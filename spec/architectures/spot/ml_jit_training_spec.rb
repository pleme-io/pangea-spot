# frozen_string_literal: true

require 'spec_helper'
require 'pangea-aws'

RSpec.describe Pangea::Architectures::Spot::MlJitTraining do
  include Pangea::Testing::SynthesisTestHelpers

  let(:synth) { create_synthesizer }
  let(:base_config) do
    {
      name: 'llama-train',
      image_id: 'ami-0gpu',
      instance_profile_arn: 'arn:aws:iam::123:instance-profile/ml',
      security_group_ids: %w[sg-ml],
      subnet_ids: %w[subnet-aaa subnet-bbb],
    }
  end

  describe '.build with defaults (profile :karpenter_gpu)' do
    let(:result) do
      described_class.build(synth, base_config)
      normalize_synthesis(synth.synthesis)
    end

    it 'creates the checkpoint S3 bucket' do
      bucket = validate_resource_structure(result, 'aws_s3_bucket', 'llama-train-ml-bucket')
      expect(bucket['bucket']).to eq('llama-train-ml-checkpoints')
    end

    it 'ensures versioning on the checkpoint bucket (point-in-time restore)' do
      ver = validate_resource_structure(result, 'aws_s3_bucket_versioning', 'llama-train-ml-bucket-versioning')
      expect(ver.dig('versioning_configuration', 'status')).to eq('Enabled')
    end

    it 'composes a K8sJitNodePool with GPU-small defaults (min=0, max=4)' do
      asg = validate_resource_structure(result, 'aws_autoscaling_group', 'llama-train-ml-asg')
      expect(asg['min_size']).to eq(0)
      expect(asg['max_size']).to eq(4)
    end

    it 'uses :checkpoint_job interruption policy (not :drain_k8s_node)' do
      rule = validate_resource_structure(result, 'aws_cloudwatch_event_rule', 'llama-train-ml-spot-rule')
      expect(rule['tags']['SpotPolicy']).to eq('checkpoint_job')
    end

    it 'propagates CheckpointCadence + CheckpointStorageUri as instance tags' do
      lt = validate_resource_structure(result, 'aws_launch_template', 'llama-train-ml-lt')
      inst_tags = lt['tag_specifications'].first['tags']
      expect(inst_tags['CheckpointCadence']).to eq('30')
      expect(inst_tags['CheckpointStorageUri']).to eq('s3://llama-train-ml-checkpoints/llama-train/checkpoints')
      expect(inst_tags['CheckpointBucket']).to eq('llama-train-ml-checkpoints')
      expect(inst_tags['ResumeFromLatest']).to eq('true')
    end

    it 'applies the ml-training taint so only training pods schedule here' do
      lt = validate_resource_structure(result, 'aws_launch_template', 'llama-train-ml-lt')
      inst_tags = lt['tag_specifications'].first['tags']
      taints = JSON.parse(inst_tags['NodeTaints'])
      expect(taints.first).to include('key' => 'workload', 'value' => 'ml-training')
    end
  end

  describe '.build with lambda_checkpoint_arn' do
    let(:result) do
      described_class.build(synth, base_config.merge(
        lambda_checkpoint_arn: 'arn:aws:lambda:us-east-1:123:function:ml-checkpoint',
      ))
      normalize_synthesis(synth.synthesis)
    end

    it 'wires the EventBridge target to the checkpoint Lambda' do
      target = validate_resource_structure(result, 'aws_cloudwatch_event_target', 'llama-train-ml-spot-target-lambda')
      expect(target['arn']).to eq('arn:aws:lambda:us-east-1:123:function:ml-checkpoint')
    end

    it 'grants EventBridge permission to invoke the checkpoint Lambda' do
      perm = validate_resource_structure(result, 'aws_lambda_permission', 'llama-train-ml-spot-lambda-perm')
      expect(perm['principal']).to eq('events.amazonaws.com')
    end
  end

  describe '.build with aggressive checkpoint cadence' do
    let(:result) do
      described_class.build(synth, base_config.merge(checkpoint_cadence_minutes: 5))
      normalize_synthesis(synth.synthesis)
    end

    it 'honors the caller-supplied cadence' do
      lt = validate_resource_structure(result, 'aws_launch_template', 'llama-train-ml-lt')
      inst_tags = lt['tag_specifications'].first['tags']
      expect(inst_tags['CheckpointCadence']).to eq('5')
    end
  end

  describe 'input validation' do
    it 'raises when image_id is missing' do
      cfg = base_config.dup
      cfg.delete(:image_id)
      expect { described_class.build(synth, cfg) }.to raise_error(ArgumentError)
    end
  end
end
