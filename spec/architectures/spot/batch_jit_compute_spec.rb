# frozen_string_literal: true

require 'spec_helper'
require 'pangea-aws'

RSpec.describe Pangea::Architectures::Spot::BatchJitCompute do
  include Pangea::Testing::SynthesisTestHelpers

  let(:synth) { create_synthesizer }
  let(:base_config) do
    {
      name: 'genomics',
      subnet_ids: %w[subnet-aaa subnet-bbb],
      security_group_ids: %w[sg-batch],
      instance_role_arn: 'arn:aws:iam::123:instance-profile/batch-worker',
      service_role_arn: 'arn:aws:iam::123:role/batch-service',
      spot_iam_fleet_role_arn: 'arn:aws:iam::123:role/batch-spot-fleet',
    }
  end

  describe '.build with defaults (profile :batch_compute, compute_type :spot)' do
    let(:result) do
      described_class.build(synth, base_config)
      normalize_synthesis(synth.synthesis)
    end

    it 'emits an aws_batch_compute_environment named {name}-ce' do
      ce = validate_resource_structure(result, 'aws_batch_compute_environment', 'genomics-ce')
      expect(ce['name']).to eq('genomics-ce')
      expect(ce['type']).to eq('MANAGED')
      expect(ce['state']).to eq('ENABLED')
    end

    it 'compute_resources are TYPE=SPOT with SPOT_PRICE_CAPACITY_OPTIMIZED allocation' do
      ce = validate_resource_structure(result, 'aws_batch_compute_environment', 'genomics-ce')
      cr = ce['compute_resources']
      expect(cr['type']).to eq('SPOT')
      expect(cr['allocation_strategy']).to eq('SPOT_PRICE_CAPACITY_OPTIMIZED')
    end

    it 'propagates min/max/desired vcpus defaults (0/256/0 — scale-to-zero)' do
      ce = validate_resource_structure(result, 'aws_batch_compute_environment', 'genomics-ce')
      cr = ce['compute_resources']
      expect(cr['min_vcpus']).to eq(0)
      expect(cr['max_vcpus']).to eq(256)
      expect(cr['desired_vcpus']).to eq(0)
    end

    it 'uses the profile instance types (batch_compute → genomics_spot pool)' do
      ce = validate_resource_structure(result, 'aws_batch_compute_environment', 'genomics-ce')
      cr = ce['compute_resources']
      expect(cr['instance_type']).not_to be_empty
    end

    it 'propagates the spot fleet role for spot compute type' do
      ce = validate_resource_structure(result, 'aws_batch_compute_environment', 'genomics-ce')
      cr = ce['compute_resources']
      expect(cr['spot_iam_fleet_role']).to eq('arn:aws:iam::123:role/batch-spot-fleet')
    end

    it 'emits an aws_batch_job_queue bound to the compute environment' do
      q = validate_resource_structure(result, 'aws_batch_job_queue', 'genomics-queue')
      expect(q['name']).to eq('genomics-queue')
      expect(q['state']).to eq('ENABLED')
      expect(q['priority']).to eq(100)
      expect(q['compute_environment_order'].size).to eq(1)
      expect(q['compute_environment_order'].first['order']).to eq(1)
    end
  end

  describe '.build with compute_type :ec2 (on-demand batch pool)' do
    let(:result) do
      cfg = base_config.dup
      cfg.delete(:spot_iam_fleet_role_arn) # not needed for :ec2
      described_class.build(synth, cfg.merge(compute_type: :ec2))
      normalize_synthesis(synth.synthesis)
    end

    it 'compute_resources.type = EC2 with BEST_FIT_PROGRESSIVE' do
      ce = validate_resource_structure(result, 'aws_batch_compute_environment', 'genomics-ce')
      cr = ce['compute_resources']
      expect(cr['type']).to eq('EC2')
      expect(cr['allocation_strategy']).to eq('BEST_FIT_PROGRESSIVE')
    end
  end

  describe '.build with bid_percentage' do
    let(:result) do
      described_class.build(synth, base_config.merge(bid_percentage: 75))
      normalize_synthesis(synth.synthesis)
    end

    it 'propagates bid_percentage to compute_resources' do
      ce = validate_resource_structure(result, 'aws_batch_compute_environment', 'genomics-ce')
      expect(ce['compute_resources']['bid_percentage']).to eq(75)
    end
  end

  describe 'input validation' do
    it 'raises when spot_iam_fleet_role_arn missing on :spot compute type' do
      cfg = base_config.dup
      cfg.delete(:spot_iam_fleet_role_arn)
      expect {
        described_class.build(synth, cfg)
      }.to raise_error(ArgumentError, /spot_iam_fleet_role_arn/)
    end

    it 'raises when service_role_arn missing' do
      cfg = base_config.dup
      cfg.delete(:service_role_arn)
      expect { described_class.build(synth, cfg) }.to raise_error(ArgumentError)
    end
  end
end
