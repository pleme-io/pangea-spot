# frozen_string_literal: true

require 'spec_helper'
require 'pangea-aws'

RSpec.describe Pangea::Architectures::Spot::AtticJitService do
  include Pangea::Testing::SynthesisTestHelpers

  let(:synth) { create_synthesizer }
  let(:base_config) do
    {
      name: 'cache',
      image_id: 'ami-0attic',
      instance_profile_arn: 'arn:aws:iam::123:instance-profile/attic',
      security_group_ids: %w[sg-attic],
      subnet_ids: %w[subnet-aaa subnet-bbb],
      domain: 'pleme.lol',
      public_zone_id: 'Z123',
    }
  end

  describe '.build with defaults' do
    let(:result) do
      described_class.build(synth, base_config)
      normalize_synthesis(synth.synthesis)
    end

    it 'creates an S3 state bucket with the default name' do
      bucket = validate_resource_structure(result, 'aws_s3_bucket', 'cache-attic-bucket')
      expect(bucket['bucket']).to eq('cache-attic-cache')
    end

    it 'enables versioning on the state bucket' do
      ver = validate_resource_structure(result, 'aws_s3_bucket_versioning', 'cache-attic-bucket-versioning')
      expect(ver.dig('versioning_configuration', 'status')).to eq('Enabled')
    end

    it 'blocks all public access on the bucket' do
      pab = validate_resource_structure(result, 'aws_s3_bucket_public_access_block', 'cache-attic-bucket-pab')
      expect(pab['block_public_acls']).to eq(true)
      expect(pab['restrict_public_buckets']).to eq(true)
    end

    it 'composes a K8sJitNodePool (ASG emitted)' do
      asg = validate_resource_structure(result, 'aws_autoscaling_group', 'cache-attic-asg')
      expect(asg['min_size']).to eq(0)
      expect(asg['max_size']).to eq(2)
    end

    it 'emits a public NLB on port 8080' do
      listener = validate_resource_structure(result, 'aws_lb_listener', 'cache-attic-listener')
      expect(listener['port']).to eq(8080)
      expect(listener['protocol']).to eq('TCP')
    end

    it 'CNAME routes {name}.{domain} → NLB' do
      rec = validate_resource_structure(result, 'aws_route53_record', 'cache-attic-cname')
      expect(rec['name']).to eq('cache.pleme.lol')
      expect(rec['zone_id']).to eq('Z123')
      expect(rec['type']).to eq('CNAME')
    end

    it 'emits a quiescent scale-to-zero policy + alarm on default 1800s idle' do
      alarm = validate_resource_structure(result, 'aws_cloudwatch_metric_alarm', 'cache-attic-quiescent')
      expect(alarm['period']).to eq(1800)
      expect(alarm['namespace']).to eq('Pleme/AtticCache')
      expect(alarm['comparison_operator']).to eq('LessThanOrEqualToThreshold')

      policy = validate_resource_structure(result, 'aws_autoscaling_policy', 'cache-attic-scale-to-zero')
      expect(policy['adjustment_type']).to eq('ExactCapacity')
      expect(policy['scaling_adjustment']).to eq(0)
    end

    it 'tags the launch template with the attic bucket name for AMI user_data discovery' do
      lt = validate_resource_structure(result, 'aws_launch_template', 'cache-attic-lt')
      inst_tags = lt['tag_specifications'].first['tags']
      expect(inst_tags['AtticBucket']).to eq('cache-attic-cache')
      expect(inst_tags['Service']).to eq('attic')
    end
  end

  describe '.build with custom bucket + idle threshold' do
    let(:result) do
      described_class.build(synth, base_config.merge(
        s3_bucket_name: 'my-existing-attic',
        idle_threshold_secs: 300,
      ))
      normalize_synthesis(synth.synthesis)
    end

    it 'honors the provided bucket name' do
      bucket = validate_resource_structure(result, 'aws_s3_bucket', 'cache-attic-bucket')
      expect(bucket['bucket']).to eq('my-existing-attic')
    end

    it 'honors the shorter idle threshold' do
      alarm = validate_resource_structure(result, 'aws_cloudwatch_metric_alarm', 'cache-attic-quiescent')
      expect(alarm['period']).to eq(300)
    end
  end

  describe 'input validation' do
    it 'raises when domain is missing' do
      cfg = base_config.dup
      cfg.delete(:domain)
      expect { described_class.build(synth, cfg) }.to raise_error(ArgumentError)
    end
  end
end
