# frozen_string_literal: true

require 'spec_helper'
require 'pangea-aws'

RSpec.describe Pangea::Architectures::Spot::FluxJitController do
  include Pangea::Testing::SynthesisTestHelpers

  let(:synth) { create_synthesizer }
  let(:base_config) do
    {
      name: 'quero',
      image_id: 'ami-0flux',
      instance_profile_arn: 'arn:aws:iam::123:instance-profile/flux',
      security_group_ids: %w[sg-flux],
      subnet_ids: %w[subnet-aaa subnet-bbb],
    }
  end

  describe '.build with defaults' do
    let(:result) do
      described_class.build(synth, base_config)
      normalize_synthesis(synth.synthesis)
    end

    it 'composes a K8sJitNodePool named {name}-flux' do
      asg = validate_resource_structure(result, 'aws_autoscaling_group', 'quero-flux-asg')
      # Utility guardrail: min_size defaults to 1 so controller-manager stays alive
      expect(asg['min_size']).to eq(1)
      expect(asg['desired_capacity']).to eq(1)
    end

    it 'does NOT emit an NLB (FluxCD has no inbound service)' do
      expect(result.dig('resource', 'aws_lb')).to be_nil
    end

    it 'does NOT emit an S3 bucket (Git is the durable layer)' do
      expect(result.dig('resource', 'aws_s3_bucket')).to be_nil
    end

    it 'tags instances with role=flux-system for NodeSelector matching' do
      lt = validate_resource_structure(result, 'aws_launch_template', 'quero-flux-lt')
      inst_tags = lt['tag_specifications'].first['tags']
      expect(JSON.parse(inst_tags['NodeLabels'])).to eq({ 'role' => 'flux-system' })
    end

    it 'defaults node_taints to dedicated=flux-system:NoSchedule' do
      lt = validate_resource_structure(result, 'aws_launch_template', 'quero-flux-lt')
      inst_tags = lt['tag_specifications'].first['tags']
      taints = JSON.parse(inst_tags['NodeTaints'])
      expect(taints.first).to include(
        'key' => 'dedicated',
        'value' => 'flux-system',
        'effect' => 'NoSchedule',
      )
    end
  end

  describe '.build with git_repo_url' do
    let(:result) do
      described_class.build(synth, base_config.merge(
        git_repo_url: 'git@github.com:pleme-io/k8s.git',
      ))
      normalize_synthesis(synth.synthesis)
    end

    it 'propagates the git repo url in launch template tags' do
      lt = validate_resource_structure(result, 'aws_launch_template', 'quero-flux-lt')
      # git_repo_url lands on the ASG-level tags via K8sJitNodePool → MixedInstancesAsg
      asg = validate_resource_structure(result, 'aws_autoscaling_group', 'quero-flux-asg')
      asg_tags = asg['tag'] || []
      flux_url_tag = asg_tags.find { |t| t['key'] == 'FluxGitRepoUrl' }
      expect(flux_url_tag).not_to be_nil
      expect(flux_url_tag['value']).to include('pleme-io/k8s.git')
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
