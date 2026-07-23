//! Connection map — records who the session talks to, classifies each endpoint.
//! Ported from the native shell's BBConnectionRecord / BBNetworkMonitor.

use crate::model::{ConnCategory, ConnectionRecord};
use std::collections::VecDeque;
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

/// Naive eTLD+1: last two labels. Matches the shell's `etldForHost:` exactly
/// (deliberately simple — the classifier lists are keyed on these forms).
pub fn etld_plus_one(host: &str) -> String {
    if host.is_empty() {
        return String::new();
    }
    let parts: Vec<&str> = host.split('.').collect();
    if parts.len() < 2 {
        return host.to_string();
    }
    format!("{}.{}", parts[parts.len() - 2], parts[parts.len() - 1])
}

/// Classify an eTLD+1 into tracker / analytics / cdn / unknown. Lists ported
/// verbatim from the native shell's BBConnectionRecord classifier.
pub fn classify(etld: &str) -> ConnCategory {
    const TRACKERS: &[&str] = &[
        "doubleclick.net", "googlesyndication.com", "connect.facebook.net",
        "criteo.com", "adnxs.com", "rubiconproject.com", "pubmatic.com", "openx.net",
        "taboola.com", "outbrain.com", "moatads.com", "scorecardresearch.com",
        "quantserve.com", "turn.com", "bidswitch.net", "casalemedia.com",
    ];
    const ANALYTICS: &[&str] = &[
        "google-analytics.com", "googletagmanager.com", "mixpanel.com",
        "amplitude.com", "segment.io", "segment.com", "heap.io", "hotjar.com",
        "fullstory.com", "logrocket.com", "smartlook.com",
    ];
    const CDNS: &[&str] = &[
        "cloudflare.com", "fastly.net", "cloudfront.net",
        "akamaized.net", "jsdelivr.net", "unpkg.com", "amazonaws.com",
        "googleapis.com", "gstatic.com", "bootstrapcdn.com", "jquery.com",
        "cdnjs.cloudflare.com", "azureedge.net", "stackpath.bootstrapcdn.com",
    ];
    if TRACKERS.contains(&etld) {
        ConnCategory::Tracker
    } else if ANALYTICS.contains(&etld) {
        ConnCategory::Analytics
    } else if CDNS.contains(&etld) {
        ConnCategory::Cdn
    } else {
        ConnCategory::Unknown
    }
}

fn now_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// Bounded, in-memory record of observed connections. No persistence — the map
/// is per-session, exactly like the shell.
pub struct NetworkMonitor {
    recs: Mutex<VecDeque<ConnectionRecord>>,
    cap: usize,
}

impl NetworkMonitor {
    pub fn new(cap: usize) -> Self {
        NetworkMonitor {
            recs: Mutex::new(VecDeque::with_capacity(cap.min(1024))),
            cap,
        }
    }

    /// Build + store a record from a raw host, returning the built record so the
    /// caller can fan it out over the event bus.
    pub fn record(
        &self,
        host: &str,
        page_url: &str,
        resource_type: &str,
        blocked: bool,
    ) -> ConnectionRecord {
        let domain = etld_plus_one(host);
        let rec = ConnectionRecord {
            category: classify(&domain),
            domain,
            page_url: page_url.to_string(),
            resource_type: resource_type.to_string(),
            blocked,
            timestamp: now_secs(),
        };
        if let Ok(mut q) = self.recs.lock() {
            if q.len() >= self.cap {
                q.pop_front();
            }
            q.push_back(rec.clone());
        }
        rec
    }

    pub fn snapshot(&self) -> Vec<ConnectionRecord> {
        self.recs
            .lock()
            .map(|q| q.iter().cloned().collect())
            .unwrap_or_default()
    }

    pub fn clear(&self) {
        if let Ok(mut q) = self.recs.lock() {
            q.clear();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn etld_extraction() {
        assert_eq!(etld_plus_one("ad.doubleclick.net"), "doubleclick.net");
        assert_eq!(etld_plus_one("example.com"), "example.com");
        assert_eq!(etld_plus_one("localhost"), "localhost");
        assert_eq!(etld_plus_one(""), "");
    }

    #[test]
    fn classification() {
        assert_eq!(classify("doubleclick.net"), ConnCategory::Tracker);
        assert_eq!(classify("google-analytics.com"), ConnCategory::Analytics);
        assert_eq!(classify("fastly.net"), ConnCategory::Cdn);
        assert_eq!(classify("example.com"), ConnCategory::Unknown);
    }
}
