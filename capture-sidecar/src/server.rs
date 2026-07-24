//! Loopback REST + WS server. Refuses any non-loopback bind. Read-only routes
//! (status, map, firewall list) answer directly; every side effect (capture
//! start/stop/save, firewall set) is gated through the canonical bridge first.

use crate::capture::{self, Session};
use crate::gate::{self, Decision, GateConfig};
use crate::firewall::Firewall;
use crate::model::{Actor, Command, FirewallDecision, SidecarEvent};
use crate::netmap::NetworkMonitor;
use anyhow::{bail, Context, Result};
use axum::extract::ws::{Message, WebSocket, WebSocketUpgrade};
use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use serde::Deserialize;
use serde_json::json;
use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::Arc;
use tokio::sync::{broadcast, Mutex};
use tower_http::cors::{Any, CorsLayer};

#[derive(Clone)]
pub struct AppState {
    pub gate: Arc<GateConfig>,
    pub firewall: Arc<Firewall>,
    pub monitor: Arc<NetworkMonitor>,
    pub events: broadcast::Sender<SidecarEvent>,
    /// The single active capture session, if any.
    pub session: Arc<Mutex<Option<Session>>>,
    /// Where saved captures default to (chosen path overrides per-request).
    pub save_dir: PathBuf,
    /// Live monitor scope (browser-only vs whole machine), switchable at runtime.
    pub scope: crate::netmon::SharedScope,
    /// Local IP-intelligence DBs (geo + ASN) — no-network enrichment.
    pub geo: std::sync::Arc<crate::geo::Geo>,
}

struct ApiError(StatusCode, String);
impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        (self.0, Json(json!({ "error": self.1 }))).into_response()
    }
}
type ApiResult<T> = std::result::Result<T, ApiError>;

fn denied(d: &Decision) -> ApiError {
    ApiError(
        StatusCode::FORBIDDEN,
        format!("gate denied '{}': {}", d.requested_action, d.reason),
    )
}

pub fn router(state: AppState) -> Router {
    Router::new()
        .route("/health", get(|| async { Json(json!({"ok": true})) }))
        .route("/capture/status", get(status))
        .route("/capture/start", post(start))
        .route("/capture/stop", post(stop))
        .route("/capture/save", post(save))
        .route("/capture/enable", post(enable))
        .route("/map", get(map).post(map_ingest).delete(map_clear))
        .route("/scope", get(scope_get).post(scope_set))
        .route("/geo/:ip", get(geo_lookup))
        .route("/whois", post(whois))
        .route("/osint", post(osint))
        .route("/firewall", get(fw_list).post(fw_set).delete(fw_clear))
        .route("/events", get(ws_upgrade))
        // The panel (resource:// origin) fetches this loopback service cross-origin.
        // Permissive CORS is safe here: the socket is loopback-only and every
        // side effect is gated through the bridge regardless of origin.
        .layer(
            CorsLayer::new()
                .allow_origin(Any)
                .allow_methods(Any)
                .allow_headers(Any),
        )
        .with_state(state)
}

/// Bind loopback ONLY. Refuses both a non-loopback request and a non-loopback
/// actual bind (defense in depth, mirroring iot-sidecar).
pub async fn serve(addr: SocketAddr, state: AppState) -> Result<()> {
    if !addr.ip().is_loopback() {
        bail!("refusing non-loopback bind: {addr}");
    }
    let listener = tokio::net::TcpListener::bind(addr)
        .await
        .with_context(|| format!("bind {addr}"))?;
    let bound = listener.local_addr().context("local_addr")?;
    if !bound.ip().is_loopback() {
        bail!("refusing non-loopback bound addr: {bound}");
    }
    tracing::info!(%bound, "capture-sidecar listening (loopback only)");
    println!("capture-sidecar listening on http://{bound}");
    axum::serve(listener, router(state)).await.context("serve")?;
    Ok(())
}

