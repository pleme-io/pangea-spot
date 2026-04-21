# frozen_string_literal: true

require 'dry-struct'
require 'dry-types'

module Pangea
  module Architectures
    module Spot
      # Local Dry::Struct-backed config types for the spot-instance
      # architecture pack. Kept self-contained (doesn't reach into
      # pangea-architectures' shared `Config` base class) so `pangea-spot`
      # can be consumed standalone.
      module Types
        include Dry.Types()

        # Base class: symbolize keys, drop unknown attributes, re-raise
        # Dry::Struct::Error as ArgumentError so existing hash-based
        # callers see a familiar exception type.
        class Config < Dry::Struct
          transform_keys(&:to_sym)

          def self.new(attributes = {})
            allowed = schema.keys.map(&:name).to_set
            filtered = attributes.each_with_object({}) do |(k, v), h|
              key = k.is_a?(String) ? k.to_sym : k
              h[key] = v if allowed.include?(key)
            end
            super(filtered)
          rescue Dry::Struct::Error => e
            raise ArgumentError, e.message
          end
        end

        SpotPolicySym = Types::Coercible::Symbol.enum(
          :naive_terminate,
          :graceful_terminate,
          :drain_k8s_node,
          :checkpoint_job,
        )

        class SpotInterruptionHandlerConfig < Config
          attribute  :name,                         Types::String
          attribute  :policy,                       SpotPolicySym
          attribute? :asg_name,                     Types::String.optional.default(nil)
          attribute? :lambda_function_arn,          Types::String.optional.default(nil)
          attribute? :lifecycle_heartbeat_timeout,  Types::Integer.default(120)
          attribute? :lifecycle_role_arn,           Types::String.optional.default(nil)
          attribute? :include_rebalance_events,     Types::Bool.default(true)
          attribute? :tags,                         Types::Hash.default({}.freeze)
        end
      end
    end
  end
end
