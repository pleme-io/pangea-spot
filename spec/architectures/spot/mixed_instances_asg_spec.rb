# frozen_string_literal: true

require 'spec_helper'
require 'pangea-aws'

RSpec.describe Pangea::Architectures::Spot::MixedInstancesAsg do
  include Pangea::Testing::SynthesisTestHelpers

  let(:synth) { create_synthesizer }
  let(:subnet_ids) { %w[subnet-aaa subnet-bbb] }
  let(:base_config) do
    {
      name: 'workers',
      profile: :beefy_spot,
      launch_template_id: 'lt-12345',
      subnet_ids: subnet_ids,
      min_size: 0,
      max_size: 10,
      desired_capacity: 3,
    }
  end

  describe '.build with a catalog profile' do
    let(:result) do
      described_class.build(synth, base_config)
      normalize_synthesis(synth.synthesis)
    end

    it 'emits an autoscaling group named {name}-asg' do
      asg = validate_resource_structure(result, 'aws_autoscaling_group', 'workers-asg')
      expect(asg['name']).to eq('workers-asg')
      expect(asg['min_size']).to eq(0)
      expect(asg['max_size']).to eq(10)
    end

    it 'attaches the launch template id via mixed_instances_policy' do
      asg = validate_resource_structure(result, 'aws_autoscaling_group', 'workers-asg')
      spec = asg.dig('mixed_instances_policy', 'launch_template', 'launch_template_specification')
      expect(spec['launch_template_id']).to eq('lt-12345')
      expect(spec['version']).to eq('$Latest')
    end

    it 'fans the launch template across every instance type in the profile' do
      asg = validate_resource_structure(result, 'aws_autoscaling_group', 'workers-asg')
      overrides = asg.dig('mixed_instances_policy', 'launch_template', 'override')
      types = overrides.map { |o| o['instance_type'] }
      # beefy_spot has 18 pools (c7g/c7gd/c8g/m7g/m7gd/m8g/r7g/c6g/m6g × 8xl/16xl).
      expect(types.size).to eq(18)
      expect(types).to include('c7g.16xlarge', 'r7g.8xlarge')
    end

    it 'picks the default allocation strategy for the profile category (nix_builder → capacity_optimized)' do
      asg = validate_resource_structure(result, 'aws_autoscaling_group', 'workers-asg')
      strategy = asg.dig('mixed_instances_policy', 'instances_distribution', 'spot_allocation_strategy')
      expect(strategy).to eq('capacity-optimized')
    end

    it 'enables capacity_rebalance by default' do
      asg = validate_resource_structure(result, 'aws_autoscaling_group', 'workers-asg')
      expect(asg['capacity_rebalance']).to eq(true)
    end

    it 'enables instance_refresh by default (rolling, triggers on tag)' do
      asg = validate_resource_structure(result, 'aws_autoscaling_group', 'workers-asg')
      refresh = asg['instance_refresh']
      expect(refresh['strategy']).to eq('Rolling')
      expect(refresh['triggers']).to include('tag')
    end
  end

  describe '.build with explicit instance_types (no profile)' do
    let(:result) do
      described_class.build(synth, base_config.merge(
        profile: nil,
        instance_types: %w[m6i.large m6i.xlarge],
        spot_allocation_strategy: :price_capacity_optimized,
      ))
      normalize_synthesis(synth.synthesis)
    end

    it 'uses the given instance types' do
      asg = validate_resource_structure(result, 'aws_autoscaling_group', 'workers-asg')
      overrides = asg.dig('mixed_instances_policy', 'launch_template', 'override')
      expect(overrides.map { |o| o['instance_type'] }).to eq(%w[m6i.large m6i.xlarge])
    end

    it 'honors the explicit allocation_strategy override' do
      asg = validate_resource_structure(result, 'aws_autoscaling_group', 'workers-asg')
      strategy = asg.dig('mixed_instances_policy', 'instances_distribution', 'spot_allocation_strategy')
      expect(strategy).to eq('price-capacity-optimized')
    end
  end

  describe '.build with on-demand floor' do
    let(:result) do
      described_class.build(synth, base_config.merge(
        on_demand_base_capacity: 1,
        on_demand_percentage_above_base: 25,
        spot_max_price: '2.50',
      ))
      normalize_synthesis(synth.synthesis)
    end

    it 'propagates on_demand_base_capacity' do
      asg = validate_resource_structure(result, 'aws_autoscaling_group', 'workers-asg')
      dist = asg.dig('mixed_instances_policy', 'instances_distribution')
      expect(dist['on_demand_base_capacity']).to eq(1)
      expect(dist['on_demand_percentage_above_base_capacity']).to eq(25)
      expect(dist['spot_max_price']).to eq('2.50')
    end
  end

  describe 'input validation' do
    it 'raises when neither profile nor instance_types is supplied' do
      expect {
        described_class.build(synth, base_config.merge(profile: nil))
      }.to raise_error(ArgumentError, /must provide either :profile or :instance_types/)
    end

    it 'raises when no launch template is supplied' do
      cfg = base_config.dup
      cfg.delete(:launch_template_id)
      expect {
        described_class.build(synth, cfg)
      }.to raise_error(ArgumentError, /launch_template/i)
    end
  end
end
