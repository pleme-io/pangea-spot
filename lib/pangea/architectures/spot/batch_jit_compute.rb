# frozen_string_literal: true

require 'pangea/architectures/spot/types'
require 'pangea/architectures/spot/topology_helpers'
require 'pangea/spot/catalog'
require 'pangea/spot/allocation'

module Pangea
  module Architectures
    module Spot
      # BatchJitCompute — AWS Batch spot compute environment.
      #
      # Uses aws_batch_compute_environment (native Batch spot support)
      # rather than ASG / EC2 Fleet / Spot Fleet. Batch has first-class
      # interruption semantics: reclaimed jobs are automatically re-queued
      # by the batch scheduler — no ASG healing, no Ec2Fleet fulfillment
      # loop, no spot-interruption Lambda needed.
      #
      # JIT five-dimension composition:
      #   - auction substrate   → Batch MANAGED compute env of TYPE=SPOT
      #                           (default) or TYPE=EC2 (for on-demand
      #                           pools, e.g. tight-SLA batch queues)
      #   - breathability       → min_vcpus=0 default → scale-to-zero
      #                           when queue empty; wake on first
      #                           submitted job (Batch scheduler fires
      #                           instance launch). First-job wake latency
      #                           ~60-90s.
      #   - state externalization → batch jobs ARE the state in flight;
      #                           Batch's automatic re-queue on
      #                           reclaim IS the durability layer. No S3
      #                           bucket emitted by this architecture.
      #   - interruption policy → implicit via Batch's native re-queue.
      #                           No InterruptionHandler emitted — the
      #                           Batch service handles reclaim internally.
      #   - substrate provider  → aws_batch_compute_environment +
      #                           aws_batch_job_queue
      #
      # Requires a pre-created IAM service role (Batch service role) and
      # instance role (for the EC2 instances inside the pool). If
      # `compute_type: :spot` (default), also requires a
      # `spot_iam_fleet_role_arn`.
      #
      # `profile` resolves instance types from the catalog (default
      # `:batch_compute` → `scientific_hpc` / `mapreduce_spot` / etc.
      # depending on which you choose); if an explicit
      # `instance_types` list is not supplied via config, the profile's
      # default list wins.
      #
      # Returns:
      #   { compute_env:, job_queue:, instance_types:, profile:, category:,
      #     allocation_strategy:, compute_type: }
      module BatchJitCompute
        def self.build(synth, config = {})
          config = Types::BatchJitComputeConfig.new(config).to_h

          synth.extend(Pangea::Resources::AWS) unless synth.respond_to?(:aws_batch_compute_environment)

          name = config[:name]
          tags = config[:tags] || {}
          profile_key = config[:profile]
          compute_type = config[:compute_type]

          # Resolve instance types from profile; allocation strategy
          # defaults to price_capacity_optimized (best spot savings for
          # batch) unless caller overrides.
          resolved = TopologyHelpers.resolve_fleet(
            profile: profile_key,
            instance_types: nil,
            allocation_strategy: config[:allocation_strategy],
          )

          compute_resources = {
            type: compute_type == :spot ? 'SPOT' : 'EC2',
            allocation_strategy: compute_type == :spot ?
              'SPOT_PRICE_CAPACITY_OPTIMIZED' :
              'BEST_FIT_PROGRESSIVE',
            min_vcpus: config[:min_vcpus],
            max_vcpus: config[:max_vcpus],
            desired_vcpus: config[:desired_vcpus],
            instance_type: resolved[:instance_types],
            subnets: config[:subnet_ids],
            security_group_ids: config[:security_group_ids],
            instance_role: config[:instance_role_arn],
            tags: tags.merge(
              Name: "#{name}-batch-ce",
              BatchQueue: name,
              SpotProfile: profile_key.to_s,
              SpotCategory: resolved[:category].to_s,
            ),
          }

          if compute_type == :spot
            raise ArgumentError, ':spot compute_type requires :spot_iam_fleet_role_arn' unless config[:spot_iam_fleet_role_arn]

            compute_resources[:spot_iam_fleet_role] = config[:spot_iam_fleet_role_arn]
            compute_resources[:bid_percentage] = config[:bid_percentage] if config[:bid_percentage]
          end

          compute_env = synth.aws_batch_compute_environment(:"#{name}-ce", {
            name: "#{name}-ce",
            type: 'MANAGED',
            state: 'ENABLED',
            service_role: config[:service_role_arn],
            compute_resources: compute_resources,
            tags: tags.merge(Name: "#{name}-ce", BatchQueue: name),
          })

          job_queue = synth.aws_batch_job_queue(:"#{name}-queue", {
            name: "#{name}-queue",
            state: config[:queue_state],
            priority: config[:queue_priority],
            compute_environment_order: [{
              order: 1,
              compute_environment: compute_env.ref(:arn),
            }],
            tags: tags.merge(Name: "#{name}-queue"),
          })

          {
            compute_env: compute_env,
            job_queue: job_queue,
            instance_types: resolved[:instance_types],
            profile: profile_key,
            category: resolved[:category],
            allocation_strategy: resolved[:allocation_strategy],
            compute_type: compute_type,
          }
        end
      end
    end
  end
end
