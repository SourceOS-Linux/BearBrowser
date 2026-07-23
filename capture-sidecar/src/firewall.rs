//! Per-domain firewall — Ask / Allow / Block, persisted across sessions.
//! Ported from the native shell's BBFirewall (which used NSUserDefaults); here
//! rules persist to a small JSON file under the sidecar state dir.

use crate::model::FirewallDecision;
use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::Mutex;

pub struct Firewall {
    rules: Mutex<BTreeMap<String, FirewallDecision>>,
    path: Option<PathBuf>,
}

impl Firewall {
    /// Load rules from `path` if present. A missing/corrupt file yields an empty
    /// ruleset (fail-open to "Ask", never a hard error — the browser must boot).
    pub fn load(path: Option<PathBuf>) -> Self {
        let rules = path
            .as_ref()
            .and_then(|p| std::fs::read_to_string(p).ok())
            .and_then(|s| serde_json::from_str::<BTreeMap<String, FirewallDecision>>(&s).ok())
            .unwrap_or_default();
        Firewall {
            rules: Mutex::new(rules),
            path,
        }
    }

    pub fn decision_for(&self, domain: &str) -> FirewallDecision {
        self.rules
            .lock()
            .ok()
            .and_then(|r| r.get(domain).copied())
            .unwrap_or(FirewallDecision::Ask)
    }

    /// Set (or clear, when Ask) a rule and persist. `Ask` removes the entry so
    /// the ruleset only stores explicit decisions — matching the shell.
    pub fn set(&self, domain: &str, decision: FirewallDecision) {
        if let Ok(mut r) = self.rules.lock() {
            match decision {
                FirewallDecision::Ask => {
                    r.remove(domain);
                }
                d => {
                    r.insert(domain.to_string(), d);
                }
            }
            self.persist(&r);
        }
    }

    pub fn all(&self) -> BTreeMap<String, FirewallDecision> {
        self.rules.lock().map(|r| r.clone()).unwrap_or_default()
    }

    pub fn clear(&self) {
        if let Ok(mut r) = self.rules.lock() {
            r.clear();
            self.persist(&r);
        }
    }

    fn persist(&self, rules: &BTreeMap<String, FirewallDecision>) {
        let Some(path) = &self.path else { return };
        if let Some(parent) = path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        if let Ok(json) = serde_json::to_string_pretty(rules) {
            // Best-effort: a failed write must not crash the browser's sidecar.
            let _ = std::fs::write(path, json);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn set_get_and_ask_clears() {
        let fw = Firewall::load(None);
        assert_eq!(fw.decision_for("x.com"), FirewallDecision::Ask);
        fw.set("x.com", FirewallDecision::Block);
        assert_eq!(fw.decision_for("x.com"), FirewallDecision::Block);
        fw.set("x.com", FirewallDecision::Ask);
        assert_eq!(fw.decision_for("x.com"), FirewallDecision::Ask);
        assert!(fw.all().is_empty());
    }

    #[test]
    fn persists_round_trip() {
        let dir = std::env::temp_dir().join(format!("bb-fw-{}", uuid::Uuid::new_v4()));
        let path = dir.join("firewall.json");
        {
            let fw = Firewall::load(Some(path.clone()));
            fw.set("ads.example", FirewallDecision::Block);
            fw.set("good.example", FirewallDecision::Allow);
        }
        let fw2 = Firewall::load(Some(path.clone()));
        assert_eq!(fw2.decision_for("ads.example"), FirewallDecision::Block);
        assert_eq!(fw2.decision_for("good.example"), FirewallDecision::Allow);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
