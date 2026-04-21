# frozen_string_literal: true

require 'spec_helper'
require 'pangea-aws'

RSpec.describe Pangea::Architectures::Spot::PackerJitBake do
  include Pangea::Testing::SynthesisTestHelpers

  let(:synth) { create_synthesizer }
  let(:base_config) { { name: 'quero' } }

  describe '.build with defaults (profile :beefy_spot)' do
    let(:result) do
      described_class.build(synth, base_config)
      normalize_synthesis(synth.synthesis)
    end

    it 'emits an SSM parameter holding the spot instance types list (StringList)' do
      param = validate_resource_structure(result, 'aws_ssm_parameter', 'quero-spot-instance-types')
      expect(param['name']).to eq('/pangea/quero/packer/spot-instance-types')
      expect(param['type']).to eq('StringList')
      # 18 instance types in beefy_spot pool
      types = param['value'].split(',')
      expect(types.size).to eq(18)
      expect(types).to include('c7g.16xlarge', 'r7g.8xlarge')
    end

    it 'emits an SSM parameter holding the spot price ceiling' do
      param = validate_resource_structure(result, 'aws_ssm_parameter', 'quero-spot-price')
      expect(param['name']).to eq('/pangea/quero/packer/spot-price')
      expect(param['value']).to eq('2.50')
      expect(param['type']).to eq('String')
    end

    it 'emits an SSM parameter holding the AWS-formatted allocation strategy' do
      param = validate_resource_structure(result, 'aws_ssm_parameter', 'quero-spot-allocation-strategy')
      expect(param['name']).to eq('/pangea/quero/packer/spot-allocation-strategy')
      # nix_builder category default is :capacity_optimized → hyphen form
      expect(param['value']).to eq('capacity-optimized')
    end

    it 'tags every SSM parameter with the profile name + category' do
      param = validate_resource_structure(result, 'aws_ssm_parameter', 'quero-spot-price')
      expect(param['tags']['SpotProfile']).to eq('beefy_spot')
      expect(param['tags']['SpotCategory']).to eq('nix_builder')
      expect(param['tags']['ManagedBy']).to eq('pangea-spot')
    end
  end

  describe '.build with custom ssm_param_prefix' do
    let(:result) do
      described_class.build(synth, base_config.merge(ssm_param_prefix: '/my/custom/prefix'))
      normalize_synthesis(synth.synthesis)
    end

    it 'honors the prefix override' do
      param = validate_resource_structure(result, 'aws_ssm_parameter', 'quero-spot-instance-types')
      expect(param['name']).to eq('/my/custom/prefix/spot-instance-types')
    end
  end

  describe '.build with custom profile + price' do
    let(:result) do
      described_class.build(synth, base_config.merge(profile: :memory_heavy, spot_price: '3.00'))
      normalize_synthesis(synth.synthesis)
    end

    it 'uses the memory_heavy instance list' do
      param = validate_resource_structure(result, 'aws_ssm_parameter', 'quero-spot-instance-types')
      types = param['value'].split(',')
      expect(types).to include('r7g.16xlarge')
    end

    it 'propagates the custom spot_price' do
      param = validate_resource_structure(result, 'aws_ssm_parameter', 'quero-spot-price')
      expect(param['value']).to eq('3.00')
    end
  end

  describe 'input validation' do
    it 'raises when profile is unknown' do
      expect {
        described_class.build(synth, base_config.merge(profile: :no_such_profile))
      }.to raise_error(ArgumentError, /unknown.*profile/i)
    end
  end
end
