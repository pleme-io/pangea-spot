# pangea-spot

> **★★★ CSE / Knowable Construction.** This repo operates under **Constructive Substrate Engineering** — canonical specification at [`pleme-io/theory/CONSTRUCTIVE-SUBSTRATE-ENGINEERING.md`](https://github.com/pleme-io/theory/blob/main/CONSTRUCTIVE-SUBSTRATE-ENGINEERING.md). The Compounding Directive (operational rules: solve once, load-bearing fixes only, idiom-first, models stay current, direction beats velocity) is in the org-level pleme-io/CLAUDE.md ★★★ section. Read both before non-trivial changes.


Spot-instance architecture pack for Pangea. Treats "auctioned compute with
interruption risk" as a first-class typed primitive across every workload
shape.

## Why this gem

The 4 orthogonal spot concerns — auction mechanism, instance-type
catalog, interruption policy, workload topology — are fused in naive
implementations. This gem separates them so any workload can compose its
own fleet from known-good parts.

## Layout

```
lib/
  pangea-spot.rb                         # entry point
  pangea-spot/version.rb
  pangea/
    spot/
      catalog.rb                         # 22 profiles × 9 categories
      allocation.rb                      # 5 AWS strategies + defaults + to_aws/to_spot_fleet
    architectures/
      spot/
        types.rb                         # Dry::Struct configs + policy/strategy/fleet-type enums
        topology_helpers.rb              # shared profile + allocation + LT resolution
        interruption_handler.rb          # 4 policies (graceful, drain_k8s, checkpoint, naive)
        mixed_instances_asg.rb           # ASG w/ mixed-instances-policy (continuous capacity)
        ec2_fleet.rb                     # aws_ec2_fleet (maintain/request/instant)
        spot_fleet.rb                    # aws_spot_fleet_request (legacy, migration parity)
```

## Phased rollout

- **Phase 1 ✓** — catalog + allocation + InterruptionHandler
- **Phase 2 ✓** — extracted from pangea-architectures into this gem
- **Phase 3 ✓** — topology architectures (MixedInstancesAsg + Ec2Fleet + SpotFleet)
- **Phase 4 ✓ (8/8)** — JIT workload architectures:
  - ✓ K8sJitNodePool (MixedInstancesAsg + interruption_policy override)
  - ✓ CiJitFleet (Ec2Fleet + :naive_terminate)
  - ✓ PackerJitBake (SSM-published spot knobs)
  - ✓ AtticJitService (breathable Nix cache — NLB + S3 state)
  - ✓ ZotJitService (breathable OCI registry — NLB+TLS + S3 state)
  - ✓ FluxJitController (Git-backed controller pool, min=1)
  - ✓ MlJitTraining (:checkpoint_job + S3 checkpoint bucket + CheckpointPolicy tags)
  - ✓ BatchJitCompute (native aws_batch_compute_environment SPOT+EC2 modes)
- **AlertLayer (Phase 5b Track A) ✓** — mandatory interruption telegraph
  wired into every architecture. `AlertLayer.build(synth, cfg, asg_name:)`
  emits SQS + EB rule + IAM policy for `:nth_queue`, none for `:nth_imds`,
  ASG tags for `:spot_io_ocean` / `:cast_ai`. Defaults per workload class
  (K8s: :nth_imds, CI/ML: :nth_queue, Batch: opt-out per native re-queue).
- Phase 5 — cross-provider (GCP Spot VMs, Azure Spot VMs) as new
  substrate providers under the same JIT typescape
- Phase 6 — intelligence (PriceSnapshot, PlacementScore, SavingsReport,
  cost-per-wake, interruption-vs-wake tradeoff)

See `theory_jit_infrastructure.md` in user auto-memory for the
foundational framing — every compute unit is a typed composition of
auction substrate + breathability + state externalization + interruption
policy + substrate provider. pangea-spot is the auction-substrate layer;
pangea-jit (future companion gem) will compose it into workload-level
JIT architectures.

## Testing

```sh
bundle exec rspec
nix run .#test
```

## Consumers

pangea-architectures requires this gem to power
`Pangea::Helpers::BuilderFleetProfiles.resolve` (the legacy entry point
kept as a backward-compat shim) and the builder-fleet template emission.

## License

Apache-2.0
