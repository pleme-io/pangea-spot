# frozen_string_literal: true
#
# Pangea::Spot::Catalog — typed spot-instance profile library.
#
# Each profile is a named {instance_types, recommended_allocation,
# on_demand_base, on_demand_pct, spot_max_price, notes} bundle
# curated for a specific workload shape. Pick by name in platform YAML:
#
#   builder_fleet:
#     instance_type_profile: beefy_spot      # from nix_builder category
#   worker_pool:
#     instance_type_profile: karpenter_general
#   ci_fleet:
#     instance_type_profile: gh_actions_large
#
# Categories:
#   nix_builder      — arm64 compute-bound Nix remote builds
#   k8s_workers      — Karpenter/managed-node-group workloads
#   ci_runner        — ephemeral self-hosted CI runners
#   ml_training      — GPU + custom-silicon spot training
#   batch_compute    — HPC, scientific, MapReduce
#   ephemeral_runner — one-shot spot-backed jobs
#   memory_heavy     — r-family, 4GB/vCPU workloads
#   storage_heavy    — local NVMe (i-family, *d suffix)
#   network_heavy    — 100-Gbps capable (*n suffix)
#
# Every profile documents the cost model + interruption expectation
# per AWS Spot Market insights (as of 2026-04). Refresh periodically.

