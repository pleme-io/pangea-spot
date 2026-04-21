# frozen_string_literal: true

require 'pangea/spot/catalog'
require 'pangea/spot/allocation'

module Pangea
  module Architectures
    module Spot
      # Shared helpers the three topology architectures (MixedInstancesAsg,
      # Ec2Fleet, SpotFleet) use to resolve (profile | instance_types) +
      # (allocation_strategy | profile default) into concrete values. Kept
      # in one place so the resolution discipline is identical across
      # substrate choices.
      module TopologyHelpers
        # Resolve instance types + allocation strategy + category from
        # config. Explicit instance_types win over profile-derived ones;
        # explicit allocation_strategy wins over category-default.
        #
        # Returns {instance_types:, allocation_strategy:, profile: (nil|Sym), category: (nil|Sym)}
        #   instance_types:       Array<String>
        #   allocation_strategy:  Sym (snake_case, snake is the typescape form)
        #
        # Raises ArgumentError when neither a profile nor an
        # instance_types list is provided, and when the profile symbol
        # isn't in the catalog.
        def self.resolve_fleet(profile:, instance_types:, allocation_strategy:)
          if instance_types && !instance_types.empty?
            types = instance_types
            category = nil
            profile_key = nil
          elsif profile
            entry = Pangea::Spot::Catalog.fetch(profile)
            types = entry[:instance_types]
            category = entry[:category]
            profile_key = profile.to_sym
          else
            raise ArgumentError, 'must provide either :profile or :instance_types'
          end

          strategy = allocation_strategy ||
                     (category ? Pangea::Spot::Allocation.default_for(category) : :capacity_optimized)

          {
            instance_types: types,
            allocation_strategy: strategy.to_sym,
            profile: profile_key,
            category: category,
          }
        end

        # Normalize a launch-template handle: callers may pass either a
        # string id (`"lt-abc123"`) or a pangea-aws ResourceReference
        # (e.g. result of `synth.aws_launch_template(...)`). Returns the
        # string id either way. Raises when nothing is provided.
        def self.resolve_launch_template(lt_ref:, lt_id:)
          return lt_ref.id if lt_ref.respond_to?(:id)
          return lt_id if lt_id && !lt_id.empty?

          raise ArgumentError,
                'must provide :launch_template (ResourceReference) or :launch_template_id'
        end
      end
    end
  end
end
