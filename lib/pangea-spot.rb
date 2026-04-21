# frozen_string_literal: true
# Entry point for the pangea-spot gem.
#
# The spot-instance architecture pack for Pangea. Provides:
#   - Pangea::Spot::Catalog       — 22 typed profiles across 9 workload categories
#   - Pangea::Spot::Allocation    — 5 AWS spot allocation strategies
#   - Pangea::Architectures::Spot — Architectures that compose the above
#
# Use case:
#
#   fleet_cfg = platform.fetch('builder_fleet', {})
#   resolved  = Pangea::Spot::Catalog.resolve(fleet_cfg)
#   # resolved is {instance_types:, on_demand_base_capacity:,
#   #   on_demand_percentage_above_base:, spot_max_price:,
#   #   allocation_strategy:, profile:, category:}
#
#   Pangea::Architectures::Spot::InterruptionHandler.build(synth, {
#     name: 'workers', policy: :graceful_terminate, asg_name: 'workers-asg',
#   })

require 'pangea-core'

module Pangea
  module Spot; end
  module Architectures
    module Spot; end
  end
end

require 'pangea/spot/catalog'
require 'pangea/spot/allocation'
require 'pangea/architectures/spot/types'
require 'pangea/architectures/spot/topology_helpers'
require 'pangea/architectures/spot/interruption_handler'
require 'pangea/architectures/spot/mixed_instances_asg'
require 'pangea/architectures/spot/ec2_fleet'
require 'pangea/architectures/spot/spot_fleet'
require 'pangea/architectures/spot/k8s_jit_node_pool'
require 'pangea/architectures/spot/ci_jit_fleet'
require 'pangea/architectures/spot/packer_jit_bake'
require 'pangea/architectures/spot/breathability_helpers'
require 'pangea/architectures/spot/attic_jit_service'
require 'pangea/architectures/spot/zot_jit_service'
require 'pangea/architectures/spot/flux_jit_controller'
require 'pangea/architectures/spot/ml_jit_training'
require 'pangea/architectures/spot/batch_jit_compute'

require 'pangea-spot/version'
