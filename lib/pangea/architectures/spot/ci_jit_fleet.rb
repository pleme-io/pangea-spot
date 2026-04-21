# frozen_string_literal: true

require 'pangea/architectures/spot/types'
require 'pangea/architectures/spot/topology_helpers'
require 'pangea/architectures/spot/ec2_fleet'
require 'pangea/architectures/spot/interruption_handler'
require 'pangea/architectures/spot/alert_layer'
require 'pangea/spot/catalog'

module Pangea
  module Architectures
    module Spot
      # CiJitFleet — ephemeral CI runner pool on spot.
      #
      # Composition:
      #
      #   1. aws_launch_template pinned to a ci_runner catalog profile
      #      (default :gh_actions_large — 3 instance types sized for
      #      linux-x64 GHA workloads, price-capacity-optimized).
      #   2. Ec2Fleet — :maintain by default (continuous capacity for a
      #      standing runner pool) or :request / :instant for one-shot
      #      burst workloads. EC2 Fleet is the right primitive here (vs
      #      ASG) because CI pools often want fleet-level fill-or-fail
      #      semantics and don't need the ASG healing surface.
      #   3. Spot::InterruptionHandler with `:naive_terminate` — CI jobs
      #      are idempotent and retry at the job level, so graceful
      #      drain is unnecessary. The handler still emits the
      #      EventBridge rule for observability (you want to KNOW when
      #      a runner got reclaimed mid-job, even if you can't drain it).
      #
      # The `runner_registration_token_secret_arn` is carried through
      # tags for later wiring (the user_data that joins the pool to
      # GitHub/BuildKite/GitLab reads it from Secrets Manager at launch).
      # This architecture doesn't render that user_data; it just exposes
      # the ARN as a config surface so cascades can propagate it.
      #
      # Returns:
      #   { launch_template:, fleet_result:, interruption_handler_result:,
      #     instance_types:, profile:, category:, fleet_type: }
      module CiJitFleet
        def self.build(synth, config = {})
          config = Types::CiJitFleetConfig.new(config).to_h

          synth.extend(Pangea::Resources::AWS) unless synth.respond_to?(:aws_launch_template)

          name = config[:name]
          tags = config[:tags] || {}
          profile_key = config[:profile]

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
                Name: "#{name}-runner",
                SpotProfile: profile_key.to_s,
                SpotCategory: category.to_s,
                CiPool: name,
              ),
            }],
            tags: tags.merge(Name: "#{name}-lt"),
          }

          lt_attrs[:key_name] = config[:key_name] if config[:key_name]
          lt_attrs[:user_data] = config[:user_data_base64] if config[:user_data_base64]

          # Propagate the runner-registration-secret ARN in tags so
          # user_data bootstrap on the instance can fetch it and
          # cascades downstream can discover it without parsing config.
          if config[:runner_registration_token_secret_arn]
            lt_attrs[:tag_specifications].first[:tags] =
              lt_attrs[:tag_specifications].first[:tags].merge(
                RunnerTokenSecretArn: config[:runner_registration_token_secret_arn],
              )
          end

          lt = synth.aws_launch_template(:"#{name}-lt", lt_attrs)

          fleet_result = Ec2Fleet.build(synth, {
            name: name,
            profile: profile_key,
            launch_template: lt,
            subnet_ids: config[:subnet_ids],
            target_capacity: config[:target_capacity],
            on_demand_target_capacity: config[:on_demand_target_capacity],
            type: config[:fleet_type],
            spot_max_price: config[:spot_max_price],
            tags: tags.merge(CiPool: name),
          })

          interruption_result = InterruptionHandler.build(synth, {
            name: name,
            policy: :naive_terminate,
            include_rebalance_events: config[:include_rebalance_events],
            tags: tags.merge(CiPool: name),
          })

          # ── Mandatory alert layer (default :nth_queue for CI) ─────────
          # CI fleets are typically multi-node; centralized queue-mode
          # NTH is cheaper than per-node DaemonSet. Caller can override
          # to :nth_imds for smaller pools or :none if the runner agent
          # already handles interruption (rare).
          alert_cfg = (config[:alert_layer] || {}).dup
          alert_cfg[:name] ||= "#{name}-alert"
          alert_cfg[:source] ||= :aws_eventbridge_sqs
          alert_cfg[:forwarder] ||= :nth_queue
          alert_layer_result = AlertLayer.build(synth, alert_cfg, asg_name: nil, tags: tags.merge(CiPool: name))

          {
            launch_template: lt,
            fleet_result: fleet_result,
            interruption_handler_result: interruption_result,
            alert_layer_result: alert_layer_result,
            instance_types: profile_entry[:instance_types],
            profile: profile_key,
            category: category,
            fleet_type: config[:fleet_type],
          }
        end
      end
    end
  end
end
