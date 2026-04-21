# frozen_string_literal: true

require 'pangea/architectures/spot/types'
require 'pangea/architectures/spot/topology_helpers'

module Pangea
  module Architectures
    module Spot
      # MixedInstancesAsg — continuous-capacity spot ASG.
      #
      # Emits aws_autoscaling_group with a mixed_instances_policy
      # pointing at a pre-existing launch template. The ASG spreads
      # across every instance type in the resolved pool and uses the
      # configured spot allocation strategy. Supports on-demand base +
      # percentage above base so callers get a guaranteed floor if every
      # spot pool dries simultaneously.
      #
      # Use when:
      #   - the workload is long-running (K8s workers, controllers,
      #     cache daemons)
      #   - capacity must heal automatically on spot reclaim (ASG picks
      #     a new pool and launches a replacement)
      #   - instance refresh on launch-template bumps is desired
      #     (new AMI id → rolling replacement)
      #
      # Not for:
      #   - one-shot jobs (use Ec2Fleet :instant or :request)
      #   - workloads that need fleet-level fill-or-fail semantics
      #     (use Ec2Fleet)
      #
      # Composes:
      #   - Pangea::Spot::Catalog (via :profile)
      #   - Pangea::Spot::Allocation.default_for(category)
      #
      # Emits:
      #   aws_autoscaling_group
      #
      # Returns:
      #   { asg: ResourceReference, instance_types: Array, profile: Sym|nil,
      #     category: Sym|nil, allocation_strategy: Sym }
      module MixedInstancesAsg
        def self.build(synth, config = {})
          # Extract runtime composition objects before Dry::Struct.
          lt_ref = config.delete(:launch_template)

          config = Types::MixedInstancesAsgConfig.new(config).to_h

          synth.extend(Pangea::Resources::AWS) unless synth.respond_to?(:aws_autoscaling_group)

          resolved = TopologyHelpers.resolve_fleet(
            profile: config[:profile],
            instance_types: config[:instance_types],
            allocation_strategy: config[:spot_allocation_strategy],
          )

          lt_id = TopologyHelpers.resolve_launch_template(
            lt_ref: lt_ref,
            lt_id: config[:launch_template_id],
          )

          name = config[:name]
          tags = config[:tags] || {}

          instances_distribution = {
            on_demand_base_capacity: config[:on_demand_base_capacity],
            on_demand_percentage_above_base_capacity: config[:on_demand_percentage_above_base],
            spot_allocation_strategy: Pangea::Spot::Allocation.to_aws(resolved[:allocation_strategy]),
          }
          instances_distribution[:spot_max_price] = config[:spot_max_price] if config[:spot_max_price]

          asg_attrs = {
            name: "#{name}-asg",
            min_size: config[:min_size],
            max_size: config[:max_size],
            desired_capacity: config[:desired_capacity],
            vpc_zone_identifier: config[:subnet_ids],
            health_check_type: config[:health_check_type],
            health_check_grace_period: config[:health_check_grace_period],
            capacity_rebalance: config[:capacity_rebalance],
            mixed_instances_policy: {
              instances_distribution: instances_distribution,
              launch_template: {
                launch_template_specification: {
                  launch_template_id: lt_id,
                  version: config[:launch_template_version],
                },
                override: resolved[:instance_types].map { |t| { instance_type: t } },
              },
            },
            tag: tags.merge(Name: "#{name}-asg").map { |k, v|
              { key: k.to_s, value: v.to_s, propagate_at_launch: true }
            },
          }

          asg_attrs[:target_group_arns] = config[:target_group_arns] if config[:target_group_arns]&.any?

          if config[:instance_refresh]
            asg_attrs[:instance_refresh] = {
              strategy: 'Rolling',
              preferences: {
                min_healthy_percentage: 0,
                instance_warmup: 60,
              },
              triggers: ['tag'],
            }
          end

          asg = synth.aws_autoscaling_group(:"#{name}-asg", asg_attrs)

          {
            asg: asg,
            instance_types: resolved[:instance_types],
            profile: resolved[:profile],
            category: resolved[:category],
            allocation_strategy: resolved[:allocation_strategy],
          }
        end
      end
    end
  end
end
