//! Deep OSINT for an endpoint — aggregates several FREE, no-key intelligence
//! sources in parallel. Every one of these SENDS THE IP/DOMAIN to a third party,
//! so this is only ever reached on an explicit, gated user "Investigate" — never
//! from the passive monitor. Fetched via curl so the sidecar needs no TLS dep;
//! each source is best-effort and independently timed out, so one slow provider
//! never blocks the rest.

use serde_json::{json, Value};
use std::time::Duration;
use tokio::process::Command;

/// GET a URL via curl, bounded. None on any failure/timeout.
async fn curl_get(url: &str, accept: Option<&str>, secs: u64) -> Option<String> {
    let mut args: Vec<String> = vec![
        "-sSL".into(),
        "--max-time".into(),
        secs.to_string(),
        "-A".into(),
        "BearBrowser-OSINT/1.0".into(),
    ];
    if let Some(a) = accept {
        args.push("-H".into());
        args.push(format!("Accept: {a}"));
    }
    args.push(url.to_string());
    let child = Command::new("curl")
        .args(&args)
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .kill_on_drop(true)
        .spawn()
        .ok()?;
    let out = tokio::time::timeout(Duration::from_secs(secs + 2), child.wait_with_output())
        .await
        .ok()?
        .ok()?;
    Some(String::from_utf8_lossy(&out.stdout).to_string())
}

/// Registry ownership (RDAP → the authoritative RIR).
fn parse_rdap(text: &str) -> Value {
    let v: Value = serde_json::from_str(text).unwrap_or(json!({}));
    let s = |x: &Value| x.as_str().map(|s| s.to_string());
    let cidr = v["cidr0_cidrs"].as_array().and_then(|a| a.first()).map(|c| {
        let pfx = c["v4prefix"].as_str().or_else(|| c["v6prefix"].as_str()).unwrap_or("");
        format!("{}/{}", pfx, c["length"].as_u64().unwrap_or(0))
    });
    let range = match (s(&v["startAddress"]), s(&v["endAddress"])) {
        (Some(a), Some(b)) => Some(format!("{a} – {b}")),
        _ => None,
    };
    let mut owner = None;
    let mut abuse = None;
    if let Some(entities) = v["entities"].as_array() {
        for e in entities {
            let roles: Vec<&str> = e["roles"].as_array().map(|r| r.iter().filter_map(|x| x.as_str()).collect()).unwrap_or_default();
            if let Some(vc) = e["vcardArray"].as_array().and_then(|a| a.get(1)).and_then(|x| x.as_array()) {
                for item in vc {
                    if let Some(arr) = item.as_array() {
                        let field = arr.first().and_then(|x| x.as_str());
                        let val = arr.get(3).and_then(|x| x.as_str()).map(|s| s.to_string());
                        match field {
                            Some("fn") if roles.contains(&"registrant") && owner.is_none() => owner = val,
                            Some("email") if roles.contains(&"abuse") && abuse.is_none() => abuse = val,
                            _ => {}
                        }
                    }
                }
            }
        }
    }
    let event = |action: &str| -> Option<String> {
        v["events"].as_array().and_then(|a| {
            a.iter()
                .find(|e| e["eventAction"] == action)
                .and_then(|e| e["eventDate"].as_str())
                .map(|d| d.split('T').next().unwrap_or(d).to_string())
        })
    };
    json!({
        "owner": owner.or_else(|| s(&v["name"])),
        "netName": s(&v["name"]),
        "netRange": cidr.or(range),
        "type": s(&v["type"]),
        "country": s(&v["country"]),
        "registered": event("registration"),
        "updated": event("last changed"),
        "abuse": abuse,
    })
}

/// Shodan InternetDB — open ports / CPEs / tags / vulns / hostnames. Free, no key.
fn parse_shodan(text: &str) -> Value {
    let v: Value = serde_json::from_str(text).unwrap_or(json!({}));
    // InternetDB returns {"detail":"No information..."} for unknown IPs.
    if v.get("detail").is_some() {
        return json!({});
    }
    json!({
        "ports": v["ports"],
        "vulns": v["vulns"],
        "hostnames": v["hostnames"],
        "tags": v["tags"],
        "cpes": v["cpes"],
    })
}

/// HackerTarget reverse-IP — other domains sharing this IP. Free (rate-limited).
fn parse_reverse_ip(text: &str) -> Value {
    // Errors come back as a single line like "error check your search parameter".
    if text.is_empty() || text.to_ascii_lowercase().starts_with("error") || text.contains("API count exceeded") {
        return json!([]);
    }
    let domains: Vec<String> = text
        .lines()
        .map(|l| l.trim().to_string())
        .filter(|l| !l.is_empty() && l.contains('.'))
        .take(40)
        .collect();
    json!(domains)
}

/// crt.sh certificate transparency — subdomains seen in issued certs. Free.
fn parse_crtsh(text: &str) -> Value {
    let v: Value = serde_json::from_str(text).unwrap_or(json!([]));
    let mut set: std::collections::BTreeSet<String> = Default::default();
    if let Some(arr) = v.as_array() {
        for c in arr {
            if let Some(nv) = c["name_value"].as_str() {
                for name in nv.split('\n') {
                    let name = name.trim().trim_start_matches("*.");
                    if !name.is_empty() {
                        set.insert(name.to_string());
                    }
                }
            }
        }
    }
    json!(set.into_iter().take(30).collect::<Vec<_>>())
}

/// Fan out to every free source in parallel and aggregate. `domain` is used for
/// the cert-transparency lookup (skipped when it's just an IP).
pub async fn investigate(ip: &str, domain: &str) -> Value {
    let do_crt = !domain.is_empty() && domain.parse::<std::net::IpAddr>().is_err() && domain.contains('.');
    // Named locals so the borrows live across the join!'s await points.
    let rdap_url = format!("https://rdap.org/ip/{ip}");
    let shodan_url = format!("https://internetdb.shodan.io/{ip}");
    let revip_url = format!("https://api.hackertarget.com/reverseiplookup/?q={ip}");
    // %25 = urlencoded '%' wildcard → subdomains of the domain, not just exact.
    let crt_url = format!("https://crt.sh/?q=%25.{}&output=json", domain);

    let (rdap, shodan, revip, crt) = tokio::join!(
        curl_get(&rdap_url, Some("application/rdap+json"), 8),
        curl_get(&shodan_url, Some("application/json"), 6),
        curl_get(&revip_url, None, 6),
        async {
            if do_crt {
                // crt.sh is notoriously slow; give it more headroom, best-effort.
                curl_get(&crt_url, Some("application/json"), 12).await
            } else {
                None
            }
        },
    );

    json!({
        "ip": ip,
        "registry": rdap.as_deref().map(parse_rdap).unwrap_or(json!({})),
        "host": shodan.as_deref().map(parse_shodan).unwrap_or(json!({})),
        "otherDomains": revip.as_deref().map(parse_reverse_ip).unwrap_or(json!([])),
        "subdomains": crt.as_deref().map(parse_crtsh).unwrap_or(json!([])),
    })
}
