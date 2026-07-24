//! Connection map — records who the session talks to, classifies each endpoint.
//! Ported from the native shell's BBConnectionRecord / BBNetworkMonitor.

use crate::model::{ConnCategory, ConnectionRecord};
use std::collections::HashMap;
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

pub fn now_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// Live map of active/recent connections, keyed for in-place graph updates.
/// The live OS monitor upserts on each poll and removes when a connection
/// disappears; the browser hook upserts one-shot request records.
pub struct NetworkMonitor {
    conns: Mutex<HashMap<String, ConnectionRecord>>,
    cap: usize,
}

impl NetworkMonitor {
    pub fn new(cap: usize) -> Self {
        NetworkMonitor {
            conns: Mutex::new(HashMap::new()),
            cap,
        }
    }

    /// Build a classified record from a browser-hook observation (host + page +
    /// type). Keyed by domain|type so repeat requests coalesce into one node.
    pub fn record(
        &self,
        host: &str,
        page_url: &str,
        resource_type: &str,
        blocked: bool,
    ) -> ConnectionRecord {
        let domain = etld_plus_one(host);
        let key = format!("host|{domain}|{resource_type}");
        let rec = ConnectionRecord {
            key,
            category: classify(&domain),
            domain,
            page_url: page_url.to_string(),
            resource_type: resource_type.to_string(),
            process: String::new(),
            remote: String::new(),
            blocked,
            timestamp: now_secs(),
        };
        self.upsert(rec.clone());
        rec
    }

    /// Insert or refresh a connection node by its key.
    pub fn upsert(&self, rec: ConnectionRecord) {
        if let Ok(mut m) = self.conns.lock() {
            if m.len() >= self.cap && !m.contains_key(&rec.key) {
                // Evict the oldest to stay bounded.
                if let Some(oldest) = m
                    .values()
                    .min_by_key(|r| r.timestamp)
                    .map(|r| r.key.clone())
                {
                    m.remove(&oldest);
                }
            }
            m.insert(rec.key.clone(), rec);
        }
    }

    /// Remove a connection node (the live monitor no longer sees it).
    pub fn remove(&self, key: &str) -> bool {
        self.conns
            .lock()
            .map(|mut m| m.remove(key).is_some())
            .unwrap_or(false)
    }

    /// Keys currently present (used by the monitor to diff each poll).
    pub fn keys(&self) -> Vec<String> {
        self.conns
            .lock()
            .map(|m| m.keys().cloned().collect())
            .unwrap_or_default()
    }

    pub fn snapshot(&self) -> Vec<ConnectionRecord> {
        self.conns
            .lock()
            .map(|m| {
                let mut v: Vec<_> = m.values().cloned().collect();
                v.sort_by(|a, b| b.timestamp.cmp(&a.timestamp));
                v
            })
            .unwrap_or_default()
    }

    pub fn clear(&self) {
        if let Ok(mut m) = self.conns.lock() {
            m.clear();
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
