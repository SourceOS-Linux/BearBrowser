# Upstream Parity Model

Canonical upstream:

- `https://codeberg.org/librewolf/source.git`

SourceOS clean mirror:

- `SourceOS-Linux/librewolf-source-mirror`

SourceOS product overlay:

- `SourceOS-Linux/sourceos-browser`

## Operating model

1. Sync Codeberg LibreWolf branches and tags into the clean mirror.
2. Exclude noncanonical refs such as merge-request refs, pipeline refs, pull refs, and notes.
3. Pin the SourceOS product repo to a known upstream tag or commit.
4. Apply SourceOS overlays as explicit patches, settings, policy, and packaging.
5. Fail parity checks when the mirror has hidden refs, patches stop applying, or the product pin is stale.
