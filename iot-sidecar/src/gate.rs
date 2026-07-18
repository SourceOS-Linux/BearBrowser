//! The gate — the ONE-ENGINE invariant.
//!
//! The sidecar reimplements NO policy. Every device command is evaluated by the
//! canonical enforcement engine, `scripts/agent-control-bridge.py --surface iot`,
//! invoked as a subprocess. We parse its Decision JSON and permit device I/O
//! ONLY when `decision == "permit"`. Any other outcome — an explicit deny, a
//! non-zero exit, a spawn failure, or unparseable output — FAILS CLOSED: the
//! device I/O never happens. This is what makes the Python injection-containment
//! proof (`scripts/tests/test_iot_injection_containment.py`) cover the Rust path
//! too: there is exactly one place physical actions are classified, and it is
//! not here.

use crate::model::Command;
use serde::Deserialize;
use std::path::PathBuf;
use tokio::process::Command as Proc;

/// The attested ReasoningEvent embedded in a decision. We keep the fields the
/// cockpit surfaces and tolerate anything else the bridge adds.
#[derive(Clone, Debug, Deserialize)]
pub struct AttestedEvent {
    #[serde(default)]
    pub id: Option<String>,
    #[serde(rename = "eventType", default)]
    pub event_type: Option<String>,
    #[serde(default)]
    pub summary: Option<String>,
    #[serde(default)]
    pub decision: Option<String>,
    #[serde(rename = "actionClass", default)]
    pub action_class: Option<String>,
}

/// The bridge's Decision JSON. Field names mirror the bridge output exactly.
#[derive(Clone, Debug, Deserialize)]
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
    #[serde(rename = "replayClass", default)]
    pub replay_class: Option<String>,
    #[serde(rename = "attestedEvent", default)]
    pub attested_event: Option<AttestedEvent>,
    #[serde(rename = "runRef", default)]
    pub run_ref: Option<String>,
}

impl Decision {
    /// The single authorization predicate. Device I/O is allowed iff this is true.
    pub fn permitted(&self) -> bool {
        self.decision == "permit"
    }

    /// Synthesize a fail-closed deny. Used when the bridge cannot be consulted
    /// or its output cannot be trusted — we deny rather than assume permit.
    fn fail_closed(action: &str, reason: impl Into<String>) -> Self {
        Decision {
            requested_action: action.to_string(),
            effective_action: Some(action.to_string()),
            action_class: "prohibited".to_string(),
            decision: "deny".to_string(),
            reason: reason.into(),
            reclassified_by: None,
            replay_class: Some("non-replayable-side-effect".to_string()),
            attested_event: None,
            run_ref: None,
        }
    }
}

/// Where the canonical bridge lives and how to invoke it.
#[derive(Clone, Debug)]
pub struct GateConfig {
    /// Python interpreter (default "python3").
    pub python: String,
    /// Absolute path to `scripts/agent-control-bridge.py`.
    pub bridge_path: PathBuf,
    /// Repo root, used as the subprocess cwd so the bridge finds the policy.
    pub repo_root: PathBuf,
}

impl GateConfig {
    /// Derive config from the repo root: `<root>/scripts/agent-control-bridge.py`.
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

/// Evaluate a command against the canonical engine.
///
/// Infallible by design: every error path folds into a fail-closed deny
/// `Decision`, so a caller that checks `decision.permitted()` can never
/// accidentally permit device I/O because the gate itself errored.
pub async fn evaluate(cfg: &GateConfig, command: &Command) -> Decision {
    let mut proc = Proc::new(&cfg.python);
    proc.arg(&cfg.bridge_path)
        .arg("--surface")
        .arg("iot")
        .arg("--action")
        .arg(&command.action)
        .arg("--json")
        .current_dir(&cfg.repo_root);

    // actor + userGesture are the ONLY things that can reclassify a prohibited
    // action down to gated. They are set by the trusted cockpit, forwarded here.
    proc.arg("--param").arg(format!("actor={}", command.actor.as_str()));
    proc.arg("--param")
        .arg(format!("userGesture={}", command.user_gesture));

    // Planner/cockpit params verbatim (e.g. includesAction=unlock-door).
    for (k, v) in &command.params {
        // actor/userGesture are supplied above from the typed fields; do not let
        // a body-supplied duplicate shadow them.
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

    // The bridge exits non-zero (3) on deny and 0 on permit. We do NOT trust the
    // exit code alone; we parse the JSON and re-check `decision == "permit"`.
    let stdout = String::from_utf8_lossy(&output.stdout);
    match serde_json::from_str::<Decision>(&stdout) {
        Ok(decision) => {
            // Defense in depth: if the process exited non-zero, never treat a
            // parsed "permit" as authoritative.
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
