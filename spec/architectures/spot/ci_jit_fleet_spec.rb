# frozen_string_literal: true

require 'spec_helper'
require 'pangea-aws'

RSpec.describe Pangea::Architectures::Spot::CiJitFleet do
  include Pangea::Testing::SynthesisTestHelpers

  let(:synth) { create_synthesizer }
  let(:base_config) do
    {
      name: 'gha-runners',
      image_id: 'ami-0gharunner',
      instance_profile_arn: 'arn:aws:iam::123:instance-profile/gha',
      security_group_ids: %w[sg-gha],
      subnet_ids: %w[subnet-aaa subnet-bbb],
      target_capacity: 5,
    }
  end

  describe '.build with defaults (profile :gh_actions_large)' do
    let(:result) do
      described_class.build(synth, base_config)
      normalize_synthesis(synth.synthesis)
    end

    it 'emits a launch template pinned to the CI runner image' do
      lt = validate_resource_structure(result, 'aws_launch_template', 'gha-runners-lt')
      expect(lt['image_id']).to eq('ami-0gharunner')
      expect(lt.dig('metadata_options', 'http_tokens')).to eq('required')
    end

    it 'tags instances with the spot profile + category' do
      lt = validate_resource_structure(result, 'aws_launch_template', 'gha-runners-lt')
      inst_tags = lt['tag_specifications'].first['tags']
      expect(inst_tags['SpotProfile']).to eq('gh_actions_large')
      expect(inst_tags['SpotCategory']).to eq('ci_runner')
      expect(inst_tags['CiPool']).to eq('gha-runners')
    end

    it 'emits an EC2 Fleet (from Ec2Fleet composition) defaulting to :maintain' do
      fleet = validate_resource_structure(result, 'aws_ec2_fleet', 'gha-runners-fleet')
      expect(fleet['type']).to eq('maintain')
      expect(fleet['target_capacity_specification']['total_target_capacity']).to eq(5)
    end

    it 'wires the interruption handler with :naive_terminate (observability only, no drain)' do
      rule = validate_resource_structure(result, 'aws_cloudwatch_event_rule', 'gha-runners-spot-rule')
      expect(rule['tags']['SpotPolicy']).to eq('naive_terminate')
    end

    it 'does NOT emit an SNS topic (naive_terminate does not need one)' do
      expect(result.dig('resource', 'aws_sns_topic')).to be_nil
    end
  end

  describe '.build with runner registration secret' do
    let(:result) do
      described_class.build(synth, base_config.merge(
        runner_registration_token_secret_arn: 'arn:aws:secretsmanager:us-east-1:123:secret:gh-runner-token',
      ))
      normalize_synthesis(synth.synthesis)
    end

    it 'propagates the secret ARN as an instance tag for cascade discovery' do
      lt = validate_resource_structure(result, 'aws_launch_template', 'gha-runners-lt')
      inst_tags = lt['tag_specifications'].first['tags']
      expect(inst_tags['RunnerTokenSecretArn']).to include('gh-runner-token')
    end
  end

  describe '.build with fleet_type :instant (burst CI)' do
    let(:result) do
      described_class.build(synth, base_config.merge(fleet_type: :instant))
      normalize_synthesis(synth.synthesis)
    end

    it 'sets fleet type to instant' do
      fleet = validate_resource_structure(result, 'aws_ec2_fleet', 'gha-runners-fleet')
      expect(fleet['type']).to eq('instant')
    end
  end

  describe 'input validation' do
    it 'raises when target_capacity is missing' do
      cfg = base_config.dup
      cfg.delete(:target_capacity)
      expect { described_class.build(synth, cfg) }.to raise_error(ArgumentError)
    end
  end
end
