# frozen_string_literal: true

require 'spec_helper'
require 'pangea-aws'

RSpec.describe Pangea::Architectures::Spot::K8sJitNodePool do
  include Pangea::Testing::SynthesisTestHelpers

  let(:synth) { create_synthesizer }
  let(:base_config) do
    {
      name: 'workers',
      image_id: 'ami-0abcdef1234567890',
      instance_profile_arn: 'arn:aws:iam::123:instance-profile/workers',
      security_group_ids: %w[sg-aaa],
      subnet_ids: %w[subnet-aaa subnet-bbb],
      min_size: 0,
      max_size: 10,
      desired_capacity: 2,
      node_labels: { workload: 'general' },
      node_taints: [{ key: 'spot', value: 'true', effect: 'NoSchedule' }],
    }
  end

  describe '.build with defaults (profile :karpenter_general)' do
    let(:result) do
      described_class.build(synth, base_config)
      normalize_synthesis(synth.synthesis)
    end

    it 'emits a launch template named {name}-lt with IMDSv2 required' do
      lt = validate_resource_structure(result, 'aws_launch_template', 'workers-lt')
      expect(lt['image_id']).to eq('ami-0abcdef1234567890')
      expect(lt.dig('metadata_options', 'http_tokens')).to eq('required')
    end

    it 'propagates node_labels + node_taints as instance tags for discovery' do
      lt = validate_resource_structure(result, 'aws_launch_template', 'workers-lt')
      inst_tags = lt['tag_specifications'].first['tags']
      expect(JSON.parse(inst_tags['NodeLabels'])).to eq({ 'workload' => 'general' })
      expect(JSON.parse(inst_tags['NodeTaints']).first).to include('key' => 'spot')
    end

    it 'tags the LT with the resolved spot profile + category' do
      lt = validate_resource_structure(result, 'aws_launch_template', 'workers-lt')
      inst_tags = lt['tag_specifications'].first['tags']
      expect(inst_tags['SpotProfile']).to eq('karpenter_general')
      expect(inst_tags['SpotCategory']).to eq('k8s_workers')
    end

    it 'emits an ASG with mixed_instances_policy (from MixedInstancesAsg composition)' do
      asg = validate_resource_structure(result, 'aws_autoscaling_group', 'workers-asg')
      expect(asg.dig('mixed_instances_policy', 'launch_template', 'launch_template_specification')).not_to be_nil
    end

    it 'keeps capacity_rebalance + instance_refresh on by default (utility preservation)' do
      asg = validate_resource_structure(result, 'aws_autoscaling_group', 'workers-asg')
      expect(asg['capacity_rebalance']).to eq(true)
      expect(asg.dig('instance_refresh', 'strategy')).to eq('Rolling')
    end

    it 'wires the interruption handler with :drain_k8s_node policy' do
      rule = validate_resource_structure(result, 'aws_cloudwatch_event_rule', 'workers-spot-rule')
      # EventBridge rule tagged with SpotPolicy
      expect(rule['tags']['SpotPolicy']).to eq('drain_k8s_node')
    end

    it 'emits an ASG lifecycle hook (heartbeat 300s default)' do
      hook = validate_resource_structure(result, 'aws_autoscaling_lifecycle_hook', 'workers-spot-lifecycle')
      expect(hook['heartbeat_timeout']).to eq(300)
      expect(hook['lifecycle_transition']).to eq('autoscaling:EC2_INSTANCE_TERMINATING')
    end
  end

  describe '.build with lambda_drain_arn' do
    let(:result) do
      described_class.build(synth, base_config.merge(
        lambda_drain_arn: 'arn:aws:lambda:us-east-1:123:function:drain-worker',
      ))
      normalize_synthesis(synth.synthesis)
    end

    it 'routes the EventBridge target to the Lambda' do
      target = validate_resource_structure(result, 'aws_cloudwatch_event_target', 'workers-spot-target-lambda')
      expect(target['arn']).to eq('arn:aws:lambda:us-east-1:123:function:drain-worker')
    end

    it 'grants EventBridge permission to invoke the Lambda' do
      perm = validate_resource_structure(result, 'aws_lambda_permission', 'workers-spot-lambda-perm')
      expect(perm['principal']).to eq('events.amazonaws.com')
    end
  end

  describe '.build with on-demand floor' do
    let(:result) do
      described_class.build(synth, base_config.merge(
        on_demand_base_capacity: 1,
        on_demand_percentage_above_base: 50,
      ))
      normalize_synthesis(synth.synthesis)
    end

    it 'propagates the on-demand base to the ASG instances_distribution' do
      asg = validate_resource_structure(result, 'aws_autoscaling_group', 'workers-asg')
      dist = asg.dig('mixed_instances_policy', 'instances_distribution')
      expect(dist['on_demand_base_capacity']).to eq(1)
      expect(dist['on_demand_percentage_above_base_capacity']).to eq(50)
    end
  end

  describe 'input validation' do
    it 'raises when required image_id is missing' do
      cfg = base_config.dup
      cfg.delete(:image_id)
      expect { described_class.build(synth, cfg) }.to raise_error(ArgumentError)
    end
  end
end
