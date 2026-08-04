# BearBrowser

BearBrowser is a sovereign, privacy-first SourceOS browser for humans and agents.

It has two primary execution modes:

1. **Human Secure Browser** — a privacy-first desktop browser with hardened upstream defaults.
2. **Agent Browser Runtime** — a governed browser execution surface for local, cloud, and fog agents.

## Install

Homebrew is a first-class distribution surface.

Immediate direct Formula install:

```bash
brew install --formula https://raw.githubusercontent.com/SourceOS-Linux/BearBrowser/main/packaging/homebrew/Formula/bearbrowser.rb
```

Target install path after the SourceOS tap is promoted:

```bash
brew install SourceOS-Linux/tap/bearbrowser
```

Update:

```bash
bearbrowser-update
```

Diagnostics:

```bash
bearbrowser-doctor
bearbrowser-verify-upstream
bearbrowser-verify-control-plane
bearbrowser-verify-native-shell
bearbrowser-automation-surfaces
```

Future GUI app install path:

```bash
brew install --cask SourceOS-Linux/tap/bearbrowser
```

See `docs/install.md` and `packaging/homebrew/README.md`.

## SourceOS control plane

BearBrowser now carries explicit SourceOS control-plane manifests under `manifests/sourceos/`:

- `manifests/sourceos/service.json` — product/service graph, capabilities, authority domain, data classes, launch triggers, resource budget, and observability posture.
- `manifests/sourceos/launch.macos.json` — hermetic macOS launch contract, bundle identity, expected process identity, PATH policy, denied shell-pollution variables, and product identity invariants.

Verify the contract locally:

```bash
python3 scripts/verify-sourceos-control-plane.py
```

Installed Homebrew command:

```bash
bearbrowser-verify-control-plane
```

The verifier checks that BearBrowser remains BearBrowser across service manifest, macOS bundle identity, Dock/menu/crash/helper naming, launcher scripts, native WebKit bootstrap shell, product PATH policy, and upstream provenance boundaries. Upstream engine names such as LibreWolf, Firefox, Mozilla, and Gecko are allowed as provenance, source, and license metadata; they must not become the user-facing product identity.

The doctor also runs this verifier:

```bash
bearbrowser-doctor
```

## Automation surfaces

BearBrowser treats browser automation as a first-class product surface:

- Playwright for deterministic browser control.
- Stagehand for AI-assisted browser actions and extraction.
- Terminal-browser compatibility for Carbonyl, Browsh, ELinks, Lynx, w3m, and Links-style environments.

See `docs/automation-compatibility.md`.

## Upstream model

The clean upstream mirror lives at:

- `SourceOS-Linux/librewolf-source-mirror`

This repository contains SourceOS overlays only:

- patch queues
- settings profiles
- enterprise/browser policies
- agent-runtime policy contracts
- downloads and workspace mount declarations
- packaging manifests
- SourceOS control-plane manifests
- AgentPlane registration
- Prophet Workspace integration
- parity and maintenance scripts

## Rule

Do not bury SourceOS product behavior inside the upstream mirror. Keep the mirror clean. Keep SourceOS changes explicit here.
