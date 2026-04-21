# frozen_string_literal: true
#
# Pangea::Spot::Allocation — typed wrapper for AWS spot allocation
# strategies. AWS accepts hyphenated snake_case; we expose snake_case
# symbols with a strict .to_aws translation.
#
# Strategies (2026-04):
#   capacity_optimized              Pick the pool with the most capacity.
#                                   Default for production workloads.
#   capacity_optimized_prioritized  Same, but respect Priorities[] order.
#                                   Use when some instance types are
#                                   preferred (e.g. newer gen > older).
#   price_capacity_optimized        Balance price AND capacity. Best
#                                   for cost-sensitive K8s workers / CI.
#   diversified                     Spread across every pool. Shallow
#                                   pools (HPC, GPU metal) only.
#   lowest_price                    Cheapest first (N lowest pools). NOT
#                                   recommended for production — high
#                                   interruption on shallow pools.

module Pangea
  module Spot
    module Allocation
      STRATEGIES = %i[
        capacity_optimized
        capacity_optimized_prioritized
        price_capacity_optimized
        diversified
        lowest_price
      ].freeze

      # snake_case → hyphen form expected by the Terraform aws provider +
      # AWS API. E.g. :capacity_optimized → "capacity-optimized".
      def self.to_aws(strategy)
        raise ArgumentError, "unknown strategy #{strategy.inspect}" unless STRATEGIES.include?(strategy.to_sym)

        strategy.to_s.tr('_', '-')
      end

      # Default per workload category.
      DEFAULTS = {
        nix_builder:      :capacity_optimized,
        k8s_workers:      :price_capacity_optimized,
        ci_runner:        :price_capacity_optimized,
        ml_training:      :capacity_optimized,
        batch_compute:    :capacity_optimized,
        ephemeral_runner: :price_capacity_optimized,
        memory_heavy:     :price_capacity_optimized,
        storage_heavy:    :price_capacity_optimized,
        network_heavy:    :capacity_optimized,
      }.freeze

      def self.default_for(category)
        DEFAULTS.fetch(category.to_sym) { :capacity_optimized }
      end
    end
  end
end
