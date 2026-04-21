# frozen_string_literal: true

require 'pangea/architectures/spot/types'
require 'pangea/spot/catalog'
require 'pangea/spot/allocation'

module Pangea
  module Architectures
    module Spot
      # PackerJitBake — SSM-backed spot knobs for Packer bakes.
      #
      # This architecture is intentionally thin: it does NOT render the
      # Packer template itself (that lives in a separate typed
      # `Pangea::Architectures::Packer::NixOsBuilder` in
      # pangea-architectures, which composes this). What it DOES is
      # publish the three values a Packer `amazon-ebs` source needs to
      # run on spot at bake time:
      #
      #   - `spot_instance_types` — ordered list from the catalog profile
      #   - `spot_price` — ceiling (string, e.g. "2.50")
      #   - `allocation_strategy` — hyphenated AWS form
      #     (e.g. "capacity-optimized")
      #
      # Published as three `aws_ssm_parameter` resources under
      # `{ssm_param_prefix}/...`. Packer then resolves them via
      # `aws_ssm_parameter` data sources inside its HCL, so bakes pick up
      # new catalog entries without touching Packer HCL.
      #
      # Default profile `:beefy_spot` gives the same 18-pool Graviton mix
      # the NixBuilderFleet uses — the bake will finish on whichever pool
      # AWS offers at bake time, fall back gracefully on interruption
      # (ami-forge retries).
      #
      # Returns:
      #   { instance_types_param:, spot_price_param:, allocation_strategy_param:,
      #     instance_types:, spot_price:, allocation_strategy:, profile:, category: }
      module PackerJitBake
        def self.build(synth, config = {})
          config = Types::PackerJitBakeConfig.new(config).to_h

          synth.extend(Pangea::Resources::AWS) unless synth.respond_to?(:aws_ssm_parameter)

          name = config[:name]
          tags = config[:tags] || {}
          profile_key = config[:profile]

          profile_entry = Pangea::Spot::Catalog.fetch(profile_key)
          category = profile_entry[:category]
          instance_types = profile_entry[:instance_types]
          allocation_strategy = profile_entry[:recommended_allocation]

          prefix = config[:ssm_param_prefix] || "/pangea/#{name}/packer"
          common_tags = tags.merge(
            ManagedBy: 'pangea-spot',
            PackerJitBake: name,
            SpotProfile: profile_key.to_s,
            SpotCategory: category.to_s,
          )

          # Instance types encoded as comma-separated string (Packer's
          # SSM parameter consumption expects StringList or a scalar
          # that Packer can split). StringList is the canonical shape.
          instance_types_param = synth.aws_ssm_parameter(
            :"#{name}-spot-instance-types",
            {
              name: "#{prefix}/spot-instance-types",
              type: 'StringList',
              value: instance_types.join(','),
              description: "Spot instance types for #{name} Packer bakes (profile: #{profile_key}).",
              tags: common_tags.merge(Name: "#{prefix}/spot-instance-types"),
            },
          )

          spot_price_param = synth.aws_ssm_parameter(
            :"#{name}-spot-price",
            {
              name: "#{prefix}/spot-price",
              type: 'String',
              value: config[:spot_price],
              description: "Max spot price ceiling for #{name} Packer bakes.",
              tags: common_tags.merge(Name: "#{prefix}/spot-price"),
            },
          )

          allocation_strategy_aws = Pangea::Spot::Allocation.to_aws(allocation_strategy)

          allocation_strategy_param = synth.aws_ssm_parameter(
            :"#{name}-spot-allocation-strategy",
            {
              name: "#{prefix}/spot-allocation-strategy",
              type: 'String',
              value: allocation_strategy_aws,
              description: "Spot allocation strategy for #{name} Packer bakes.",
              tags: common_tags.merge(Name: "#{prefix}/spot-allocation-strategy"),
            },
          )

          {
            instance_types_param: instance_types_param,
            spot_price_param: spot_price_param,
            allocation_strategy_param: allocation_strategy_param,
            instance_types: instance_types,
            spot_price: config[:spot_price],
            allocation_strategy: allocation_strategy,
            profile: profile_key,
            category: category,
            ssm_param_prefix: prefix,
          }
        end
      end
    end
  end
end
