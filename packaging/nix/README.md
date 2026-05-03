# BearBrowser Nix Packaging

BearBrowser exposes root-level Nix outputs for SourceOS packaging.

## Commands

Show outputs:

```bash
nix flake show
```

Build human secure profile package:

```bash
nix build .#bearbrowser-human-secure
```

Build agent runtime profile package:

```bash
nix build .#bearbrowser-agent-runtime
```

Enter development shell:

```bash
nix develop
```

Verify structural packaging inputs:

```bash
bash scripts/verify-nix-packaging.sh
```

## Outputs

- `packages.${system}.bearbrowser-human-secure`
- `packages.${system}.bearbrowser-agent-runtime`
- `packages.${system}.default`
- `devShells.${system}.default`

## Inputs

- Clean mirror: `SourceOS-Linux/librewolf-source-mirror`
- Overlay script: `scripts/apply-sourceos-overlays.sh`
- Human profile: `settings/profiles/human-secure`
- Agent profile: `settings/profiles/agent-runtime`
- Policy contract: `policy/bearbrowser-contract.yaml`
- Mount plan: `mounts/agent-browser-mounts.yaml`
- Upstream manifest: `manifests/upstream.json`

## Current build flow

The current Nix outputs package the BearBrowser profile, policy, mount, and upstream metadata surfaces. They are intentionally metadata/profile packages, not full LibreWolf binary builds yet.

## Full browser build flow target

1. Resolve pinned LibreWolf ref from `manifests/upstream.json` or explicit build input.
2. Run the overlay pipeline for the selected profile.
3. Build the resulting LibreWolf-derived source workspace.
4. Inject profile-specific settings and policies.
5. Emit package metadata and provenance manifest.
6. Promote artifacts through Nix, Homebrew, OCI, and SourceOS release channels.

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
