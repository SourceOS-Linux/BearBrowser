# Agent Harness Browser Receipt Surface

Status: v0.1 planning baseline  
Owner plane: BearBrowser governed browser runtime  
Consumers: SourceOS spec, AgentPlane, Policy Fabric, Memory Mesh, SCOPE-D, Delivery Excellence

## Purpose

BearBrowser is the SourceOS browser surface for humans and agents. The Aden/Hive lessons make browser control a first-class production-agent requirement, but our posture is governance-first: visible, receipt-producing, policy-gated browser work rather than stealth or unbounded browser automation.

This document defines how BearBrowser should emit browser receipts for the cross-estate agent harness loop.

## Boundary

BearBrowser owns:

- governed browser sessions
- browser action evidence
- credential-use events
- download/upload manifests
- screenshot or DOM/action pointers
- automation-surface compatibility checks
- local provenance events
- browser policy-action proposals and verifiers

BearBrowser does not own:

- AgentPlane graph execution
- Policy Fabric gate authority
- Memory Mesh artifact storage
- Delivery Excellence scoreboards
- SCOPE-D security exercise execution
- SocioSphere topology authority

## Receipt classes

### BrowserSessionReceipt

Records a governed browser session.

Required semantics:

- session id
- actor/agent ref
- workspace ref
- runtime profile
- policy admission ref
- network profile
- credential posture
- start/end timestamps
- headless/visible mode
- automation mode
- AgentPlane run/session refs

### BrowserActionReceipt

Records each meaningful browser action.

Action classes:

- navigate
- click
- type
- extract
- screenshot
- download
- upload
- form-submit
- login
- credential-use
- account-setting-change
- message-send
- purchase-or-order
- ticket-or-record-create

Required semantics:

- action id
- browser session ref
- URL/domain
- action class
- side-effect class
- policy decision ref
- screenshot pointer or DOM/action pointer
- credential-use flag
- upload/download artifact refs
- result status
- replay/simulation eligibility

### BrowserDownloadReceipt

Records files acquired through the browser.

Required semantics:

- download id
- source URL/domain
- file name
- sha256
- media type
- size
- quarantine state
- scan refs
- Memory Mesh artifact pointer ref
- retention class
- policy decision ref

### BrowserCredentialUseReceipt

Records credential access or login action.

Required semantics:

- credential event id
- browser session ref
- credential scope
- provider/account alias
- policy decision ref
- human-control event ref when required
- no raw credential material
- result status

## Policy requirements

Require Policy Fabric decisions for:

- login or credential use
- form submit
- upload
- download
- account-setting changes
- message sends
- purchase/order/ticket creation
- hidden/headless automation mode when the workflow is customer-facing or externally mutating
- any action outside the declared network profile

Fail closed when a controlled action lacks a policy decision ref.

## AgentPlane integration

AgentPlane should cite BearBrowser receipts in:

- RunArtifact
- ReplayArtifact
- SessionEnvelope
- EvidencePack
- FailureDiagnosis
- PromotionGate

Browser receipts must be treated as evidence, not informal logs.

## Memory Mesh integration

Screenshots, DOM captures, extracted pages, downloads, and large browser outputs should be represented as Memory Mesh `ArtifactPointer` refs when they are large, sensitive, replay-critical, or customer-proof relevant.

## Delivery Excellence integration

Delivery Excellence should consume derived metrics/readouts:

- browser action success/failure
- policy-blocked browser action count
- credential-use event count
- form-submit approval count
- download quarantine count
- replay-eligible browser action count
- customer-safe browser work proof

Delivery Excellence should not consume raw browser payloads unless policy explicitly permits it.

## SCOPE-D integration

SCOPE-D should validate BearBrowser workflows for:

- browser CSRF/local-origin abuse
- credential exfiltration
- malicious download bypass
- prompt injection through page content
- tool poisoning through browser-extracted instructions
- unauthorized form submit
- stealth/evasion misuse
- cross-domain network policy violations

## Non-negotiables

- BearBrowser does not default to stealth/evasion.
- Credential use is an evidence event.
- External side effects require policy refs.
- Downloads are artifact-managed and quarantine-aware.
- Customer-safe proof must be redacted and policy-approved.
- Headless mode must not erase evidence requirements.

## Near-term implementation path

1. Align existing BearBrowser provenance and policy-action schemas with this receipt surface.
2. Add examples for session, action, download, and credential-use receipts.
3. Add a verifier that ensures policy refs exist for controlled action classes.
4. Add a Delivery Excellence projection example for browser action metrics.
5. Add SCOPE-D browser-risk checks for credential, download, form-submit, and network-profile misuse.
