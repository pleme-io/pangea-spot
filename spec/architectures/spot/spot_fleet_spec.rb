# frozen_string_literal: true

require 'spec_helper'
require 'pangea-aws'

RSpec.describe Pangea::Architectures::Spot::SpotFleet do
  include Pangea::Testing::SynthesisTestHelpers

  let(:synth) { create_synthesizer }
  let(:subnet_ids) { %w[subnet-aaa subnet-bbb] }
  let(:base_config) do
    {
      name: 'hpc-burst',
      iam_fleet_role: 'arn:aws:iam::123:role/spotfleet',
      profile: :scientific_hpc,
      launch_template_id: 'lt-hpc',
      subnet_ids: subnet_ids,
      target_capacity: 20,
    }
  end

  describe '.build with defaults (fleet_type :maintain)' do
    let(:result) do
      described_class.build(synth, base_config)
      normalize_synthesis(synth.synthesis)
    end

    it 'emits an aws_spot_fleet_request named {name}-spot-fleet' do
      fleet = validate_resource_structure(result, 'aws_spot_fleet_request', 'hpc-burst-spot-fleet')
      expect(fleet['fleet_type']).to eq('maintain')
      expect(fleet['target_capacity']).to eq(20)
    end

    it 'uses camelCase allocation_strategy on the wire' do
      fleet = validate_resource_structure(result, 'aws_spot_fleet_request', 'hpc-burst-spot-fleet')
      # scientific_hpc category → batch_compute default :capacity_optimized
      # → camelCase "capacityOptimized" on the spot_fleet_request API.
      expect(fleet['allocation_strategy']).to match(/^[a-z][a-zA-Z]+$/)
      expect(fleet['allocation_strategy']).not_to include('_')
      expect(fleet['allocation_strategy']).not_to include('-')
    end

    it 'propagates the iam_fleet_role' do
      fleet = validate_resource_structure(result, 'aws_spot_fleet_request', 'hpc-burst-spot-fleet')
      expect(fleet['iam_fleet_role']).to eq('arn:aws:iam::123:role/spotfleet')
    end

    it 'materializes every (type × subnet) pair in launch_template_config overrides' do
      fleet = validate_resource_structure(result, 'aws_spot_fleet_request', 'hpc-burst-spot-fleet')
      overrides = fleet['launch_template_config'].first['overrides']
      expect(overrides.size).to be >= 2
      expect(overrides.first).to include('instance_type', 'subnet_id')
    end
  end

  describe '.build with fleet_type :request' do
    let(:result) do
      described_class.build(synth, base_config.merge(fleet_type: :request))
      normalize_synthesis(synth.synthesis)
    end

    it 'sets fleet_type to request' do
      fleet = validate_resource_structure(result, 'aws_spot_fleet_request', 'hpc-burst-spot-fleet')
      expect(fleet['fleet_type']).to eq('request')
    end
  end

  describe '.build with spot_price ceiling' do
    let(:result) do
      described_class.build(synth, base_config.merge(spot_price: '5.00'))
      normalize_synthesis(synth.synthesis)
    end

    it 'emits spot_price on the fleet' do
      fleet = validate_resource_structure(result, 'aws_spot_fleet_request', 'hpc-burst-spot-fleet')
      expect(fleet['spot_price']).to eq('5.00')
    end
  end

  describe 'input validation' do
    it 'raises when iam_fleet_role is missing' do
      cfg = base_config.dup
      cfg.delete(:iam_fleet_role)
      expect {
        described_class.build(synth, cfg)
      }.to raise_error(ArgumentError)
    end

    it 'raises when target_capacity is missing' do
      cfg = base_config.dup
      cfg.delete(:target_capacity)
      expect {
        described_class.build(synth, cfg)
      }.to raise_error(ArgumentError)
    end
  end
end
