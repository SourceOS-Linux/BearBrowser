//! Live connection monitor — the Little Snitch-style core. Polls the OS
//! connection table (`lsof`) for established outbound TCP, reverse-resolves the
//! remote IPs to their owners, classifies them, and streams connections as they
//! open and close. NEEDS NO ROOT — this is the real, working network surface
//! (raw packet capture, which does need BPF, is the separate power tool).

use crate::firewall::Firewall;
use crate::model::{ConnectionRecord, FirewallDecision, Scope, SidecarEvent};
use crate::netmap::{classify, etld_plus_one, now_secs, NetworkMonitor};
use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex, RwLock};
use std::time::Duration;
use tokio::process::Command;
use tokio::sync::broadcast;

/// Shared, runtime-switchable monitor scope (browser-only vs whole machine).
pub type SharedScope = Arc<RwLock<Scope>>;

/// One row parsed from lsof: owning process + remote endpoint.
struct Raw {
    process: String,
    remote_ip: String,
    remote_port: String,
}

/// Run `lsof` once and parse established outbound TCP connections. Uses field
/// output (-F) so it's robust to spaces in process names. Best-effort: any
/// error yields an empty list (the monitor just shows nothing that tick).
async fn poll_lsof() -> Vec<Raw> {
    let out = Command::new("lsof")
        .args(["-nP", "-iTCP", "-sTCP:ESTABLISHED", "-Fpcn"])
        .output()
        .await;
    let Ok(out) = out else { return Vec::new() };
    let text = String::from_utf8_lossy(&out.stdout);

    let mut rows = Vec::new();
    let mut cur_proc = String::new();
    for line in text.lines() {
        if line.is_empty() {
            continue;
        }
        let (tag, val) = (&line[..1], &line[1..]);
        match tag {
            "c" => cur_proc = val.to_string(),
            "n" => {
                // name looks like "192.168.1.172:63468->172.64.41.4:443"
                if let Some((_local, remote)) = val.split_once("->") {
                    // Strip a trailing " (STATE)" if present.
                    let remote = remote.split_whitespace().next().unwrap_or(remote);
                    // Split host:port from the right (IPv6 has colons too).
                    if let Some(idx) = remote.rfind(':') {
                        let (host, port) = remote.split_at(idx);
                        let host = host.trim_matches(['[', ']']);
                        rows.push(Raw {
                            process: cur_proc.clone(),
                            remote_ip: host.to_string(),
                            remote_port: port[1..].to_string(),
                        });
                    }
                }
            }
            _ => {}
        }
    }
    rows
}

/// Does this process belong to the browser? (scope=Browser filter)
fn is_browser(proc: &str) -> bool {
    let p = proc.to_ascii_lowercase();
    p.contains("bearbrowser") || p.contains("firefox") || p.contains("librewolf")
}

/// Reverse-resolve an IP to an owner domain (eTLD+1), cached. Best-effort via
/// the system `dig`; a missing PTR (common for Cloudflare etc.) falls back to
/// the bare IP so the node still shows.
async fn reverse_owner(ip: &str, cache: &Mutex<HashMap<String, String>>) -> String {
    if let Ok(c) = cache.lock() {
        if let Some(v) = c.get(ip) {
            return v.clone();
        }
    }
    let ptr = Command::new("dig")
        .args(["+short", "+time=1", "+tries=1", "-x", ip])
        .output()
        .await
        .ok()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .unwrap_or_default();
    let owner = ptr
        .lines()
        .next()
        .map(|l| l.trim_end_matches('.'))
        .filter(|l| !l.is_empty())
        .map(etld_plus_one)
        .unwrap_or_else(|| ip.to_string());
    if let Ok(mut c) = cache.lock() {
        c.insert(ip.to_string(), owner.clone());
    }
    owner
}

/// Spawn the polling loop. Returns immediately; runs until the process exits.
pub fn spawn(
    monitor: Arc<NetworkMonitor>,
    firewall: Arc<Firewall>,
    events: broadcast::Sender<SidecarEvent>,
    scope: SharedScope,
) {
    tokio::spawn(async move {
        let dns_cache: Mutex<HashMap<String, String>> = Mutex::new(HashMap::new());
        loop {
            let want_browser = matches!(*scope.read().unwrap(), Scope::Browser);
            let rows = poll_lsof().await;

            let mut live_keys: HashSet<String> = HashSet::new();
            for r in rows {
                if want_browser && !is_browser(&r.process) {
                    continue;
                }
                // Skip loopback / link-local noise.
                if r.remote_ip.starts_with("127.") || r.remote_ip == "::1" {
                    continue;
                }
                let key = format!("conn|{}|{}:{}", r.process, r.remote_ip, r.remote_port);
                live_keys.insert(key.clone());

                // reverse_owner already returns the final label (eTLD+1 for a
                // resolved host, or the bare IP when there's no PTR) — do NOT
                // eTLD+1 it again or an IP like 151.101.129.91 becomes "129.91".
                let domain = reverse_owner(&r.remote_ip, &dns_cache).await;
                let blocked = firewall.decision_for(&domain) == FirewallDecision::Block;
                let rec = ConnectionRecord {
                    key: key.clone(),
                    category: classify(&domain),
                    domain: if domain.is_empty() { r.remote_ip.clone() } else { domain },
                    page_url: String::new(),
                    resource_type: "tcp".to_string(),
                    process: r.process.clone(),
                    remote: format!("{}:{}", r.remote_ip, r.remote_port),
                    blocked,
                    timestamp: now_secs(),
                };
                monitor.upsert(rec.clone());
                let _ = events.send(SidecarEvent::Connection(rec));
            }

            // Reap connections the monitor owns (conn|…) that are no longer live.
            for key in monitor.keys() {
                if key.starts_with("conn|") && !live_keys.contains(&key) {
                    if monitor.remove(&key) {
                        let _ = events.send(SidecarEvent::ConnectionClosed { key });
                    }
                }
            }

            tokio::time::sleep(Duration::from_secs(3)).await;
        }
    });
}
