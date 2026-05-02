# BearBrowser Agent Runtime Threat Model

BearBrowser Agent Runtime is a governed browser execution surface for local, cloud, and fog agents. It must be treated as a high-risk automation boundary because browsers bridge untrusted web content, user workspace data, credentials, downloads, and agent decision loops.

## Assets

- Human browser profile state
- Agent browser profile state
- Cookies, local storage, session storage, and cache
- Downloads and generated files
- Screenshots, DOM snapshots, PDFs, HAR files, and exported artifacts
- Workspace input files
- User credentials and policy-brokered tokens
- AgentPlane provenance records
- PolicyFabric decisions
- Prophet Workspace-visible session state

## Primary threats

### Credential bleed

A browser session must not share cookies, local storage, credentials, or profile state between the human profile and agent runtime. Agent credentials must be session-scoped and supplied only through a policy broker.

Default control: deny credential export, deny human profile sharing, emit credential-boundary events.

### Ambient host access

An agent browser must not inherit access to the operator home directory, SSH keys, cloud credentials, Kubernetes configs, GitHub CLI state, container sockets, or arbitrary host paths.

Default control: no ambient host mounts; only governed mount classes are allowed.

### Web-to-workspace pivot

Untrusted web content may attempt to influence downloads, file names, browser protocol handlers, clipboard content, native messaging, extension installation, or local file access.

Default control: downloads are confined to governed mounts; native messaging and extensions are denied unless allowlisted; clipboard is denied by default for agent runtime.

### Network pivot

Browser sessions can be abused for SSRF-like access to private networks, loopback services, metadata endpoints, and internal control planes.

Default control: deny private networks, loopback, metadata services, and all egress unless policy grants access.

### Capture leakage

Screenshots, DOM snapshots, PDFs, and HAR files may contain sensitive information.

Default control: capture is policy-mediated, stored in governed mounts, and requires provenance events plus content hashes.

### Persistence abuse

A malicious page, extension, or compromised agent may attempt to persist state across sessions.

Default control: agent profile and cache are ephemeral by default and cleaned on exit.

### Automation ambiguity

Browser automation without provenance makes it hard to distinguish user action, agent action, web content behavior, and policy-broker behavior.

Default control: all agent browser sessions require session ID, agent ID, workspace ID, provenance events, and PolicyFabric decision linkage.

## Security posture

The agent runtime is default-deny. Any access to network destinations, host files, credentials, native messaging, extensions, screenshots, DOM snapshots, or clipboard must be explicitly granted by policy.

## Non-goals for v1

- Sharing human browser cookies with agents
- Persistent agent profiles by default
- Ambient local filesystem access
- Unrestricted browser extensions
- Unrestricted remote debugging
- Unmediated native messaging
