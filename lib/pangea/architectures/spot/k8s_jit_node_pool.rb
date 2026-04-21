# frozen_string_literal: true

require 'pangea/architectures/spot/types'
require 'pangea/architectures/spot/topology_helpers'
require 'pangea/architectures/spot/mixed_instances_asg'
require 'pangea/architectures/spot/interruption_handler'
require 'pangea/spot/catalog'

module Pangea
  module Architectures
    module Spot
      # K8sJitNodePool — a K8s-ready spot worker pool composition.
      #
      # Stacks three things behind one YAML knob:
      #
      #   1. aws_launch_template wired to a Pangea::Spot::Catalog profile
      #      (default :karpenter_general — price-capacity-optimized across
      #      a mix of m6i/c6i general-purpose workers).
      #   2. MixedInstancesAsg with capacity_rebalance + instance_refresh
      #      on by default (the utility-preserving defaults) plus the
      #      configured on-demand floor.
      #   3. Spot::InterruptionHandler with `:drain_k8s_node` policy. When
      #      a `lambda_drain_arn` is supplied, interruption warnings route
      #      directly to that Lambda (cordons + drains the node via the
      #      pre-signed kubeconfig). When absent, falls back to the SNS
      #      topic the handler emits — downstream ops attach whatever
      #      draining subscriber they like.
      #
      # Node labels/taints land on the launch-template `tag_specifications`
      # block so Karpenter / cluster-autoscaler discovery can read them.
      # Applying them as actual kubelet labels is the launch-template
      # user_data's job — this architecture doesn't render bootstrap
      # scripts, only the substrate.
      #
      # Returns:
      #   { launch_template:, asg_result:, interruption_handler_result:,
      #     instance_types:, profile:, category: }
      module K8sJitNodePool
        def self.build(synth, config = {})
          config = Types::K8sJitNodePoolConfig.new(config).to_h

          synth.extend(Pangea::Resources::AWS) unless synth.respond_to?(:aws_launch_template)

          name = config[:name]
          tags = config[:tags] || {}
          profile_key = config[:profile]

          # Pre-resolve the profile so we can tag the LT with the profile
          # name + category for operator observability.
          profile_entry = Pangea::Spot::Catalog.fetch(profile_key)
          category = profile_entry[:category]

          lt_attrs = {
            name: "#{name}-lt",
            image_id: config[:image_id],
            instance_type: profile_entry[:instance_types].first,
            iam_instance_profile: { arn: config[:instance_profile_arn] },
            vpc_security_group_ids: config[:security_group_ids],
            block_device_mappings: [{
              device_name: '/dev/xvda',
              ebs: {
                volume_size: config[:root_volume_gb],
                volume_type: 'gp3',
                encrypted: true,
                delete_on_termination: true,
              },
            }],
            metadata_options: {
              http_endpoint: 'enabled',
              http_tokens: 'required',
              http_put_response_hop_limit: 2,
            },
            tag_specifications: [{
              resource_type: 'instance',
              tags: tags.merge(
                Name: "#{name}-node",
                SpotProfile: profile_key.to_s,
                SpotCategory: category.to_s,
                NodeLabels: config[:node_labels].to_json,
                NodeTaints: config[:node_taints].to_json,
              ),
            }],
            tags: tags.merge(Name: "#{name}-lt"),
          }

          lt_attrs[:key_name] = config[:key_name] if config[:key_name]
          lt_attrs[:user_data] = config[:user_data_base64] if config[:user_data_base64]

          lt = synth.aws_launch_template(:"#{name}-lt", lt_attrs)

          asg_result = MixedInstancesAsg.build(synth, {
            name: name,
            profile: profile_key,
            launch_template: lt,
            subnet_ids: config[:subnet_ids],
            min_size: config[:min_size],
            max_size: config[:max_size],
            desired_capacity: config[:desired_capacity],
            on_demand_base_capacity: config[:on_demand_base_capacity],
            on_demand_percentage_above_base: config[:on_demand_percentage_above_base],
            spot_max_price: config[:spot_max_price],
            capacity_rebalance: true,
            instance_refresh: true,
            tags: tags.merge(NodePool: name),
          })

          # The ASG emitted by MixedInstancesAsg is tagged with Name:
          # "#{name}-asg". The interruption handler uses ASG_NAME in its
          # lifecycle hook, so we need the concrete string here.
          asg_name = "#{name}-asg"

          # Interruption policy — default :drain_k8s_node preserves the
          # K8s drain semantics. Callers like MlJitTraining override to
          # :checkpoint_job so spot reclaims trigger a checkpoint Lambda
          # instead of a cordon+drain. Lambda ARN resolves explicit
          # lambda_function_arn first, falls back to lambda_drain_arn
          # (back-compat alias).
          lambda_arn = config[:lambda_function_arn] || config[:lambda_drain_arn]

          handler_cfg = {
            name: name,
            policy: config[:interruption_policy] || :drain_k8s_node,
            asg_name: asg_name,
            lifecycle_heartbeat_timeout: config[:lifecycle_heartbeat_timeout],
            include_rebalance_events: config[:include_rebalance_events],
            tags: tags.merge(NodePool: name),
          }
          handler_cfg[:lambda_function_arn] = lambda_arn if lambda_arn

          interruption_result = InterruptionHandler.build(synth, handler_cfg)

          {
            launch_template: lt,
            asg_result: asg_result,
            interruption_handler_result: interruption_result,
            instance_types: profile_entry[:instance_types],
            profile: profile_key,
            category: category,
          }
        end
      end
    end
  end
end
