#!/usr/bin/env bash
set -euo pipefail

cat <<'EOF'
BearBrowser automation surfaces

Deterministic control:
  - browser.playwright

AI-assisted action/extraction:
  - browser.stagehand

Terminal browser compatibility:
  - browser.terminal.carbonyl
  - browser.terminal.browsh
  - browser.terminal.elinks
  - browser.terminal.lynx
  - browser.terminal.text-browser-fallback

Governance rule:
  Automation frameworks provide control mechanisms, not authority.
  PolicyFabric grants authority; AgentPlane records capability; BearBrowser emits provenance.

Manifests:
  - automation/playwright-adapter.yaml
  - automation/stagehand-adapter.yaml
  - automation/terminal-browser-adapters.yaml
  - agentplane/registration.yaml
EOF