async fn status(State(st): State<AppState>) -> Json<serde_json::Value> {
    let det = capture::detect();
    let running = st.session.lock().await.is_some();
    // `available` = an engine binary exists; `canCapture` = we can actually open
    // a BPF device (the real gate). The panel offers "Enable" when available but
    // not canCapture — the live connection map never needs either.
    Json(json!({
        "available": det.is_some(),
        "canCapture": det.is_some() && crate::bpf::can_capture(),
        "engine": det.as_ref().map(|d| d.engine.label()),
        "binary": det.as_ref().map(|d| d.binary.to_string_lossy()),
        "running": running,
        "guidance": det.is_none().then_some(
            "No capture engine found. Install Wireshark (provides dumpcap/tshark) \
             or ensure tcpdump is on PATH."
        ),
    }))
}

async fn enable(State(st): State<AppState>, Json(body): Json<GestureBody>) -> ApiResult<Response> {
    let cmd = Command {
        action: "capture-enable".into(),
        actor: body.actor,
        user_gesture: body.user_gesture,
        approval_token: body.approval_token,
        params: vec![],
    };
    let decision = gate::evaluate(&st.gate, &cmd).await;
    if !decision.permitted() {
        return Err(denied(&decision));
    }
    match crate::bpf::enable().await {
        Ok(instructions) => Ok(Json(json!({ "enabled": true, "instructions": instructions })).into_response()),
        Err(e) => Err(ApiError(StatusCode::INTERNAL_SERVER_ERROR, e)),
    }
}

#[derive(Deserialize, Default)]
struct StartBody {
    #[serde(default)]
    host: Option<String>,
    #[serde(default)]
    actor: Actor,
    #[serde(rename = "userGesture", default)]
    user_gesture: bool,
    #[serde(rename = "approvalToken", default)]
    approval_token: Option<String>,
}

async fn start(State(st): State<AppState>, Json(body): Json<StartBody>) -> ApiResult<Response> {
    let cmd = Command {
        action: "capture-start".into(),
        actor: body.actor,
        user_gesture: body.user_gesture,
        approval_token: body.approval_token,
        params: vec![],
    };
    let decision = gate::evaluate(&st.gate, &cmd).await;
    if !decision.permitted() {
        return Err(denied(&decision));
    }

    let mut slot = st.session.lock().await;
    if slot.is_some() {
        return Err(ApiError(StatusCode::CONFLICT, "capture already running".into()));
    }
    let det = capture::detect().ok_or_else(|| {
        ApiError(StatusCode::SERVICE_UNAVAILABLE, "no capture engine installed".into())
    })?;
    let pcap_path = det.engine.writes_pcap().then(|| {
        st.save_dir
            .join(format!("bearbrowser-capture-{}.pcapng", uuid::Uuid::new_v4()))
    });
    let session = Session::start(&det, body.host.as_deref(), pcap_path, st.events.clone())
        .map_err(|e| ApiError(StatusCode::INTERNAL_SERVER_ERROR, format!("spawn failed: {e}")))?;
    *slot = Some(session);
    Ok(Json(json!({ "started": true, "engine": det.engine.label(), "decision": decision })).into_response())
}

#[derive(Deserialize, Default)]
struct GestureBody {
    #[serde(default)]
    actor: Actor,
    #[serde(rename = "userGesture", default)]
    user_gesture: bool,
    #[serde(rename = "approvalToken", default)]
    approval_token: Option<String>,
    #[serde(default)]
    path: Option<String>,
}

async fn stop(State(st): State<AppState>, Json(body): Json<GestureBody>) -> ApiResult<Response> {
    let cmd = Command {
        action: "capture-stop".into(),
        actor: body.actor,
        user_gesture: body.user_gesture,
        approval_token: body.approval_token,
        params: vec![],
    };
    let decision = gate::evaluate(&st.gate, &cmd).await;
    if !decision.permitted() {
        return Err(denied(&decision));
    }
    let sess = st.session.lock().await.take();
    match sess {
        Some(s) => {
            s.stop(&st.events).await;
            Ok(Json(json!({ "stopped": true })).into_response())
        }
        None => Ok(Json(json!({ "stopped": false, "reason": "no capture running" })).into_response()),
    }
}

