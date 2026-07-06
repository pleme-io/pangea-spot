# frozen_string_literal: true

require 'spec_helper'
require 'pangea/spot/catalog'
require 'pangea/spot/allocation'

RSpec.describe Pangea::Spot::Catalog do
  describe '.all' do
    it 'exposes ≥20 typed profiles' do
      expect(described_class.all.size).to be >= 20
    end

    it 'covers nine categories' do
      categories = described_class.all.values.map { |p| p[:category] }.uniq
      expect(categories).to contain_exactly(
        :nix_builder, :k8s_workers, :ci_runner, :ml_training,
        :batch_compute, :ephemeral_runner, :memory_heavy,
        :storage_heavy, :network_heavy,
      )
    end

    it 'every profile declares the required fields' do
      described_class.all.each do |name, p|
        %i[category instance_types recommended_allocation
           on_demand_base_capacity on_demand_percentage_above_base
           spot_max_price notes].each do |field|
          expect(p).to have_key(field), "#{name} missing #{field}"
        end
      end
    end

    it 'every spot_max_price is a decimal string' do
      described_class.all.each do |name, p|
        expect(p[:spot_max_price]).to match(/\A\d+(\.\d+)?\z/), "#{name}: #{p[:spot_max_price].inspect}"
      end
    end

    it 'every recommended_allocation is a known strategy' do
      strategies = Pangea::Spot::Allocation::STRATEGIES
      described_class.all.each do |name, p|
        expect(strategies).to include(p[:recommended_allocation]), "#{name}: #{p[:recommended_allocation]}"
      end
    end
  end

  describe '.fetch' do
    it 'returns a profile by name' do
      prof = described_class.fetch(:beefy_spot)
      expect(prof[:category]).to eq(:nix_builder)
    end

    it 'raises on unknown profile' do
      expect { described_class.fetch(:nope) }.to raise_error(ArgumentError, /unknown Spot profile/)
    end
  end

  describe '.in_category' do
    it 'returns only profiles in the named category' do
      nix = described_class.in_category(:nix_builder)
      expect(nix.keys).to include(
        :beefy_spot, :balanced, :legacy,
        :beefy_spot_amd64, :memory_heavy_amd64,
      )
      nix.values.each { |p| expect(p[:category]).to eq(:nix_builder) }
    end

    it 'nix_builder spans both arches (arm64 + amd64 mirrors)' do
      nix = described_class.in_category(:nix_builder)
      expect(nix.keys).to include(:beefy_spot, :memory_heavy)            # arm64
      expect(nix.keys).to include(:beefy_spot_amd64, :memory_heavy_amd64) # amd64
    end

    it 'k8s_workers spans ≥5 profiles' do
      expect(described_class.in_category(:k8s_workers).size).to be >= 5
    end

    it 'ml_training spans ≥4 profiles (g5, p4d, trainium, inferentia)' do
      expect(described_class.in_category(:ml_training).size).to be >= 4
    end
  end

  describe '.resolve' do
    it 'expands a YAML fleet config to concrete knobs' do
      out = described_class.resolve({ 'instance_type_profile' => 'beefy_spot' })
      expect(out[:profile]).to eq(:beefy_spot)
      expect(out[:category]).to eq(:nix_builder)
      expect(out[:instance_types]).to include('c7g.16xlarge')
      expect(out[:allocation_strategy]).to eq(:capacity_optimized)
    end

    it 'falls back to default when no profile is set' do
      out = described_class.resolve({}, default: :balanced)
      expect(out[:profile]).to eq(:balanced)
    end

    it 'per-field override wins over profile preset' do
      out = described_class.resolve({
        'instance_type_profile' => 'beefy_spot',
        'spot_max_price' => '5.00',
      })
      expect(out[:spot_max_price]).to eq('5.00')
      expect(out[:profile]).to eq(:beefy_spot)
    end

    it 'k8s karpenter_general expands to mixed arm/x86' do
      out = described_class.resolve({ 'instance_type_profile' => 'karpenter_general' })
      expect(out[:instance_types].any? { |t| t.start_with?('c7g') }).to eq(true)
      expect(out[:instance_types].any? { |t| t.start_with?('c7i') }).to eq(true)
    end

    it 'p4d_spot uses capacity_optimized allocation' do
      out = described_class.resolve({ 'instance_type_profile' => 'p4d_spot' })
      expect(out[:allocation_strategy]).to eq(:capacity_optimized)
      expect(out[:instance_types]).to eq(%w[p4d.24xlarge p4de.24xlarge])
    end

    it 'beefy_spot_amd64 is the native x86 nix_builder mirror (100% spot)' do
      out = described_class.resolve({ 'instance_type_profile' => 'beefy_spot_amd64' })
      expect(out[:category]).to eq(:nix_builder)
      expect(out[:allocation_strategy]).to eq(:capacity_optimized)
      expect(out[:on_demand_base_capacity]).to eq(0)
      expect(out[:on_demand_percentage_above_base]).to eq(0)
      expect(out[:instance_types]).to include('c7i.16xlarge', 'c7a.16xlarge', 'm7i.16xlarge')
      # x86 only — never a Graviton (arm64) family in the amd64 lane
      expect(out[:instance_types].none? { |t| t.match?(/\d+gd?\./) }).to eq(true)
    end

    it 'memory_heavy_amd64 targets amd64 r-family for big Go/FIPS closures' do
      out = described_class.resolve({ 'instance_type_profile' => 'memory_heavy_amd64' })
      expect(out[:category]).to eq(:nix_builder)
      expect(out[:allocation_strategy]).to eq(:capacity_optimized)
      expect(out[:instance_types]).to include('r7i.16xlarge', 'r7a.16xlarge', 'r6i.16xlarge')
      expect(out[:instance_types].none? { |t| t.match?(/\d+gd?\./) }).to eq(true)
    end
  end
end

RSpec.describe Pangea::Spot::Allocation do
  it 'defines 5 AWS strategies' do
    expect(described_class::STRATEGIES.size).to eq(5)
  end

  it 'maps snake_case → hyphen AWS form' do
    expect(described_class.to_aws(:capacity_optimized)).to eq('capacity-optimized')
    expect(described_class.to_aws(:price_capacity_optimized)).to eq('price-capacity-optimized')
  end

  it 'raises on unknown strategy' do
    expect { described_class.to_aws(:paranoid) }.to raise_error(ArgumentError, /unknown strategy/)
  end

  it 'default_for returns the category default' do
    expect(described_class.default_for(:k8s_workers)).to eq(:price_capacity_optimized)
    expect(described_class.default_for(:nix_builder)).to eq(:capacity_optimized)
  end
end
