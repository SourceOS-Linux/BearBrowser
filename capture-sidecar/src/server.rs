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
use axum::extract::State;
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
        .route("/map", get(map).post(map_ingest).delete(map_clear))
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
    Json(json!({
        "available": det.is_some(),
        "engine": det.as_ref().map(|d| d.engine.label()),
        "binary": det.as_ref().map(|d| d.binary.to_string_lossy()),
        "running": running,
        "guidance": det.is_none().then_some(
            "No capture engine found. Install Wireshark (provides dumpcap/tshark) \
             or ensure tcpdump is on PATH. On macOS you may also need read access \
             to /dev/bpf* (add yourself to the access_bpf group). On Linux, grant \
             dumpcap CAP_NET_RAW or run via the wireshark group."
        ),
    }))
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
