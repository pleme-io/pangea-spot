# pangea-spot (stub)

Placeholder gem for the extraction of spot architectures out of
`pangea-architectures`. Currently empty — real `Pangea::Spot::Catalog` +
`Pangea::Architectures::Spot::*` classes land in a follow-up commit.

## Why this exists

`pangea-architectures/lib/pangea/architectures.rb` eagerly loads
`require 'pangea-spot'`. Without this stub, no workspace under
`pangea-architectures` can deploy — even workspaces that don't use spot
at all. The stub unblocks those while the extraction proceeds.

## What's safe today

- `require 'pangea-spot'` — succeeds.
- Any workspace that doesn't reference `Pangea::Spot::*` — deploys cleanly.

## What's not safe until extraction lands

- `Pangea::Spot::Catalog.resolve(...)` — NameError.
- `Pangea::Spot::Catalog::NIX_BUILDER` — NameError.
- Code in `lib/pangea/helpers/builder_fleet_profiles.rb` that delegates to
  `Pangea::Spot::Catalog`.

Workspaces affected: `nix-builders`, `platform-builder-fleet`, and
anything using `NixBuilderFleet`. These stay on the legacy path until the
real extraction lands.
