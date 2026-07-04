# BearHistory: Local-First Browser History and OpsHistory Bridge

BearHistory is BearBrowser's local-first browser history, session, capture, and automation event substrate.

It is not a centralized browser account system. It is a governed local-first event store that can replicate selected browser state across devices and export selected agent-runtime browser events into OpsHistory.

## Goals

BearHistory must provide:

- local-first storage for navigation and session state;
- explicit sync policy instead of opaque remote configuration;
- faster deletion, redaction, and tombstone propagation than ordinary hydration;
- bounded payload windows and throttling controls;
- hard separation between human-secure and agent-runtime profiles;
- auditable export into AgentPlane, Memory Mesh, AgentTerm, and OpsHistory;
- PolicyFabric authority for export, hydration, capture, replication, credential-boundary, and redaction decisions.

## State classes

BearHistory events may represent:

- navigation;
- tab and session graph;
- download metadata;
- capture metadata;
- automation action;
- policy decision reference;
- credential-boundary event;
- deletion, redaction, or tombstone;
- artifact reference.

## Profile separation

Human-secure profile:

- owns human browsing state;
- uses OS-native credential broker where allowed;
- does not export human profile state to agents by default;
- may sync across user-approved devices under policy.

Agent-runtime profile:

- owns governed browser execution traces;
- does not inherit human cookies, credentials, or session state;
- may export redacted browser events into OpsHistory when PolicyFabric allows;
- uses session-scoped policy-brokered credentials only.

## Local-first sync posture

BearHistory stores state locally first. Replication is optional and policy-controlled.

Core sync controls:

- `mode`: disabled, localOnly, singleDevice, multiDevice, or opsExportOnly;
- `syncWindowSeconds`: maximum lookback window for ordinary hydration;
- `payloadCapBytes`: maximum serialized payload size;
- `idleDelayMs`: delay before opportunistic writes;
- `saveDebounceMs`: debounce delay for save bursts;
- `fetchThrottleMs`: minimum fetch interval;
- `shutdownTimeoutMs`: final flush budget;
- `deletePriority`: deletion/redaction/tombstone priority lane.

## Deletion priority lane

Deletion, redaction, and tombstone events are not ordinary history updates. They must propagate through a priority lane so remote or secondary indexes converge toward removal quickly.

Deletion lane requirements:

- deletion events carry policy decision references;
- tombstones carry event IDs and redaction scope;
- secret-bearing payloads are not replicated;
- downstream stores must acknowledge tombstones;
- human profile redactions are not exported to agents unless policy explicitly permits a redacted summary.

## OpsHistory bridge

OpsHistory is the operational event layer used by agents, AgentTerm, Memory Mesh, and AgentPlane.

BearHistory may export agent-runtime events into OpsHistory when:

- the source profile is `agent-runtime`;
- PolicyFabric grants export;
- the event is redacted;
- any artifact reference is governed;
- credential-boundary events contain no secrets;
- evidence refs and policy refs are included.

Human-secure events are not exported to OpsHistory by default.

## Dry-run command surface

This implementation slice adds `bearbrowser-history` as a dry-run contract surface. The command does not read browser profiles, cookies, credentials, history databases, downloads, captures, or automation traces.

Commands:

```bash
bearbrowser-history policy explain --profile human-secure --dry-run
bearbrowser-history policy explain --profile agent-runtime --dry-run
bearbrowser-history export explain --session demo --profile agent-runtime --dry-run
bearbrowser-history redactions --dry-run
```

Expected posture:

- human-secure export outcome is `deny`;
- agent-runtime export outcome is `metadata-only` until PolicyFabric and Agent Registry permit stronger behavior;
- credentials, cookies, and ambient session material are always absent in this slice;
- redaction posture is critical priority and invalidates downstream OpsHistory exports, context packs, and memory writebacks.

## Future service model

The future service boundary is `bearhistoryd`, represented by `urn:srcos:local-first-service:bearhistoryd`.

Expected local endpoint names:

- `org.sourceos.BearHistory`;
- `org.sourceos.BearHistory.Push`;
- `org.sourceos.BearHistory.Redaction`;
- `org.sourceos.BearHistory.Export`.

## Non-goals

BearHistory does not provide:

- a centralized BearBrowser cloud account system;
- a custom password vault;
- a custom payment vault;
- ambient agent access to human cookies, credentials, or sessions;
- hidden remote behavior that cannot be explained locally.

## Explainability

BearBrowser should expose a doctor/explain path for BearHistory policy:

- current sync mode;
- profile separation posture;
- last hydration/export decision;
- active throttle windows;
- deletion queue state;
- policy decision IDs;
- blocked export reasons;
- redaction status.

## Validation

The Homebrew Formula exposes `bearbrowser-history` and checks:

```bash
bearbrowser-history policy explain --profile agent-runtime --dry-run
bearbrowser-history export explain --session demo --profile agent-runtime --dry-run
```
