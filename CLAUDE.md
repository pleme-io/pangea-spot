# pangea-spot

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
      allocation.rb                      # 5 AWS strategies + defaults
    architectures/
      spot/
        interruption_handler.rb          # 4 policies (graceful, drain_k8s, checkpoint, naive)
```

## Phased rollout

- **Phase 1 ✓** — catalog + allocation + InterruptionHandler
- **Phase 2 ✓** — extracted from pangea-architectures into this gem
- Phase 3 — topology architectures (MixedInstancesAsg, Ec2Fleet, SpotFleet)
- Phase 4 — workload architectures (K8sSpotWorkers, CiSpotFleet,
  MlTrainingCluster, BatchComputeEnv, EphemeralRunner)
- Phase 5 — cross-provider (GCP Spot VMs, Azure Spot VMs)
- Phase 6 — intelligence (PriceSnapshot, PlacementScore, SavingsReport)

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
