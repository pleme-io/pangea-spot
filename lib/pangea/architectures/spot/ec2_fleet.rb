# frozen_string_literal: true

require 'pangea/architectures/spot/types'
require 'pangea/architectures/spot/topology_helpers'

module Pangea
  module Architectures
    module Spot
      # Ec2Fleet — request-fulfill-release pattern via aws_ec2_fleet.
      #
      # Distinct from an ASG. EC2 Fleet is a fleet-level primitive that
      # asks AWS for N units of capacity across a pool and returns (or
      # maintains) whatever it gets. Three fleet types:
      #
      #   :maintain  — continuous capacity, like an ASG without the
      #                auto-healing or lifecycle-hook surface. Best for
      #                long-running batch pools.
      #   :request   — fill once. If an instance dies / is reclaimed, it
      #                is NOT replaced. Best for one-shot job batches.
      #   :instant   — synchronous single fulfillment. API returns with
      #                either the instances or a partial/failed fulfill.
      #                Best for CI bursts and ephemeral compute where
      #                you want to know RIGHT NOW whether you got what
      #                you asked for.
      #
      # Use when:
      #   - The workload needs fleet-level fill-or-fail semantics.
      #   - Target capacity is measured in units (can be vCPUs, memory)
      #     not instance count.
      #   - You don't need the ASG surface (lifecycle hooks, launch-
      #     template instance refresh, target group attachment).
      #
      # Emits:
      #   aws_ec2_fleet
      #
      # Returns:
      #   { fleet: ResourceReference, instance_types: Array, profile: Sym|nil,
      #     category: Sym|nil, allocation_strategy: Sym, type: Sym }
      module Ec2Fleet
        def self.build(synth, config = {})
          lt_ref = config.delete(:launch_template)
          config = Types::Ec2FleetConfig.new(config).to_h

          synth.extend(Pangea::Resources::AWS) unless synth.respond_to?(:aws_ec2_fleet)

          resolved = TopologyHelpers.resolve_fleet(
            profile: config[:profile],
            instance_types: config[:instance_types],
            allocation_strategy: config[:allocation_strategy],
          )

          lt_id = TopologyHelpers.resolve_launch_template(
            lt_ref: lt_ref,
            lt_id: config[:launch_template_id],
          )

          name = config[:name]
          tags = config[:tags] || {}
          fleet_type = config[:type]

          # target_capacity_specification
          total_target = config[:target_capacity]
          on_demand_target = config[:on_demand_target_capacity]
          spot_target = config[:spot_target_capacity] || (total_target - on_demand_target)

          target_spec = {
            total_target_capacity: total_target,
            on_demand_target_capacity: on_demand_target,
            spot_target_capacity: spot_target,
            default_target_capacity_type: on_demand_target.positive? ? 'on-demand' : 'spot',
          }

          spot_options = {
            allocation_strategy: Pangea::Spot::Allocation.to_aws(resolved[:allocation_strategy]),
          }
          spot_options[:max_total_price] = config[:spot_max_price] if config[:spot_max_price]

          fleet_attrs = {
            type: fleet_type.to_s,
            target_capacity_specification: target_spec,
            launch_template_config: [{
              launch_template_specification: {
                launch_template_id: lt_id,
                version: config[:launch_template_version],
              },
              override: resolved[:instance_types].map { |t|
                { instance_type: t, subnet_id: config[:subnet_ids].first }
              } + resolved[:instance_types].flat_map { |t|
                config[:subnet_ids].drop(1).map { |sn| { instance_type: t, subnet_id: sn } }
              },
            }],
            spot_options: spot_options,
            # :instant fleets don't support these flags (no continuous
            # maintenance), so gate them.
            replace_unhealthy_instances: fleet_type == :maintain ? config[:replace_unhealthy_instances] : false,
            terminate_instances_with_expiration: config[:terminate_instances_with_expiration],
            tags: tags.merge(Name: "#{name}-fleet"),
          }

          fleet = synth.aws_ec2_fleet(:"#{name}-fleet", fleet_attrs)

          {
            fleet: fleet,
            instance_types: resolved[:instance_types],
            profile: resolved[:profile],
            category: resolved[:category],
            allocation_strategy: resolved[:allocation_strategy],
            type: fleet_type,
          }
        end
      end
    end
  end
end
