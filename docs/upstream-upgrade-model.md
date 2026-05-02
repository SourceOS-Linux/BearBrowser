# BearBrowser Upstream Upgrade Model

BearBrowser must remain an overlay product, not a long-lived source fork branch.

## Canonical flow

```text
Codeberg LibreWolf source
  -> SourceOS-Linux/librewolf-source-mirror
  -> BearBrowser overlay pipeline
  -> human-secure / agent-runtime build workspaces
```

## Rules

- Do not rebase BearBrowser itself onto LibreWolf source.
- Do not commit generated LibreWolf source workspaces into BearBrowser.
- Do not add SourceOS/BearBrowser commits to the clean mirror.
- Keep LibreWolf parity in `SourceOS-Linux/librewolf-source-mirror`.
- Keep BearBrowser deltas as settings, policy, mounts, packaging, integration contracts, and explicit patches.
- Treat `patches/*.patch` as the only normal place for browser-source modifications.

## Upgrade procedure

1. Sync `SourceOS-Linux/librewolf-source-mirror` from Codeberg.
2. Verify mirror parity.
3. Select the next LibreWolf tag or commit.
4. Run BearBrowser overlay dry runs for both profiles.
5. Run full overlay application for `human-secure` and `agent-runtime`.
6. If patches fail, update the patch stack in BearBrowser.
7. Update `manifests/upstream.json` with the promoted pin.
8. Merge the upgrade through a BearBrowser PR.

## Rebase policy

Do not run this in BearBrowser:

```bash
git rebase upstream/main
```

Rebase is only appropriate inside disposable generated workspaces or temporary patch-preparation branches. BearBrowser `main` should remain a product overlay repository.

## Safety property

This model keeps upstream churn isolated. LibreWolf source changes are absorbed by replaying BearBrowser overlays against a new upstream ref. If an upstream change breaks a BearBrowser patch, CI fails at the patch application step instead of creating a broad source-tree merge conflict.
