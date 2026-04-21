# frozen_string_literal: true

require 'spec_helper'
require 'pangea-aws'

RSpec.describe Pangea::Architectures::Spot::ZotJitService do
  include Pangea::Testing::SynthesisTestHelpers

  let(:synth) { create_synthesizer }
  let(:base_config) do
    {
      name: 'registry',
      image_id: 'ami-0zot',
      instance_profile_arn: 'arn:aws:iam::123:instance-profile/zot',
      security_group_ids: %w[sg-zot],
      subnet_ids: %w[subnet-aaa subnet-bbb],
      domain: 'pleme.lol',
      public_zone_id: 'Z456',
    }
  end

  describe '.build with defaults (no TLS, no auth)' do
    let(:result) do
      described_class.build(synth, base_config)
      normalize_synthesis(synth.synthesis)
    end

    it 'creates an S3 state bucket for manifests + layers' do
      bucket = validate_resource_structure(result, 'aws_s3_bucket', 'registry-zot-bucket')
      expect(bucket['bucket']).to eq('registry-zot-registry')
    end

    it 'emits an NLB listener on port 5000 TCP (no TLS)' do
      listener = validate_resource_structure(result, 'aws_lb_listener', 'registry-zot-listener')
      expect(listener['port']).to eq(5000)
      expect(listener['protocol']).to eq('TCP')
      expect(listener['certificate_arn']).to be_nil
    end

    it 'tags the launch template with the zot bucket name' do
      lt = validate_resource_structure(result, 'aws_launch_template', 'registry-zot-lt')
      inst_tags = lt['tag_specifications'].first['tags']
      expect(inst_tags['ZotBucket']).to eq('registry-zot-registry')
      expect(inst_tags['Service']).to eq('zot')
    end

    it 'does NOT propagate an htpasswd secret tag when none supplied' do
      lt = validate_resource_structure(result, 'aws_launch_template', 'registry-zot-lt')
      inst_tags = lt['tag_specifications'].first['tags']
      expect(inst_tags).not_to have_key('ZotHtpasswdSecretArn')
    end

    it 'CNAME routes {name}.{domain} → NLB' do
      rec = validate_resource_structure(result, 'aws_route53_record', 'registry-zot-cname')
      expect(rec['name']).to eq('registry.pleme.lol')
    end

    it 'emits a quiescent scale-to-zero alarm' do
      alarm = validate_resource_structure(result, 'aws_cloudwatch_metric_alarm', 'registry-zot-quiescent')
      expect(alarm['namespace']).to eq('Pleme/ZotRegistry')
    end
  end

  describe '.build with TLS (acm_cert_arn)' do
    let(:result) do
      described_class.build(synth, base_config.merge(
        acm_cert_arn: 'arn:aws:acm:us-east-1:123:certificate/abc',
      ))
      normalize_synthesis(synth.synthesis)
    end

    it 'terminates TLS at the NLB on port 443' do
      listener = validate_resource_structure(result, 'aws_lb_listener', 'registry-zot-listener')
      expect(listener['port']).to eq(443)
      expect(listener['protocol']).to eq('TLS')
      expect(listener['certificate_arn']).to eq('arn:aws:acm:us-east-1:123:certificate/abc')
      expect(listener['ssl_policy']).to match(/TLS13/)
    end
  end

  describe '.build with htpasswd auth secret' do
    let(:result) do
      described_class.build(synth, base_config.merge(
        htpasswd_secret_arn: 'arn:aws:secretsmanager:us-east-1:123:secret:zot-htpasswd',
      ))
      normalize_synthesis(synth.synthesis)
    end

    it 'propagates the secret ARN as an instance tag' do
      lt = validate_resource_structure(result, 'aws_launch_template', 'registry-zot-lt')
      inst_tags = lt['tag_specifications'].first['tags']
      expect(inst_tags['ZotHtpasswdSecretArn']).to include('zot-htpasswd')
    end
  end

  describe 'input validation' do
    it 'raises when public_zone_id is missing' do
      cfg = base_config.dup
      cfg.delete(:public_zone_id)
      expect { described_class.build(synth, cfg) }.to raise_error(ArgumentError)
    end
  end
end
