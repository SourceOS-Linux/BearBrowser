# BearBrowser Nix Packaging

This lane packages BearBrowser as LibreWolf-derived outputs with SourceOS overlays.

## Outputs

- `bearbrowser-human-secure`
- `bearbrowser-agent-runtime`
- `bearbrowser-devshell`

## Inputs

- Clean mirror: `SourceOS-Linux/librewolf-source-mirror`
- Overlay script: `scripts/apply-sourceos-overlays.sh`
- Human profile: `settings/profiles/human-secure`
- Agent profile: `settings/profiles/agent-runtime`
- Policy contract: `policy/bearbrowser-contract.yaml`
- Mount plan: `mounts/agent-browser-mounts.yaml`

## Build flow

1. Resolve pinned LibreWolf ref from `manifests/upstream.json` or explicit build input.
2. Run the overlay pipeline for the selected profile.
3. Build the resulting LibreWolf-derived source workspace.
4. Inject profile-specific settings and policies.
5. Emit package metadata and provenance manifest.

## Reproducibility expectations

- The upstream ref must be explicit in release builds.
- Generated workspace paths must not affect package output identity.
- Release artifacts must include the BearBrowser profile, upstream ref, SourceOS revision, and target system.
- Patch application must fail closed.

## Release artifact naming

```text
BearBrowser-human-secure-${upstreamRef}-${sourceosRevision}-${system}
BearBrowser-agent-runtime-${upstreamRef}-${sourceosRevision}-${system}
```

## Build cache strategy

Use the upstream ref and patch-stack hash as the primary cache key. Human and agent profiles should share upstream build cache where possible, but profile-specific settings and packaging metadata must remain separate.
