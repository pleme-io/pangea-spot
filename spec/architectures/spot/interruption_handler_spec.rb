# frozen_string_literal: true

require 'spec_helper'
require 'pangea-aws'

RSpec.describe Pangea::Architectures::Spot::InterruptionHandler do
  include Pangea::Testing::SynthesisTestHelpers

  let(:synth) { create_synthesizer }
  let(:base) do
    { name: 'quero-builders', policy: :graceful_terminate }
  end

  describe '.build with :graceful_terminate' do
    let(:result) do
      described_class.build(synth, base)
      normalize_synthesis(synth.synthesis)
    end

    it 'emits EventBridge rule matching spot interruption + rebalance' do
      rule = validate_resource_structure(result, 'aws_cloudwatch_event_rule', 'quero-builders-spot-rule')
      pattern = JSON.parse(rule['event_pattern'])
      expect(pattern['source']).to eq(['aws.ec2'])
      expect(pattern['detail-type']).to include('EC2 Spot Instance Interruption Warning')
      expect(pattern['detail-type']).to include('EC2 Instance Rebalance Recommendation')
    end

    it 'emits SNS topic for notifications' do
      topic = validate_resource_structure(result, 'aws_sns_topic', 'quero-builders-spot-topic')
      expect(topic['name']).to eq('quero-builders-spot-interruption')
    end

    it 'wires event target to the topic' do
      target = validate_resource_structure(result, 'aws_cloudwatch_event_target', 'quero-builders-spot-target-sns')
      expect(target['target_id']).to eq('quero-builders-spot-sns')
    end
  end

  describe '.build with :naive_terminate' do
    let(:result) do
      described_class.build(synth, name: 'cheap', policy: :naive_terminate)
      normalize_synthesis(synth.synthesis)
    end

    it 'still emits the EventBridge rule (observability)' do
      expect(result.dig('resource', 'aws_cloudwatch_event_rule', 'cheap-spot-rule')).not_to be_nil
    end

    it 'does NOT emit SNS topic' do
      expect(result.dig('resource', 'aws_sns_topic')).to be_nil
    end
  end

  describe '.build with :drain_k8s_node + lambda' do
    let(:result) do
      described_class.build(synth, {
        name: 'eks-workers',
        policy: :drain_k8s_node,
        lambda_function_arn: 'arn:aws:lambda:us-east-1:123:function:drain',
      })
      normalize_synthesis(synth.synthesis)
    end

    it 'wires event target to the Lambda ARN' do
      target = validate_resource_structure(result, 'aws_cloudwatch_event_target', 'eks-workers-spot-target-lambda')
      expect(target['arn']).to eq('arn:aws:lambda:us-east-1:123:function:drain')
    end

    it 'grants EventBridge permission to invoke the lambda' do
      perm = validate_resource_structure(result, 'aws_lambda_permission', 'eks-workers-spot-lambda-perm')
      expect(perm['principal']).to eq('events.amazonaws.com')
    end
  end

  describe '.build with :asg_name' do
    let(:result) do
      described_class.build(synth, {
        name: 'workers',
        policy: :graceful_terminate,
        asg_name: 'workers-asg',
        lifecycle_heartbeat_timeout: 300,
      })
      normalize_synthesis(synth.synthesis)
    end

    it 'emits ASG lifecycle hook holding terminating instances' do
      hook = validate_resource_structure(result, 'aws_autoscaling_lifecycle_hook', 'workers-spot-lifecycle')
      expect(hook['lifecycle_transition']).to eq('autoscaling:EC2_INSTANCE_TERMINATING')
      expect(hook['heartbeat_timeout']).to eq(300)
    end
  end

  describe '.build with :include_rebalance_events: false' do
    let(:result) do
      described_class.build(synth, base.merge(include_rebalance_events: false))
      normalize_synthesis(synth.synthesis)
    end

    it 'event pattern only captures spot interruption' do
      rule = validate_resource_structure(result, 'aws_cloudwatch_event_rule', 'quero-builders-spot-rule')
      pattern = JSON.parse(rule['event_pattern'])
      expect(pattern['detail-type']).to eq(['EC2 Spot Instance Interruption Warning'])
    end
  end

  describe 'policy validation' do
    it 'refuses unknown policy' do
      expect {
        described_class.build(synth, name: 'x', policy: :nuke_it)
      }.to raise_error(ArgumentError)
    end
  end
end
