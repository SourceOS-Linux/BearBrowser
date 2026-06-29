# BearBrowser Credential Broker

BearBrowser should provide excellent credential UX without becoming a password manager or payment vault.

## Product principle

BearBrowser brokers credentials through the operating system and user-approved credential providers. It does not create a BearBrowser-owned password or payment vault by default.

## Human Secure Browser

The human-secure profile may integrate with local OS credential systems when the user grants access.

macOS targets:

- Keychain Services for secure credential storage.
- LocalAuthentication for Touch ID / biometric or device-owner unlock where available.
- Passkeys/WebAuthn through platform authenticators.

Linux targets:

- Secret Service API / GNOME Keyring.
- KWallet on KDE environments.
- libsecret-backed credential lookup where available.
- FIDO2/WebAuthn/passkeys through system/browser-supported authenticators.

## Agent Browser Runtime

The agent-runtime profile must not inherit human credentials.

Agent sessions may only receive credentials through a policy broker:

- session scoped,
- auditable,
- revocable,
- bound to workspace/session/agent IDs,
- denied by default.

## Payments and autofill

BearBrowser should not duplicate payment card storage by default. Payment and autofill data should be supplied by OS/provider integrations or user-mediated flows.

## Biometric unlock

BearBrowser must never handle fingerprint templates or biometric secrets directly. Biometric unlock is mediated by the OS. BearBrowser should request an OS unlock decision and receive only an allow/deny result.

## Required provenance events

- `browser.credential.boundary`
- `browser.credential.requested`
- `browser.credential.granted`
- `browser.credential.denied`
- `browser.credential.cleared`

Events must not contain secrets.