async fn save(State(st): State<AppState>, Json(body): Json<GestureBody>) -> ApiResult<Response> {
    let cmd = Command {
        action: "capture-export".into(),
        actor: body.actor,
        user_gesture: body.user_gesture,
        approval_token: body.approval_token,
        params: vec![],
    };
    let decision = gate::evaluate(&st.gate, &cmd).await;
    if !decision.permitted() {
        return Err(denied(&decision));
    }
    let slot = st.session.lock().await;
    let sess = slot.as_ref().ok_or_else(|| {
        ApiError(StatusCode::BAD_REQUEST, "no capture to save".into())
    })?;
    let dest = match &body.path {
        Some(p) => PathBuf::from(p),
        None => st
            .save_dir
            .join(format!("bearbrowser-capture-{}.txt", uuid::Uuid::new_v4())),
    };
    let written = sess
        .save(&dest)
        .await
        .map_err(|e| ApiError(StatusCode::INTERNAL_SERVER_ERROR, format!("save failed: {e}")))?;
    Ok(Json(json!({ "saved": written.to_string_lossy() })).into_response())
}

async fn map(State(st): State<AppState>) -> Json<serde_json::Value> {
    Json(json!({ "connections": st.monitor.snapshot() }))
}

async fn map_clear(State(st): State<AppState>) -> Json<serde_json::Value> {
    st.monitor.clear();
    Json(json!({ "cleared": true }))
}

async fn scope_get(State(st): State<AppState>) -> Json<serde_json::Value> {
    let s = *st.scope.read().unwrap();
    Json(json!({ "scope": s }))
}

#[derive(Deserialize)]
struct ScopeBody {
    scope: crate::model::Scope,
}

/// Switch the live monitor between browser-only and whole-machine. Read-ish
/// (changes only what's observed, not what's allowed) — ungated. Clears the
/// current node set so the graph repopulates cleanly under the new scope.
async fn scope_set(State(st): State<AppState>, Json(b): Json<ScopeBody>) -> Json<serde_json::Value> {
    *st.scope.write().unwrap() = b.scope;
    st.monitor.clear();
    Json(json!({ "scope": b.scope }))
}

#[derive(Deserialize)]
struct MapIngest {
    host: String,
    #[serde(rename = "pageUrl", default)]
    page_url: String,
    #[serde(rename = "resourceType", default)]
    resource_type: String,
}

/// Telemetry ingest from the trusted browser: it reports a connection it made
/// (the BearNav actor hook, mirroring the shell's WKNavigationDelegate feed).
/// Ungated — this only populates a view; enforcement is the firewall's job. The
/// `blocked` flag is derived from the current firewall rule, not client-supplied.
async fn map_ingest(State(st): State<AppState>, Json(b): Json<MapIngest>) -> Json<serde_json::Value> {
    let domain = crate::netmap::etld_plus_one(&b.host);
    let blocked = st.firewall.decision_for(&domain) == FirewallDecision::Block;
    let rec = st.monitor.record(&b.host, &b.page_url, &b.resource_type, blocked);
    let _ = st.events.send(SidecarEvent::Connection(rec));
    Json(json!({ "recorded": domain, "blocked": blocked }))
}

/// Local IP intelligence (geo + ASN/owner) for one IP. No network — answered
/// entirely from the bundled DBs, so it's an ungated read.
async fn geo_lookup(State(st): State<AppState>, Path(ip): Path<String>) -> Json<serde_json::Value> {
    Json(json!({ "ip": ip, "geo": st.geo.lookup(&ip) }))
}

#[derive(Deserialize)]
struct WhoisBody {
    ip: String,
    #[serde(default)]
    actor: Actor,
    #[serde(rename = "userGesture", default)]
    user_gesture: bool,
    #[serde(rename = "approvalToken", default)]
    approval_token: Option<String>,
}

