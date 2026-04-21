# frozen_string_literal: true

require 'spec_helper'
require 'pangea-aws'

RSpec.describe Pangea::Architectures::Spot::Ec2Fleet do
  include Pangea::Testing::SynthesisTestHelpers

  let(:synth) { create_synthesizer }
  let(:subnet_ids) { %w[subnet-aaa subnet-bbb] }
  let(:base_config) do
    {
      name: 'ci-burst',
      profile: :gh_actions_large,
      launch_template_id: 'lt-98765',
      subnet_ids: subnet_ids,
      target_capacity: 5,
    }
  end

  describe '.build with defaults (type :maintain)' do
    let(:result) do
      described_class.build(synth, base_config)
      normalize_synthesis(synth.synthesis)
    end

    it 'emits an aws_ec2_fleet named {name}-fleet' do
      fleet = validate_resource_structure(result, 'aws_ec2_fleet', 'ci-burst-fleet')
      expect(fleet['type']).to eq('maintain')
    end

    it 'defaults to all-spot target capacity when on_demand_target_capacity is 0' do
      fleet = validate_resource_structure(result, 'aws_ec2_fleet', 'ci-burst-fleet')
      spec = fleet['target_capacity_specification']
      expect(spec['total_target_capacity']).to eq(5)
      expect(spec['on_demand_target_capacity']).to eq(0)
      expect(spec['spot_target_capacity']).to eq(5)
      expect(spec['default_target_capacity_type']).to eq('spot')
    end

    it 'picks the category-default allocation strategy (ci_runner → price_capacity_optimized)' do
      fleet = validate_resource_structure(result, 'aws_ec2_fleet', 'ci-burst-fleet')
      expect(fleet.dig('spot_options', 'allocation_strategy')).to eq('price-capacity-optimized')
    end

    it 'materializes launch_template_config with every (type × subnet) pair' do
      fleet = validate_resource_structure(result, 'aws_ec2_fleet', 'ci-burst-fleet')
      overrides = fleet['launch_template_config'].first['override']
      # gh_actions_large has 3 instance types × 2 subnets = 6 combinations
      expect(overrides.size).to be >= 2
      expect(overrides.first).to include('instance_type', 'subnet_id')
    end

    it 'replace_unhealthy_instances is true for :maintain' do
      fleet = validate_resource_structure(result, 'aws_ec2_fleet', 'ci-burst-fleet')
      expect(fleet['replace_unhealthy_instances']).to eq(true)
    end
  end

  describe '.build with type :instant' do
    let(:result) do
      described_class.build(synth, base_config.merge(type: :instant))
      normalize_synthesis(synth.synthesis)
    end

    it 'sets type to instant' do
      fleet = validate_resource_structure(result, 'aws_ec2_fleet', 'ci-burst-fleet')
      expect(fleet['type']).to eq('instant')
    end

    it 'disables replace_unhealthy_instances for :instant (not supported)' do
      fleet = validate_resource_structure(result, 'aws_ec2_fleet', 'ci-burst-fleet')
      expect(fleet['replace_unhealthy_instances']).to eq(false)
    end
  end

  describe '.build with on-demand split' do
    let(:result) do
      described_class.build(synth, base_config.merge(
        target_capacity: 10,
        on_demand_target_capacity: 2,
      ))
      normalize_synthesis(synth.synthesis)
    end

    it 'defaults new capacity to on-demand when a base is set' do
      fleet = validate_resource_structure(result, 'aws_ec2_fleet', 'ci-burst-fleet')
      spec = fleet['target_capacity_specification']
      expect(spec['on_demand_target_capacity']).to eq(2)
      expect(spec['spot_target_capacity']).to eq(8)
      expect(spec['default_target_capacity_type']).to eq('on-demand')
    end
  end

  describe 'input validation' do
    it 'raises when neither profile nor instance_types is supplied' do
      expect {
        described_class.build(synth, base_config.merge(profile: nil))
      }.to raise_error(ArgumentError, /must provide either :profile or :instance_types/)
    end
  end
end
