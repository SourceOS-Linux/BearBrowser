# BearBrowser Architecture

## Human Secure Browser

The human profile should inherit LibreWolf's privacy/security posture and add SourceOS workspace integration.

Expected properties:

- privacy-first defaults
- hardened browser policy
- controlled downloads location
- explicit workspace document handoff
- no agent automation by default
- no credential sharing with agent profiles

## Agent Browser Runtime

The agent-runtime profile is a governed execution surface.

Expected properties:

- ephemeral profile support
- controlled downloads mount
- screenshot capture
- DOM/export capture
- provenance/event log emission
- network policy enforcement
- file-system policy enforcement
- credential isolation
- Matrix/Hermes integration path
- AgentPlane registration
- PolicyFabric enforcement
- Prophet Workspace visibility
