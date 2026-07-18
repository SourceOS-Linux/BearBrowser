//! Credential seam.
//!
//! The sidecar MUST NOT store device credentials. Adapters that need a secret
//! (a Home Assistant long-lived token, an MQTT password, a HomeKit pairing key)
//! fetch it, per-use, from the repo's existing `credential-broker/`, which is
//! the single OS-mediated vault boundary (Keychain / Secret Service / etc — see
//! `credential-broker/{macos,linux}-backends.yaml`). Secrets are never persisted
//! in the sidecar's SQLite store and never logged.
//!
//! The transport to the broker is intentionally left as a TODO seam: the broker
//! ships today as a policy/backend contract (YAML), not a live socket in this
//! repo. When the broker daemon lands, implement `BrokerTransport` for its
//! actual IPC (unix socket / native-messaging) — nothing above this seam changes.

use anyhow::{bail, Result};
use std::path::PathBuf;

/// An opaque handle to a secret. Adapters hold a handle, never the secret; the
/// secret materializes only for the duration of a single broker call.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SecretHandle {
    /// Logical credential name the broker resolves (e.g. "ha.longLivedToken").
    pub name: String,
    /// Purpose string for the broker's audit event.
    pub purpose: String,
}

impl SecretHandle {
    pub fn new(name: impl Into<String>, purpose: impl Into<String>) -> Self {
        SecretHandle {
            name: name.into(),
            purpose: purpose.into(),
        }
    }
}

/// A resolved secret. Deliberately NOT `Clone`/`Serialize`; it is consumed at
/// the point of use and dropped. `Debug` redacts the material.
pub struct Secret {
    material: String,
}

impl Secret {
    pub fn expose(&self) -> &str {
        &self.material
    }
}

impl std::fmt::Debug for Secret {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("Secret(<redacted>)")
    }
}

/// The transport-agnostic broker seam. The rest of the sidecar depends only on
/// this trait, so the wire protocol can change without touching adapters.
#[async_trait::async_trait]
pub trait BrokerTransport: Send + Sync {
    async fn resolve(&self, handle: &SecretHandle) -> Result<Secret>;
}

/// Client for the local credential-broker. `endpoint` is the broker's IPC path
/// (unix socket) once the daemon exists.
#[derive(Clone, Debug)]
pub struct CredentialBroker {
    pub endpoint: Option<PathBuf>,
}

impl CredentialBroker {
    /// Locate the broker relative to the repo root. Today this only records the
    /// expected endpoint; the daemon is not yet present in the repo.
    pub fn from_repo_root(repo_root: &std::path::Path) -> Self {
        // Convention: the broker exposes a loopback unix socket under the repo's
        // runtime dir. Kept as the expected path so wiring is a one-line change.
        let endpoint = repo_root.join("runtime").join("credential-broker.sock");
        CredentialBroker {
            endpoint: Some(endpoint),
        }
    }
}

#[async_trait::async_trait]
impl BrokerTransport for CredentialBroker {
    async fn resolve(&self, _handle: &SecretHandle) -> Result<Secret> {
        // TODO(credential-broker): connect to `self.endpoint` and perform the
        // user/policy-mediated secret resolution. Until the broker daemon is
        // wired, fail closed — never fabricate or cache a secret. An adapter
        // that reaches this path simply cannot perform authenticated I/O yet,
        // which is the correct, safe default.
        bail!(
            "credential-broker transport not yet wired (expected endpoint: {:?}); \
             adapters must not fabricate secrets",
            self.endpoint
        )
    }
}
