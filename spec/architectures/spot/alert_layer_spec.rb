# frozen_string_literal: true

require 'spec_helper'
require 'pangea-aws'

RSpec.describe Pangea::Architectures::Spot::AlertLayer do
  include Pangea::Testing::SynthesisTestHelpers

  let(:synth) { create_synthesizer }

  describe '.build with :nth_queue (centralized NTH)' do
    let(:result) do
      described_class.build(synth, {
        name: 'workers-alerts',
        source: :aws_eventbridge_sqs,
        forwarder: :nth_queue,
      }, asg_name: 'workers-asg')
      normalize_synthesis(synth.synthesis)
    end

    it 'emits an SQS queue with short message retention' do
      q = validate_resource_structure(result, 'aws_sqs_queue', 'workers-alerts-queue')
      expect(q['message_retention_seconds']).to eq(300)
      expect(q['sqs_managed_sse_enabled']).to eq(true)
    end

    it 'emits an EventBridge rule matching spot interruption + rebalance' do
      rule = validate_resource_structure(result, 'aws_cloudwatch_event_rule', 'workers-alerts-rule')
      pattern = JSON.parse(rule['event_pattern'])
      expect(pattern['detail-type']).to include('EC2 Spot Instance Interruption Warning')
      expect(pattern['detail-type']).to include('EC2 Instance Rebalance Recommendation')
    end

    it 'wires the event target to the SQS queue' do
      target = validate_resource_structure(result, 'aws_cloudwatch_event_target', 'workers-alerts-target')
      expect(target['target_id']).to eq('workers-alerts-sqs')
    end

    it 'emits an IAM policy granting events.amazonaws.com sqs:SendMessage' do
      policy = validate_resource_structure(result, 'aws_iam_policy', 'workers-alerts-sqs-policy')
      body = JSON.parse(policy['policy'])
      stmt = body['Statement'].first
      expect(stmt['Action']).to eq('sqs:SendMessage')
      expect(stmt['Principal']['Service']).to eq('events.amazonaws.com')
    end
  end

  describe '.build with :nth_imds (per-node DaemonSet, no cloud resources)' do
    let(:result) do
      described_class.build(synth, {
        name: 'edge-alerts',
        source: :aws_imds,
        forwarder: :nth_imds,
      }, asg_name: 'edge-asg')
      normalize_synthesis(synth.synthesis)
    end

    it 'does NOT emit an SQS queue' do
      expect(result.dig('resource', 'aws_sqs_queue')).to be_nil
    end

    it 'does NOT emit an EventBridge rule' do
      expect(result.dig('resource', 'aws_cloudwatch_event_rule')).to be_nil
    end
  end

  describe '.build with :spot_io_ocean (vendor-managed)' do
    let(:out) do
      described_class.build(synth, {
        source: :vendor_spot_io,
        forwarder: :spot_io_ocean,
      })
    end

    it 'emits no cloud resources (vendor handles interruption)' do
      out
      expect(synth.synthesis.dig('resource', 'aws_sqs_queue')).to be_nil
    end

    it 'flags the result as vendor_self_handling' do
      expect(out[:vendor_self_handling]).to eq(true)
    end
  end

  describe '.build with :required false (opt-out)' do
    let(:out) do
      described_class.build(synth, { source: :none, forwarder: :none, required: false })
    end

    it 'returns opted_out without emitting resources' do
      expect(out).to include(opted_out: true)
    end
  end

  describe 'incompatible source + forwarder combinations' do
    it 'raises when GCP metadata server paired with AWS NTH' do
      expect {
        described_class.build(synth, {
          source: :gcp_metadata_server,
          forwarder: :nth_imds,
        })
      }.to raise_error(ArgumentError, /incompatible with source/)
    end
  end

  describe 'integration: K8sJitNodePool emits the alert layer by default' do
    let(:result) do
      Pangea::Architectures::Spot::K8sJitNodePool.build(synth, {
        name: 'wk',
        image_id: 'ami-x',
        instance_profile_arn: 'arn:aws:iam::1:instance-profile/x',
        security_group_ids: %w[sg-x],
        subnet_ids: %w[subnet-x],
      })
      normalize_synthesis(synth.synthesis)
    end

    it 'tags the NTH mode on the event rule... wait, IMDS mode emits none' do
      # K8sJitNodePool defaults to :nth_imds (per-node), so no SQS queue
      # emitted. Default alert layer still validates + tags ASG.
      expect(result.dig('resource', 'aws_sqs_queue')).to be_nil
    end
  end

  describe 'integration: CiJitFleet defaults to :nth_queue and emits SQS' do
    let(:result) do
      Pangea::Architectures::Spot::CiJitFleet.build(synth, {
        name: 'gha',
        image_id: 'ami-x',
        instance_profile_arn: 'arn:aws:iam::1:instance-profile/x',
        security_group_ids: %w[sg-x],
        subnet_ids: %w[subnet-x],
        target_capacity: 5,
      })
      normalize_synthesis(synth.synthesis)
    end

    it 'emits an SQS queue for the centralized CI runner alert handler' do
      expect(result.dig('resource', 'aws_sqs_queue', 'gha-alert-queue')).not_to be_nil
    end
  end

  describe 'integration: BatchJitCompute opts out by default (Batch native re-queue)' do
    let(:result) do
      Pangea::Architectures::Spot::BatchJitCompute.build(synth, {
        name: 'genomics',
        subnet_ids: %w[subnet-x],
        security_group_ids: %w[sg-x],
        instance_role_arn: 'arn:aws:iam::1:instance-profile/batch-worker',
        service_role_arn: 'arn:aws:iam::1:role/batch-service',
        spot_iam_fleet_role_arn: 'arn:aws:iam::1:role/batch-spot-fleet',
      })
      normalize_synthesis(synth.synthesis)
    end

    it 'emits no SQS / EB rule (alert layer opted out — Batch native re-queue)' do
      expect(result.dig('resource', 'aws_sqs_queue')).to be_nil
      expect(result.dig('resource', 'aws_cloudwatch_event_rule')).to be_nil
    end
  end
end
