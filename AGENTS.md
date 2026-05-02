# Agent Instructions

This repo is the BearBrowser product overlay.

Agents must preserve the upstream parity model:

- Do not vendor arbitrary LibreWolf source into this repo.
- Do not commit directly into `SourceOS-Linux/librewolf-source-mirror`.
- Treat the mirror as read-only upstream state except when running the approved sync script.
- Keep SourceOS changes as patches, policy, settings, packaging, and integration contracts.
- Separate human browser behavior from agent browser behavior.
- Every browser capability exposed to agents must have an explicit policy surface.
- Downloads, screenshots, profile state, cookies, credentials, native messaging, and file access are governed resources.
