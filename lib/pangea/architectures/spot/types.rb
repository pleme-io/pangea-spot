# frozen_string_literal: true

require 'dry-struct'
require 'dry-types'

# Guard: pangea-aws activates zeitwerk with a parent directory that
# shadows this file, causing a second evaluation pass that would reopen
# the Dry::Struct config classes below and trip
# `Dry::Struct::RepeatedAttributeError`. A proper constant sentinel
# keeps the file idempotent.
if defined?(Pangea::Architectures::Spot::Types::LOADED_SENTINEL)
  return
end

module Pangea
  module Architectures
    module Spot
      # Local Dry::Struct-backed config types for the spot-instance
      # architecture pack. Kept self-contained (doesn't reach into
      # pangea-architectures' shared `Config` base class) so `pangea-spot`
      # can be consumed standalone.
      module Types
        include Dry.Types()
        LOADED_SENTINEL = true

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

        # ── Interruption handler ─────────────────────────────────────────

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

        # ── Shared topology knobs ────────────────────────────────────────

        SpotAllocationStrategySym = Types::Coercible::Symbol.enum(
          :capacity_optimized,
          :capacity_optimized_prioritized,
          :price_capacity_optimized,
          :diversified,
          :lowest_price,
        )

        # ── MixedInstancesAsg — ASG with mixed-instances policy ──────────
        #
        # Continuous-capacity pattern. The only ASG shape that can have a
        # mixed on-demand/spot fleet with auto-healing + instance refresh.
        # Best for long-running worker pools that still want spot savings.
        class MixedInstancesAsgConfig < Config
          attribute  :name,                             Types::String
          attribute? :profile,                          Types::Coercible::Symbol.optional.default(nil)
          attribute? :instance_types,                   Types::Array.of(Types::String).optional.default(nil)
          attribute? :launch_template_id,               Types::String.optional.default(nil)
          attribute? :launch_template_version,          Types::String.default('$Latest')
          attribute  :subnet_ids,                       Types::Array.of(Types::String)
          attribute? :min_size,                         Types::Integer.default(0)
          attribute? :max_size,                         Types::Integer.default(4)
          attribute? :desired_capacity,                 Types::Integer.default(1)
          attribute? :on_demand_base_capacity,          Types::Integer.default(0)
          attribute? :on_demand_percentage_above_base,  Types::Integer.default(0)
          attribute? :spot_allocation_strategy,         SpotAllocationStrategySym.optional.default(nil)
          attribute? :spot_max_price,                   Types::String.optional.default(nil)
          attribute? :capacity_rebalance,               Types::Bool.default(true)
          attribute? :health_check_type,                Types::String.default('EC2')
          attribute? :health_check_grace_period,        Types::Integer.default(300)
          attribute? :instance_refresh,                 Types::Bool.default(true)
          attribute? :target_group_arns,                Types::Array.of(Types::String).default([].freeze)
          attribute? :tags,                             Types::Hash.default({}.freeze)
        end

        # ── Ec2Fleet — aws_ec2_fleet ─────────────────────────────────────
        #
        # Request-fulfill-release pattern. Supports three fleet types:
        #   :maintain — continuous capacity (like an ASG without the
        #               auto-healing or lifecycle hooks)
        #   :request  — fill once, don't replace interrupted instances
        #   :instant  — synchronous: API call returns when instances are
        #               either launched or fulfillment declined
        # Use for batch / CI / burst workloads where you don't need ASG's
        # continuous-replacement guarantee.
        Ec2FleetTypeSym = Types::Coercible::Symbol.default(:maintain).enum(:maintain, :request, :instant)

        class Ec2FleetConfig < Config
          attribute  :name,                                  Types::String
          attribute? :profile,                               Types::Coercible::Symbol.optional.default(nil)
          attribute? :instance_types,                        Types::Array.of(Types::String).optional.default(nil)
          attribute? :launch_template_id,                    Types::String.optional.default(nil)
          attribute? :launch_template_version,               Types::String.default('$Latest')
          attribute  :subnet_ids,                            Types::Array.of(Types::String)
          attribute  :target_capacity,                       Types::Integer
          attribute? :on_demand_target_capacity,             Types::Integer.default(0)
          attribute? :spot_target_capacity,                  Types::Integer.optional.default(nil)
          attribute? :type,                                  Ec2FleetTypeSym
          attribute? :allocation_strategy,                   SpotAllocationStrategySym.optional.default(nil)
          attribute? :spot_max_price,                        Types::String.optional.default(nil)
          attribute? :replace_unhealthy_instances,           Types::Bool.default(true)
          attribute? :terminate_instances_with_expiration,   Types::Bool.default(true)
          attribute? :tags,                                  Types::Hash.default({}.freeze)
        end

        # ── SpotFleet — aws_spot_fleet_request (legacy) ──────────────────
        #
        # Predecessor to EC2 Fleet. Still useful for specific workloads:
        # tagged-volume propagation on older instance families, certain
        # GPU HPC pools where EC2 Fleet has regression. Prefer Ec2Fleet
        # for new workloads; SpotFleet stays for migration parity.
        SpotFleetTypeSym = Types::Coercible::Symbol.default(:maintain).enum(:maintain, :request)

        class SpotFleetConfig < Config
          attribute  :name,                                  Types::String
          attribute  :iam_fleet_role,                        Types::String
          attribute? :profile,                               Types::Coercible::Symbol.optional.default(nil)
          attribute? :instance_types,                        Types::Array.of(Types::String).optional.default(nil)
          attribute? :launch_template_id,                    Types::String.optional.default(nil)
          attribute? :launch_template_version,               Types::String.default('$Latest')
          attribute  :subnet_ids,                            Types::Array.of(Types::String)
          attribute  :target_capacity,                       Types::Integer
          attribute? :fleet_type,                            SpotFleetTypeSym
          attribute? :allocation_strategy,                   SpotAllocationStrategySym.optional.default(nil)
          attribute? :spot_price,                            Types::String.optional.default(nil)
          attribute? :replace_unhealthy_instances,           Types::Bool.default(true)
          attribute? :terminate_instances_with_expiration,   Types::Bool.default(true)
          attribute? :tags,                                  Types::Hash.default({}.freeze)
        end

        # ── K8sJitNodePool — JIT K8s worker pool ─────────────────────────
        #
        # Composes MixedInstancesAsg + InterruptionHandler(:drain_k8s_node).
        # The substrate building block for K8s workers that live on spot
        # but preserve pod-level utility via graceful drain.
        class K8sJitNodePoolConfig < Config
          attribute  :name,                                  Types::String
          attribute? :profile,                               Types::Coercible::Symbol.default(:karpenter_general)
          attribute  :image_id,                              Types::String
          attribute  :instance_profile_arn,                  Types::String
          attribute  :security_group_ids,                    Types::Array.of(Types::String)
          attribute  :subnet_ids,                            Types::Array.of(Types::String)
          attribute? :key_name,                              Types::String.optional.default(nil)
          attribute? :user_data_base64,                      Types::String.optional.default(nil)
          attribute? :min_size,                              Types::Integer.default(0)
          attribute? :max_size,                              Types::Integer.default(10)
          attribute? :desired_capacity,                      Types::Integer.default(1)
          attribute? :on_demand_base_capacity,               Types::Integer.default(0)
          attribute? :on_demand_percentage_above_base,       Types::Integer.default(0)
          attribute? :node_labels,                           Types::Hash.default({}.freeze)
          attribute? :node_taints,                           Types::Array.default([].freeze)
          attribute? :lambda_drain_arn,                      Types::String.optional.default(nil)
          attribute? :include_rebalance_events,              Types::Bool.default(true)
          attribute? :lifecycle_heartbeat_timeout,           Types::Integer.default(300)
          attribute? :spot_max_price,                        Types::String.optional.default(nil)
          attribute? :root_volume_gb,                        Types::Integer.default(50)
          attribute? :tags,                                  Types::Hash.default({}.freeze)
        end

        # ── CiJitFleet — JIT CI runner fleet ─────────────────────────────
        #
        # Composes Ec2Fleet + InterruptionHandler(:naive_terminate). CI
        # jobs retry at job level (GHA/BuildKite), so drain is
        # unnecessary; interruption handler is there purely for
        # observability of spot reclaims.
        class CiJitFleetConfig < Config
          attribute  :name,                                  Types::String
          attribute? :profile,                               Types::Coercible::Symbol.default(:gh_actions_large)
          attribute  :image_id,                              Types::String
          attribute  :instance_profile_arn,                  Types::String
          attribute  :security_group_ids,                    Types::Array.of(Types::String)
          attribute  :subnet_ids,                            Types::Array.of(Types::String)
          attribute  :target_capacity,                       Types::Integer
          attribute? :fleet_type,                            Ec2FleetTypeSym
          attribute? :on_demand_target_capacity,             Types::Integer.default(0)
          attribute? :key_name,                              Types::String.optional.default(nil)
          attribute? :user_data_base64,                      Types::String.optional.default(nil)
          attribute? :runner_registration_token_secret_arn,  Types::String.optional.default(nil)
          attribute? :include_rebalance_events,              Types::Bool.default(true)
          attribute? :spot_max_price,                        Types::String.optional.default(nil)
          attribute? :root_volume_gb,                        Types::Integer.default(30)
          attribute? :tags,                                  Types::Hash.default({}.freeze)
        end

        # ── PackerJitBake — Packer bake spot knob publisher ──────────────
        #
        # Thin architecture. Publishes the typed spot profile's instance
        # types + allocation strategy + spot_price as SSM parameters so
        # Packer's amazon-ebs builder (rendered by a SEPARATE typed
        # Pangea::Architectures::Packer::NixOsBuilder) can resolve
        # spot_instance_types + spot_price via aws_ssm_parameter data
        # sources at bake time. No fleet, no LT — just the config surface.
        class PackerJitBakeConfig < Config
          attribute  :name,                                  Types::String
          attribute? :profile,                               Types::Coercible::Symbol.default(:beefy_spot)
          attribute? :spot_price,                            Types::String.default('2.50')
          attribute? :ssm_param_prefix,                      Types::String.optional.default(nil)
          attribute? :tags,                                  Types::Hash.default({}.freeze)
        end
      end
    end
  end
end
