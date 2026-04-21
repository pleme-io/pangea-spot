# frozen_string_literal: true

require 'pangea/architectures/spot/types'
require 'pangea/architectures/spot/k8s_jit_node_pool'

module Pangea
  module Architectures
    module Spot
      # FluxJitController — breathable FluxCD controller pool.
      #
      # FluxCD controllers reconcile FROM Git. That makes Git the durable
      # state layer (fully externalized by definition), and controller
      # interruption a non-event: the next controller instance wakes,
      # reads Git, picks up reconciliation where it left off.
      #
      # This architecture is deliberately thin. It emits ONLY a
      # K8sJitNodePool dedicated to flux-system:
      #   - taint `dedicated=flux-system:NoSchedule` so only flux-system
      #     pods land here (set via tolerations in the FluxCD manifests)
      #   - label `role=flux-system` so NodePool selectors match
      #   - `min_size: 1` by default — FluxCD needs at least one
      #     controller-manager alive to receive reconcile ticks. Setting
      #     `min_size: 0` is allowed for clusters that accept reconcile
      #     lag on cold start, but the default preserves utility.
      #   - K8sJitNodePool's `:drain_k8s_node` interruption policy applies
      #     (graceful drain of flux-system pods before spot reclaim).
      #
      # No NLB (FluxCD has no inbound service).
      # No S3 bucket (Git is the durable layer).
      # `git_repo_url` is carried as an instance tag for cascade
      # discovery but not otherwise rendered.
      #
      # Returns:
      #   { node_pool_result:, flux_label:, flux_taint:, git_repo_url: }
      module FluxJitController
        def self.build(synth, config = {})
          config = Types::FluxJitControllerConfig.new(config).to_h

          synth.extend(Pangea::Resources::AWS) unless synth.respond_to?(:aws_launch_template)

          name = config[:name]
          tags = config[:tags] || {}

          node_labels = config[:node_labels] || { 'role' => 'flux-system' }
          node_taints = config[:node_taints] || [
            { key: 'dedicated', value: 'flux-system', effect: 'NoSchedule' },
          ]

          extra_tags = tags.merge(Service: 'flux-controller')
          if config[:git_repo_url]
            extra_tags = extra_tags.merge(FluxGitRepoUrl: config[:git_repo_url])
          end

          node_pool_result = K8sJitNodePool.build(synth, {
            name: "#{name}-flux",
            profile: config[:profile],
            image_id: config[:image_id],
            instance_profile_arn: config[:instance_profile_arn],
            security_group_ids: config[:security_group_ids],
            subnet_ids: config[:subnet_ids],
            key_name: config[:key_name],
            user_data_base64: config[:user_data_base64],
            min_size: config[:min_size],
            max_size: config[:max_size],
            desired_capacity: config[:desired_capacity],
            node_labels: node_labels,
            node_taints: node_taints,
            lambda_drain_arn: config[:lambda_drain_arn],
            alert_layer: config[:alert_layer] || {},
            tags: extra_tags,
          })

          {
            node_pool_result: node_pool_result,
            flux_label: node_labels,
            flux_taint: node_taints,
            git_repo_url: config[:git_repo_url],
          }
        end
      end
    end
  end
end