module Pangea
  module Spot
    module Catalog
      # Typed allocation strategies (AWS spot). Each maps to the
      # SpotAllocationStrategy field on the mixed-instances policy.
      ALLOCATION_STRATEGIES = %i[
        capacity_optimized
        capacity_optimized_prioritized
        diversified
        lowest_price
        price_capacity_optimized
      ].freeze

      # ─── NIX BUILDER ───────────────────────────────────────────────

      NIX_BUILDER = {
        # Maximum spot availability — 18 pools across c7g/c7gd/c8g/m7g/
        # m7gd/m8g/r7g/c6g/m6g × 8xl/16xl. 100% spot, no on-demand floor.
        # Cost: c7g.16xl spot ≈ $0.70/hr; a 30-min build cycle ≈ $0.35.
        # Interruption rate: <5% for c7g/m7g.8xl in us-east-1 (2026-04).
        beefy_spot: {
          category: :nix_builder,
          instance_types: %w[
            c7g.16xlarge  c7g.8xlarge
            c7gd.16xlarge c7gd.8xlarge
            c8g.16xlarge  c8g.8xlarge
            m7g.16xlarge  m7g.8xlarge
            m7gd.16xlarge m7gd.8xlarge
            m8g.16xlarge  m8g.8xlarge
            r7g.16xlarge  r7g.8xlarge
            c6g.16xlarge  c6g.8xlarge
            m6g.16xlarge  m6g.8xlarge
          ].freeze,
          recommended_allocation: :capacity_optimized,
          on_demand_base_capacity: 0,
          on_demand_percentage_above_base: 0,
          spot_max_price: '2.50',
          notes: 'Maximum capacity spread. 100% spot. Ephemeral wake-build-sleep cycles.',
        }.freeze,

        # The amd64 (x86_64-linux) mirror of :beefy_spot — 12 pools across
        # c7i/c7a/m7i/m7a/c6i/m6i × 8xl/16xl. Intel (i) + AMD (a) diversified
        # so the native x86 build lane never starves. 100% spot, no OD floor.
        # Cost: c7i.16xl spot ≈ $1.20/hr; a 30-min build cycle ≈ $0.60.
        # Interruption rate: <5% for c7i/m7i.8xl in us-east-1 (2026-04).
        beefy_spot_amd64: {
          category: :nix_builder,
          instance_types: %w[
            c7i.16xlarge c7i.8xlarge
            c7a.16xlarge c7a.8xlarge
            m7i.16xlarge m7i.8xlarge
            m7a.16xlarge m7a.8xlarge
            c6i.16xlarge c6i.8xlarge
            m6i.16xlarge m6i.8xlarge
          ].freeze,
          recommended_allocation: :capacity_optimized,
          on_demand_base_capacity: 0,
          on_demand_percentage_above_base: 0,
          spot_max_price: '2.50',
          notes: 'Native x86_64-linux lane. 12 Intel+AMD pools. 100% spot.',
        }.freeze,

        # ── TIME-FLOOR builder pools (objective: MINIMUM build time) ──────
        # Distinct from :beefy_spot* (which floor on COST — the cheapest small
        # deep pool). A build pool's bottleneck is parallel-compile width +
        # RAM for a never-touch-disk RAMDISK, so the time-floor pools reach for
        # the BIGGEST latest-gen instances (24xl/48xl = 96–192 vCPU, 192–384 GB
        # RAM) — spot-diversified across ~10 families for capacity depth so the
        # monster still lands fast + rarely reclaims. Scale-to-zero keeps it
        # cost-controlled: you rent the monster only for the build minutes.
        # 100% spot on every rung — no on-demand floor, ever.
        #
        # amd64 (x86_64-linux) — the native ARC-runner / sui build target.
        #   compute (c7i/c7a) up to 48xl = 192 vCPU for parallel derivations +
        #   Go package compile; memory (m7i/m7a) 24xl/48xl for a big RAMDISK;
        #   local-NVMe (c6id/m6id) 24xl for store/scratch overflow. Intel+AMD
        #   diversified so a native x86 monster never starves.
        # Cost: c7i.48xl spot ≈ $3.60/hr; a 15-min build ≈ $0.90 (idle: $0).
        nix_builder_timefloor_amd64: {
          category: :nix_builder,
          instance_types: %w[
            c7i.48xlarge c7i.24xlarge
            c7a.48xlarge c7a.24xlarge
            m7i.48xlarge m7i.24xlarge
            m7a.48xlarge m7a.24xlarge
            c6id.32xlarge c6id.24xlarge
            m6id.32xlarge m6id.24xlarge
          ].freeze,
          recommended_allocation: :capacity_optimized,
          on_demand_base_capacity: 0,
          on_demand_percentage_above_base: 0,
          spot_max_price: '8.00',
          notes: 'TIME-FLOOR: biggest latest-gen x86 (96–192 vCPU, 192–384 GB). ' \
                 'Rent-the-monster-for-the-build-minute; scale-to-zero at idle. 100% spot.',
        }.freeze,

        # arm64 (aarch64-linux) mirror — Graviton c8g/m8g 48xl + c7gd/m7gd
        # local-NVMe 16xl (Graviton tops out at 48xl on c8g/m8g / 16xl on the
        # d-suffix; still 96–192 vCPU on the 48xl). 100% spot.
        nix_builder_timefloor_arm64: {
          category: :nix_builder,
          instance_types: %w[
            c8g.48xlarge c8g.24xlarge
            m8g.48xlarge m8g.24xlarge
            c7g.16xlarge c7g.8xlarge
            m7g.16xlarge m7g.8xlarge
            c7gd.16xlarge c7gd.8xlarge
            m7gd.16xlarge m7gd.8xlarge
          ].freeze,
          recommended_allocation: :capacity_optimized,
          on_demand_base_capacity: 0,
          on_demand_percentage_above_base: 0,
          spot_max_price: '8.00',
          notes: 'TIME-FLOOR arm64: biggest Graviton (up to 192 vCPU on c8g/m8g.48xl). 100% spot.',
        }.freeze,

        # Conservative — 6 pools + 1 on-demand base + 20% OD above.
        # Guaranteed wake even if all spot pools dry.
        balanced: {
          category: :nix_builder,
          instance_types: %w[
            c7g.16xlarge c7g.8xlarge
            m7g.16xlarge m7g.8xlarge
            c8g.16xlarge c8g.8xlarge
          ].freeze,
          recommended_allocation: :capacity_optimized,
          on_demand_base_capacity: 1,
          on_demand_percentage_above_base: 20,
          spot_max_price: '2.50',
          notes: 'Guaranteed wake. Modest spot savings.',
        }.freeze,

        memory_heavy: {
          category: :nix_builder,
          instance_types: %w[
            r7g.16xlarge  r7g.8xlarge
            r8g.16xlarge  r8g.8xlarge
            r7gd.16xlarge r7gd.8xlarge
            r6g.16xlarge  r6g.8xlarge
          ].freeze,
          recommended_allocation: :capacity_optimized,
          on_demand_base_capacity: 0,
          on_demand_percentage_above_base: 0,
          spot_max_price: '3.00',
          notes: 'Large Nix closures, heavy linkers. 256GB+ RAM on 16xl.',
        }.freeze,

        # The amd64 mirror of :memory_heavy — r7i/r7a/r6i × 8xl/16xl. Big
        # Go monorepo + FIPS-OpenSSL closures on 512GB+ RAM (r*.16xl). Intel
        # (i) + AMD (a) diversified. 100% spot, no OD floor.
        memory_heavy_amd64: {
          category: :nix_builder,
          instance_types: %w[
            r7i.16xlarge r7i.8xlarge
            r7a.16xlarge r7a.8xlarge
            r6i.16xlarge r6i.8xlarge
          ].freeze,
          recommended_allocation: :capacity_optimized,
          on_demand_base_capacity: 0,
          on_demand_percentage_above_base: 0,
          spot_max_price: '3.00',
          notes: 'Native x86_64-linux memory lane. Big Go/FIPS closures. 100% spot.',
        }.freeze,

        legacy: {
          category: :nix_builder,
          instance_types: %w[
            c6g.16xlarge c6g.8xlarge
            m6g.16xlarge m6g.8xlarge
            r6g.16xlarge r6g.8xlarge
          ].freeze,
          recommended_allocation: :capacity_optimized,
          on_demand_base_capacity: 1,
          on_demand_percentage_above_base: 20,
          spot_max_price: '2.00',
          notes: 'Graviton 2 fallback when G3/G4 capacity is tight.',
        }.freeze,
      }.freeze

      # ─── K8S WORKERS ──────────────────────────────────────────────

      K8S_WORKERS = {
        # Karpenter-friendly: broad generation spread; arm64 + x86_64.
        # Consume as a node-pool instance filter.
        karpenter_general: {
          category: :k8s_workers,
          instance_types: %w[
            c7g.4xlarge  c7g.8xlarge  c7g.12xlarge c7g.16xlarge
            c7i.4xlarge  c7i.8xlarge  c7i.12xlarge c7i.16xlarge
            c7a.4xlarge  c7a.8xlarge  c7a.12xlarge c7a.16xlarge
            m7g.4xlarge  m7g.8xlarge  m7g.12xlarge m7g.16xlarge
            m7i.4xlarge  m7i.8xlarge  m7i.12xlarge m7i.16xlarge
            m7a.4xlarge  m7a.8xlarge  m7a.12xlarge m7a.16xlarge
          ].freeze,
          recommended_allocation: :price_capacity_optimized,
          on_demand_base_capacity: 0,
          on_demand_percentage_above_base: 10,
          spot_max_price: '3.00',
          notes: 'Mixed arm/x86, Intel+AMD, multiple sizes. Karpenter picks per pod spec.',
        }.freeze,

        karpenter_memory: {
          category: :k8s_workers,
          instance_types: %w[
            r7g.4xlarge  r7g.8xlarge  r7g.16xlarge
            r7i.4xlarge  r7i.8xlarge  r7i.16xlarge
            r7a.4xlarge  r7a.8xlarge  r7a.16xlarge
            x2gd.2xlarge x2gd.4xlarge x2gd.8xlarge x2gd.16xlarge
          ].freeze,
          recommended_allocation: :price_capacity_optimized,
          on_demand_base_capacity: 0,
          on_demand_percentage_above_base: 10,
          spot_max_price: '4.00',
          notes: 'DB caches, JVM heavy, big ML inference. 4–32 GB/vCPU.',
        }.freeze,

        karpenter_gpu: {
          category: :k8s_workers,
          instance_types: %w[
            g5.xlarge g5.2xlarge g5.4xlarge g5.8xlarge g5.12xlarge
            g6.xlarge g6.2xlarge g6.4xlarge g6.8xlarge g6.12xlarge
          ].freeze,
          recommended_allocation: :capacity_optimized,
          on_demand_base_capacity: 0,
          on_demand_percentage_above_base: 0,
          spot_max_price: '5.00',
          notes: 'Inference + small training. A10/L4 GPUs. Higher interruption rate.',
        }.freeze,

        karpenter_batch: {
          category: :k8s_workers,
          instance_types: %w[
            c7i.24xlarge c7i.48xlarge
            c7a.24xlarge c7a.48xlarge
            m7i.24xlarge m7i.48xlarge
          ].freeze,
          recommended_allocation: :diversified,
          on_demand_base_capacity: 0,
          on_demand_percentage_above_base: 0,
          spot_max_price: '6.00',
          notes: 'Parallel jobs on enormous instances. Diversified to spread risk.',
        }.freeze,

        eks_managed_small: {
          category: :k8s_workers,
          instance_types: %w[
            t3.medium  t3.large   t3.xlarge   t3.2xlarge
            t4g.medium t4g.large  t4g.xlarge  t4g.2xlarge
          ].freeze,
          recommended_allocation: :lowest_price,
          on_demand_base_capacity: 1,
          on_demand_percentage_above_base: 50,
          spot_max_price: '0.50',
          notes: 'Ingress, controllers, sidecars. Mixed OD/spot for stability.',
        }.freeze,
      }.freeze

      # ─── CI RUNNERS ───────────────────────────────────────────────

      CI_RUNNER = {
        gh_actions_small: {
          category: :ci_runner,
          instance_types: %w[
            c7g.2xlarge c7g.4xlarge c7g.8xlarge
            c7i.2xlarge c7i.4xlarge c7i.8xlarge
            c6g.2xlarge c6g.4xlarge c6g.8xlarge
          ].freeze,
          recommended_allocation: :price_capacity_optimized,
          on_demand_base_capacity: 0,
          on_demand_percentage_above_base: 0,
          spot_max_price: '1.00',
          notes: 'Short-lived CI jobs (≤15min). Cost-optimized.',
        }.freeze,

        gh_actions_large: {
          category: :ci_runner,
          instance_types: %w[
            c7g.16xlarge  c7i.16xlarge
            c7gd.16xlarge c7id.16xlarge
            m7g.16xlarge  m7i.16xlarge
          ].freeze,
          recommended_allocation: :capacity_optimized,
          on_demand_base_capacity: 0,
          on_demand_percentage_above_base: 0,
          spot_max_price: '3.00',
          notes: 'Heavy builds (Rust/C++ compile matrices). 64 vCPU.',
        }.freeze,

        buildkite_agent: {
          category: :ci_runner,
          instance_types: %w[
            m7g.4xlarge  m7g.8xlarge  m7g.16xlarge
            m7i.4xlarge  m7i.8xlarge  m7i.16xlarge
            m6g.4xlarge  m6g.8xlarge  m6g.16xlarge
          ].freeze,
          recommended_allocation: :price_capacity_optimized,
          on_demand_base_capacity: 0,
          on_demand_percentage_above_base: 10,
          spot_max_price: '2.00',
          notes: 'Long-lived agent (≥30min). 10% OD for queue continuity.',
        }.freeze,

        gitlab_runner: {
          category: :ci_runner,
          instance_types: %w[
            c6i.4xlarge c6i.8xlarge c6i.16xlarge
            c7i.4xlarge c7i.8xlarge c7i.16xlarge
          ].freeze,
          recommended_allocation: :price_capacity_optimized,
          on_demand_base_capacity: 0,
          on_demand_percentage_above_base: 0,
          spot_max_price: '2.00',
          notes: 'x86-only (GitLab runner Docker images). Cost-optimized.',
        }.freeze,
      }.freeze

      # ─── ML TRAINING ──────────────────────────────────────────────

      ML_TRAINING = {
        g5_spot: {
          category: :ml_training,
          instance_types: %w[
            g5.xlarge  g5.2xlarge  g5.4xlarge
            g5.8xlarge g5.12xlarge g5.24xlarge g5.48xlarge
          ].freeze,
          recommended_allocation: :capacity_optimized,
          on_demand_base_capacity: 0,
          on_demand_percentage_above_base: 0,
          spot_max_price: '10.00',
          notes: 'A10 GPU. Small-to-medium training + inference. 70%+ savings vs OD.',
        }.freeze,

        p4d_spot: {
          category: :ml_training,
          instance_types: %w[p4d.24xlarge p4de.24xlarge].freeze,
          recommended_allocation: :capacity_optimized,
          on_demand_base_capacity: 0,
          on_demand_percentage_above_base: 0,
          spot_max_price: '25.00',
          notes: '8× A100 GPU. Top-tier spot — interruption rate 5-15%. Checkpoint liberally.',
        }.freeze,

        trainium_spot: {
          category: :ml_training,
          instance_types: %w[
            trn1.2xlarge trn1.32xlarge trn1n.32xlarge
          ].freeze,
          recommended_allocation: :capacity_optimized,
          on_demand_base_capacity: 0,
          on_demand_percentage_above_base: 0,
          spot_max_price: '20.00',
          notes: 'AWS custom silicon. Excellent $/training-step for transformer workloads.',
        }.freeze,

        inferentia_spot: {
          category: :ml_training,
          instance_types: %w[
            inf2.xlarge  inf2.8xlarge
            inf2.24xlarge inf2.48xlarge
          ].freeze,
          recommended_allocation: :capacity_optimized,
          on_demand_base_capacity: 0,
          on_demand_percentage_above_base: 10,
          spot_max_price: '12.00',
          notes: 'Inference-optimized. 10% OD for latency-SLO workloads.',
        }.freeze,
      }.freeze

      # ─── BATCH COMPUTE ────────────────────────────────────────────

      BATCH_COMPUTE = {
        genomics_spot: {
          category: :batch_compute,
          instance_types: %w[
            hpc6a.48xlarge hpc7a.96xlarge
            r7i.24xlarge   r7i.48xlarge
            r7a.24xlarge   r7a.48xlarge
          ].freeze,
          recommended_allocation: :capacity_optimized,
          on_demand_base_capacity: 0,
          on_demand_percentage_above_base: 0,
          spot_max_price: '8.00',
          notes: 'Large-memory sequencing pipelines. HPC-tuned CPUs + r-family fallback.',
        }.freeze,

        mapreduce_spot: {
          category: :batch_compute,
          instance_types: %w[
            r7i.12xlarge r7i.24xlarge r7i.48xlarge
            m7i.12xlarge m7i.24xlarge m7i.48xlarge
          ].freeze,
          recommended_allocation: :price_capacity_optimized,
          on_demand_base_capacity: 0,
          on_demand_percentage_above_base: 0,
          spot_max_price: '6.00',
          notes: 'EMR/Spark jobs. Checkpoint to S3 every N stages.',
        }.freeze,

        scientific_hpc: {
          category: :batch_compute,
          instance_types: %w[
            hpc7a.96xlarge hpc7g.16xlarge hpc7g.32xlarge
            c7i.24xlarge   c7i.48xlarge
          ].freeze,
          recommended_allocation: :diversified,
          on_demand_base_capacity: 0,
          on_demand_percentage_above_base: 0,
          spot_max_price: '10.00',
          notes: 'MPI + EFA. Diversified because hpc-family spot pools are shallow.',
        }.freeze,
      }.freeze

      # ─── EPHEMERAL RUNNER ─────────────────────────────────────────

      EPHEMERAL_RUNNER = {
        tiny_burst: {
          category: :ephemeral_runner,
          instance_types: %w[
            t3.medium t3.large t3.xlarge
            t4g.medium t4g.large t4g.xlarge
          ].freeze,
          recommended_allocation: :lowest_price,
          on_demand_base_capacity: 0,
          on_demand_percentage_above_base: 0,
          spot_max_price: '0.25',
          notes: 'One-off scripts, cron jobs, cheap CI sanity checks.',
        }.freeze,

        medium_burst: {
          category: :ephemeral_runner,
          instance_types: %w[
            c7g.2xlarge c7g.4xlarge c7g.8xlarge
            c7i.2xlarge c7i.4xlarge c7i.8xlarge
          ].freeze,
          recommended_allocation: :price_capacity_optimized,
          on_demand_base_capacity: 0,
          on_demand_percentage_above_base: 0,
          spot_max_price: '1.50',
          notes: 'Medium-duration jobs (5min–1hr). Compile, parse, ETL.',
        }.freeze,

        beefy_burst: {
          category: :ephemeral_runner,
          instance_types: %w[
            c7g.16xlarge c7i.16xlarge
            m7g.16xlarge m7i.16xlarge
          ].freeze,
          recommended_allocation: :capacity_optimized,
          on_demand_base_capacity: 0,
          on_demand_percentage_above_base: 0,
          spot_max_price: '3.00',
          notes: 'Heavy one-off jobs. 64 vCPU × 2–4 hrs, $1.50–3 total.',
        }.freeze,
      }.freeze

      # ─── SPECIAL-PURPOSE ──────────────────────────────────────────

      MEMORY_HEAVY = {
        r7_family_spot: {
          category: :memory_heavy,
          instance_types: %w[
            r7g.4xlarge  r7g.8xlarge  r7g.16xlarge
            r7i.4xlarge  r7i.8xlarge  r7i.16xlarge
            r7a.4xlarge  r7a.8xlarge  r7a.16xlarge
          ].freeze,
          recommended_allocation: :price_capacity_optimized,
          on_demand_base_capacity: 0,
          on_demand_percentage_above_base: 0,
          spot_max_price: '4.00',
          notes: '4 GB/vCPU. DB caches, JVM heaps, search indexes.',
        }.freeze,

        x2gd_terabyte: {
          category: :memory_heavy,
          instance_types: %w[
            x2gd.8xlarge x2gd.12xlarge x2gd.16xlarge x2gd.metal
          ].freeze,
          recommended_allocation: :capacity_optimized,
          on_demand_base_capacity: 0,
          on_demand_percentage_above_base: 0,
          spot_max_price: '10.00',
          notes: 'Up to 1TB RAM. Redis/Memcache/SAP HANA spot. Rare capacity.',
        }.freeze,
      }.freeze

      STORAGE_HEAVY = {
        i4i_nvme: {
          category: :storage_heavy,
          instance_types: %w[
            i4i.4xlarge i4i.8xlarge i4i.16xlarge i4i.32xlarge
          ].freeze,
          recommended_allocation: :price_capacity_optimized,
          on_demand_base_capacity: 0,
          on_demand_percentage_above_base: 0,
          spot_max_price: '5.00',
          notes: '30+ TB NVMe. ClickHouse, Cassandra, Elasticsearch spot.',
        }.freeze,

        i4g_nvme_graviton: {
          category: :storage_heavy,
          instance_types: %w[
            i4g.4xlarge i4g.8xlarge i4g.16xlarge
          ].freeze,
          recommended_allocation: :price_capacity_optimized,
          on_demand_base_capacity: 0,
          on_demand_percentage_above_base: 0,
          spot_max_price: '4.00',
          notes: 'arm64 + NVMe. Cheaper than i4i for Graviton-compatible apps.',
        }.freeze,
      }.freeze

      NETWORK_HEAVY = {
        c7gn_100gbps: {
          category: :network_heavy,
          instance_types: %w[
            c7gn.4xlarge c7gn.8xlarge c7gn.16xlarge
          ].freeze,
          recommended_allocation: :capacity_optimized,
          on_demand_base_capacity: 0,
          on_demand_percentage_above_base: 0,
          spot_max_price: '3.00',
          notes: '200 Gbps networking. Video processing, realtime analytics.',
        }.freeze,

        c7in_intel_400gbps: {
          category: :network_heavy,
          instance_types: %w[
            c7in.12xlarge c7in.24xlarge c7in.48xlarge
          ].freeze,
          recommended_allocation: :capacity_optimized,
          on_demand_base_capacity: 0,
          on_demand_percentage_above_base: 0,
          spot_max_price: '6.00',
          notes: 'Up to 400 Gbps. Distributed-systems research, SDN.',
        }.freeze,
      }.freeze

      # ─── MASTER REGISTRY ──────────────────────────────────────────

      ALL_PROFILES = {}.merge(
        NIX_BUILDER, K8S_WORKERS, CI_RUNNER, ML_TRAINING,
        BATCH_COMPUTE, EPHEMERAL_RUNNER, MEMORY_HEAVY, STORAGE_HEAVY,
        NETWORK_HEAVY,
      ).freeze

      # Public API ────────────────────────────────────────────────────

      # Look up a profile by symbol name. Raises if unknown.
      def self.fetch(name)
        profile = ALL_PROFILES[name.to_sym]
        return profile if profile

        available = ALL_PROFILES.keys.sort.join(', ')
        raise ArgumentError,
              "unknown Spot profile: #{name.inspect}. Available: #{available}"
      end

      # All profiles in a category.
      def self.in_category(category)
        ALL_PROFILES.select { |_, p| p[:category] == category.to_sym }
      end

      # Full registry (frozen). Keys are symbols.
      def self.all
        ALL_PROFILES
      end

      # Resolve a YAML fleet config → concrete knobs. Per-field overrides
      # in YAML win over the profile's preset.
      def self.resolve(fleet_cfg, default: :balanced)
        profile_key = (fleet_cfg['instance_type_profile'] || default).to_sym
        profile = fetch(profile_key)

        {
          instance_types: fleet_cfg.fetch('instance_types', profile[:instance_types]),
          on_demand_base_capacity:
            fleet_cfg.fetch('on_demand_base_capacity', profile[:on_demand_base_capacity]),
          on_demand_percentage_above_base:
            fleet_cfg.fetch('on_demand_percentage_above_base',
                            profile[:on_demand_percentage_above_base]),
          spot_max_price:
            fleet_cfg.fetch('spot_max_price', profile[:spot_max_price]),
          allocation_strategy:
            fleet_cfg.fetch('allocation_strategy',
                            profile[:recommended_allocation]).to_sym,
          profile: profile_key,
          category: profile[:category],
        }
      end
    end
  end
end
