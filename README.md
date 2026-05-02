# BearBrowser

BearBrowser is a LibreWolf-derived SourceOS browser product for humans and agents.

It has two primary execution modes:

1. **Human Secure Browser** — a privacy-first desktop browser profile based on LibreWolf defaults.
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
bearbrowser-automation-surfaces
```

Future GUI app install path:

```bash
brew install --cask SourceOS-Linux/tap/bearbrowser
```

See `docs/install.md` and `packaging/homebrew/README.md`.

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
- AgentPlane registration
- Prophet Workspace integration
- parity and maintenance scripts

## Rule

Do not bury SourceOS product behavior inside the upstream mirror. Keep the mirror clean. Keep SourceOS changes explicit here.
