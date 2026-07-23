//! The gate — the ONE-ENGINE invariant (cloned from iot-sidecar).
//!
//! The sidecar reimplements NO policy. Every effectful action (start/stop/save a
//! capture, set a firewall rule) is evaluated by the canonical enforcement
//! engine, `scripts/agent-control-bridge.py --surface capture`, invoked as a
//! subprocess. We permit the action ONLY when `decision == "permit"`. Any other
//! outcome — an explicit deny, a non-zero exit, a spawn failure, or unparseable
//! output — FAILS CLOSED. Read-only reads (status, map snapshot, firewall list)
//! do NOT pass through the gate; only side effects do.

use crate::model::Command;
use serde::Deserialize;
use std::path::PathBuf;
use tokio::process::Command as Proc;

/// The attested ReasoningEvent embedded in a decision. Fields are parsed for
/// completeness and surfaced in the decision echo; not all are read on the hot
/// path, hence the allow.
#[derive(Clone, Debug, Deserialize)]
#[allow(dead_code)]
pub struct AttestedEvent {
    #[serde(default)]
    pub id: Option<String>,
    #[serde(rename = "eventType", default)]
    pub event_type: Option<String>,
    #[serde(rename = "actionClass", default)]
    pub action_class: Option<String>,
}

/// The bridge's Decision JSON. Field names mirror the bridge output exactly.
/// Several fields are echoed to the cockpit rather than read here.
#[derive(Clone, Debug, Deserialize, serde::Serialize)]
#[allow(dead_code)]
pub struct Decision {
    #[serde(rename = "requestedAction")]
    pub requested_action: String,
    #[serde(rename = "effectiveAction", default)]
    pub effective_action: Option<String>,
    #[serde(rename = "actionClass")]
    pub action_class: String,
    /// "permit" | "deny".
    pub decision: String,
    pub reason: String,
    #[serde(rename = "reclassifiedBy", default)]
    pub reclassified_by: Option<String>,
    #[serde(rename = "attestedEvent", default)]
    #[serde(skip_serializing)]
    pub attested_event: Option<AttestedEvent>,
    #[serde(rename = "runRef", default)]
    pub run_ref: Option<String>,
}

impl Decision {
    pub fn permitted(&self) -> bool {
        self.decision == "permit"
    }

    fn fail_closed(action: &str, reason: impl Into<String>) -> Self {
        Decision {
            requested_action: action.to_string(),
            effective_action: Some(action.to_string()),
            action_class: "prohibited".to_string(),
            decision: "deny".to_string(),
            reason: reason.into(),
            reclassified_by: None,
            attested_event: None,
            run_ref: None,
        }
    }
}

#[derive(Clone, Debug)]
pub struct GateConfig {
    pub python: String,
    pub bridge_path: PathBuf,
    pub repo_root: PathBuf,
}

impl GateConfig {
    pub fn from_repo_root(repo_root: impl Into<PathBuf>) -> Self {
        let repo_root = repo_root.into();
        let bridge_path = repo_root.join("scripts").join("agent-control-bridge.py");
        GateConfig {
            python: "python3".to_string(),
            bridge_path,
            repo_root,
        }
    }
}

/// Evaluate a command against the canonical engine. Infallible by design: every
/// error path folds into a fail-closed deny.
pub async fn evaluate(cfg: &GateConfig, command: &Command) -> Decision {
    let mut proc = Proc::new(&cfg.python);
    proc.arg(&cfg.bridge_path)
        .arg("--surface")
        .arg("capture")
        .arg("--action")
        .arg(&command.action)
        .arg("--json")
        .current_dir(&cfg.repo_root);

    proc.arg("--param").arg(format!("actor={}", command.actor.as_str()));
    proc.arg("--param")
        .arg(format!("userGesture={}", command.user_gesture));

    for (k, v) in &command.params {
        if k == "actor" || k == "userGesture" {
            continue;
        }
        proc.arg("--param").arg(format!("{k}={v}"));
    }

    if let Some(token) = &command.approval_token {
        proc.arg("--approval-token").arg(token);
    }

    let output = match proc.output().await {
        Ok(o) => o,
        Err(e) => {
            tracing::error!(action = %command.action, error = %e, "gate: bridge spawn failed");
            return Decision::fail_closed(
                &command.action,
                format!("gate: bridge spawn failed: {e}"),
            );
        }
    };

    let stdout = String::from_utf8_lossy(&output.stdout);
    match serde_json::from_str::<Decision>(&stdout) {
        Ok(decision) => {
            if !output.status.success() && decision.permitted() {
                tracing::warn!(
                    action = %command.action,
                    "gate: bridge reported permit but exited non-zero; failing closed"
                );
                return Decision::fail_closed(
                    &command.action,
                    "gate: bridge permit contradicted by non-zero exit",
                );
            }
            decision
        }
        Err(e) => {
            tracing::error!(action = %command.action, error = %e, "gate: unparseable bridge output; failing closed");
            Decision::fail_closed(
                &command.action,
                format!("gate: unparseable bridge output: {e}"),
            )
        }
    }
}