/// External OSINT: WHOIS the IP at the authoritative registry (port 43). This
/// SENDS THE IP off-device, so it is gated — an agent can't quietly fingerprint
/// your peers; only an explicit user "Investigate" click, carrying a token,
/// permits it. Returns the parsed netblock owner / CIDR / org / allocation.
async fn whois(State(st): State<AppState>, Json(body): Json<WhoisBody>) -> ApiResult<Response> {
    let cmd = Command {
        action: "whois".into(),
        actor: body.actor,
        user_gesture: body.user_gesture,
        approval_token: body.approval_token,
        params: vec![("ip".into(), body.ip.clone())],
    };
    let decision = gate::evaluate(&st.gate, &cmd).await;
    if !decision.permitted() {
        return Err(denied(&decision));
    }
    // Basic IP sanity so we never fetch arbitrary text.
    if body.ip.parse::<std::net::IpAddr>().is_err() {
        return Err(ApiError(StatusCode::BAD_REQUEST, "not an IP address".into()));
    }
    // RDAP (the modern WHOIS replacement): structured JSON over HTTPS, one fast
    // request via rdap.org's bootstrap → the authoritative RIR. Far faster and
    // cleaner than port-43 whois (which referral-chains for 12–75s). Fetched via
    // curl so we need no TLS dep in the sidecar. The panel already shows instant
    // local geo+ASN, so a slow/failed RDAP just means less bonus detail.
    let url = format!("https://rdap.org/ip/{}", body.ip);
    let child = tokio::process::Command::new("curl")
        .args(["-sSL", "--max-time", "8", "-H", "Accept: application/rdap+json", &url])
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .kill_on_drop(true)
        .spawn()
        .map_err(|e| ApiError(StatusCode::INTERNAL_SERVER_ERROR, format!("rdap fetch failed: {e}")))?;
    match tokio::time::timeout(std::time::Duration::from_secs(10), child.wait_with_output()).await {
        Ok(Ok(out)) => {
            let text = String::from_utf8_lossy(&out.stdout);
            let rdap: serde_json::Value = serde_json::from_str(&text).unwrap_or(json!({}));
            Ok(Json(json!({ "ip": body.ip, "whois": parse_rdap(&rdap) })).into_response())
        }
        Ok(Err(e)) => Err(ApiError(StatusCode::INTERNAL_SERVER_ERROR, format!("rdap failed: {e}"))),
        Err(_) => Ok(Json(json!({
            "ip": body.ip, "timedOut": true, "whois": {},
            "note": "registry lookup timed out — local geo + ASN shown above"
        })).into_response()),
    }
}

/// Pull the OSINT-relevant fields out of an RDAP IP-network record (RFC 9083).
/// Uniform across all RIRs, so no per-registry heuristics.
fn parse_rdap(v: &serde_json::Value) -> serde_json::Value {
    let s = |x: &serde_json::Value| x.as_str().map(|s| s.to_string());
    // CIDR from cidr0_cidrs, else the start–end range.
    let cidr = v["cidr0_cidrs"].as_array().and_then(|a| a.first()).map(|c| {
        let pfx = c["v4prefix"].as_str().or_else(|| c["v6prefix"].as_str()).unwrap_or("");
        format!("{}/{}", pfx, c["length"].as_u64().unwrap_or(0))
    });
    let range = match (s(&v["startAddress"]), s(&v["endAddress"])) {
        (Some(a), Some(b)) => Some(format!("{a} – {b}")),
        _ => None,
    };
    // Registrant org: first entity carrying a "registrant" role, its vCard "fn".
    let mut owner_org = None;
    if let Some(entities) = v["entities"].as_array() {
        for e in entities {
            let is_reg = e["roles"].as_array().map(|r| r.iter().any(|x| x == "registrant")).unwrap_or(false);
            if is_reg {
                if let Some(vc) = e["vcardArray"].as_array().and_then(|a| a.get(1)).and_then(|x| x.as_array()) {
                    for item in vc {
                        if let Some(arr) = item.as_array() {
                            if arr.first().and_then(|x| x.as_str()) == Some("fn") {
                                owner_org = arr.get(3).and_then(|x| x.as_str()).map(|s| s.to_string());
                            }
                        }
                    }
                }
            }
        }
    }
    // Registration + last-changed from the events array.
    let event = |action: &str| -> Option<String> {
        v["events"].as_array().and_then(|a| {
            a.iter().find(|e| e["eventAction"] == action)
                .and_then(|e| e["eventDate"].as_str())
                .map(|d| d.split('T').next().unwrap_or(d).to_string())
        })
    };
    json!({
        "owner": owner_org.or_else(|| s(&v["name"])),
        "netName": s(&v["name"]),
        "netRange": cidr.or(range),
        "type": s(&v["type"]),
        "country": s(&v["country"]),
        "handle": s(&v["handle"]),
        "registered": event("registration"),
        "updated": event("last changed"),
    })
}

