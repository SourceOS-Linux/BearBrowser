# SourceOS Browser

SourceOS Browser is a LibreWolf-derived browser product for SourceOS.

It has two primary execution modes:

1. **Human Secure Browser** — a privacy-first desktop browser profile based on LibreWolf defaults.
2. **Agent Browser Runtime** — a governed browser execution surface for local, cloud, and fog agents.

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
