# frozen_string_literal: true

require 'pangea/architectures/spot/types'
require 'pangea/architectures/spot/topology_helpers'

module Pangea
  module Architectures
    module Spot
      # SpotFleet — aws_spot_fleet_request (legacy predecessor to EC2 Fleet).
      #
      # Prefer Ec2Fleet for new workloads. SpotFleet stays as a first-class
      # architecture for three cases:
      #
      #   1. Migration parity — existing Terraform stacks that already
      #      declare aws_spot_fleet_request and can't migrate until a
      #      maintenance window aligns.
      #   2. Tagged-volume propagation on older instance families where
      #      EC2 Fleet's tag handling has regressions.
      #   3. GPU / HPC pools where SpotFleet's `instance_pools_to_use_count`
      #      (diversified) heuristic is still better than Ec2Fleet's.
      #
      # Key differences vs Ec2Fleet:
      #   - Allocation strategy is camelCase on the wire
      #     (capacityOptimized) not hyphen (capacity-optimized).
      #     Pangea::Spot::Allocation.to_spot_fleet handles the translation.
      #   - Requires a pre-created IAM fleet-role ARN
      #     (aws_iam_role for spotfleet.amazonaws.com).
      #   - Only two fleet types (:maintain, :request) — no :instant.
      #
      # Emits:
      #   aws_spot_fleet_request
      #
      # Returns:
      #   { fleet: ResourceReference, instance_types: Array, profile: Sym|nil,
      #     category: Sym|nil, allocation_strategy: Sym, fleet_type: Sym }
      module SpotFleet
        def self.build(synth, config = {})
          lt_ref = config.delete(:launch_template)
          config = Types::SpotFleetConfig.new(config).to_h

          synth.extend(Pangea::Resources::AWS) unless synth.respond_to?(:aws_spot_fleet_request)

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

          fleet_attrs = {
            iam_fleet_role: config[:iam_fleet_role],
            fleet_type: config[:fleet_type].to_s,
            allocation_strategy: Pangea::Spot::Allocation.to_spot_fleet(resolved[:allocation_strategy]),
            target_capacity: config[:target_capacity],
            replace_unhealthy_instances: config[:replace_unhealthy_instances],
            terminate_instances_with_expiration: config[:terminate_instances_with_expiration],
            launch_template_config: [{
              launch_template_specification: {
                id: lt_id,
                version: config[:launch_template_version],
              },
              overrides: resolved[:instance_types].flat_map { |t|
                config[:subnet_ids].map { |sn| { instance_type: t, subnet_id: sn } }
              },
            }],
            tags: tags.merge(Name: "#{name}-spot-fleet"),
          }

          fleet_attrs[:spot_price] = config[:spot_price] if config[:spot_price]

          fleet = synth.aws_spot_fleet_request(:"#{name}-spot-fleet", fleet_attrs)

          {
            fleet: fleet,
            instance_types: resolved[:instance_types],
            profile: resolved[:profile],
            category: resolved[:category],
            allocation_strategy: resolved[:allocation_strategy],
            fleet_type: config[:fleet_type],
          }
        end
      end
    end
  end
end