#[derive(Deserialize)]
struct OsintBody {
    ip: String,
    #[serde(default)]
    domain: String,
    #[serde(default)]
    actor: Actor,
    #[serde(rename = "userGesture", default)]
    user_gesture: bool,
    #[serde(rename = "approvalToken", default)]
    approval_token: Option<String>,
}

/// Deep OSINT — fans out to several free external sources (Shodan InternetDB,
/// reverse-IP, cert transparency, RDAP). SENDS the IP/domain to third parties,
/// so it is prohibited for agents and gated on an explicit user gesture.
async fn osint(State(st): State<AppState>, Json(body): Json<OsintBody>) -> ApiResult<Response> {
    let cmd = Command {
        action: "osint".into(),
        actor: body.actor,
        user_gesture: body.user_gesture,
        approval_token: body.approval_token,
        params: vec![("ip".into(), body.ip.clone())],
    };
    let decision = gate::evaluate(&st.gate, &cmd).await;
    if !decision.permitted() {
        return Err(denied(&decision));
    }
    if body.ip.parse::<std::net::IpAddr>().is_err() {
        return Err(ApiError(StatusCode::BAD_REQUEST, "not an IP address".into()));
    }
    Ok(Json(crate::osint::investigate(&body.ip, &body.domain).await).into_response())
}

async fn fw_list(State(st): State<AppState>) -> Json<serde_json::Value> {
    Json(json!({ "rules": st.firewall.all() }))
}

/// Reset all firewall rules to default (Ask). Read-ish maintenance, ungated.
async fn fw_clear(State(st): State<AppState>) -> Json<serde_json::Value> {
    st.firewall.clear();
    Json(json!({ "cleared": true }))
}

#[derive(Deserialize)]
struct FwSetBody {
    domain: String,
    decision: FirewallDecision,
    #[serde(default)]
    actor: Actor,
    #[serde(rename = "userGesture", default)]
    user_gesture: bool,
    #[serde(rename = "approvalToken", default)]
    approval_token: Option<String>,
}

async fn fw_set(State(st): State<AppState>, Json(body): Json<FwSetBody>) -> ApiResult<Response> {
    // Normalize to eTLD+1 — the whole subsystem (map classifier, blocked-check)
    // operates at that granularity, so a rule on "ads.evil.com" must key on
    // "evil.com" or it would never match an observed connection. Matches the
    // native shell, which set + checked firewall rules via etldForHost:.
    let domain = crate::netmap::etld_plus_one(&body.domain);
    let cmd = Command {
        action: "firewall-set".into(),
        actor: body.actor,
        user_gesture: body.user_gesture,
        approval_token: body.approval_token,
        params: vec![
            ("domain".into(), domain.clone()),
            ("decision".into(), format!("{:?}", body.decision).to_lowercase()),
        ],
    };
    let decision = gate::evaluate(&st.gate, &cmd).await;
    if !decision.permitted() {
        return Err(denied(&decision));
    }
    st.firewall.set(&domain, body.decision);
    Ok(Json(json!({ "set": domain, "decision": body.decision })).into_response())
}

async fn ws_upgrade(State(st): State<AppState>, ws: WebSocketUpgrade) -> Response {
    ws.on_upgrade(move |socket| ws_loop(socket, st.events.subscribe()))
}

async fn ws_loop(mut socket: WebSocket, mut rx: broadcast::Receiver<SidecarEvent>) {
    loop {
        tokio::select! {
            ev = rx.recv() => match ev {
                Ok(ev) => {
                    let txt = match serde_json::to_string(&ev) {
                        Ok(t) => t,
                        Err(_) => continue,
                    };
                    if socket.send(Message::Text(txt)).await.is_err() {
                        break; // client gone
                    }
                }
                Err(broadcast::error::RecvError::Lagged(_)) => continue,
                Err(broadcast::error::RecvError::Closed) => break,
            },
            incoming = socket.recv() => match incoming {
                Some(Ok(Message::Close(_))) | None => break,
                Some(Ok(_)) => {}   // ignore client chatter; this is a push channel
                Some(Err(_)) => break,
            },
        }
    }
}
