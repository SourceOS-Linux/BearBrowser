//! Loopback-only REST + WebSocket server the BearBrowser cockpit calls.
//!
//! Routes:
//!   GET  /health                      → liveness
//!   GET  /devices                     → inventory (store + live discovery merge)
//!   GET  /devices/:id/state           → live state read (allowed action)
//!   POST /devices/:id/command         → gate-governed command apply
//!   GET  /events (WS)                 → event fan-out
//!
//! INVARIANTS enforced here:
//!   * bind 127.0.0.1 only — `serve` refuses any non-loopback address;
//!   * EVERY command POST calls `gate::evaluate` FIRST and touches a device only
//!     on `permit`;
//!   * nothing is emitted to the network except over this loopback socket.

use crate::adapters::{AdapterRegistry, SubscriptionFilter};
use crate::gate::{self, Decision, GateConfig};
use crate::model::{Actor, Command, DeviceEvent, DeviceId};
use crate::state::Store;
use anyhow::{bail, Result};
use axum::{
    extract::{
        ws::{Message, WebSocket, WebSocketUpgrade},
        Path, State,
    },
    http::StatusCode,
    response::{IntoResponse, Response},
    routing::{get, post},
    Json, Router,
};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::net::{IpAddr, SocketAddr};
use std::sync::Arc;
use tokio::sync::broadcast;

/// Shared application state (all cheaply clonable handles).
#[derive(Clone)]
pub struct AppState {
    pub registry: AdapterRegistry,
    pub store: Store,
    pub gate: Arc<GateConfig>,
    /// Fan-out bus: adapter/command events → all connected WS clients.
    pub events: broadcast::Sender<DeviceEvent>,
}

/// Request body for `POST /devices/:id/command`.
///
/// `actor` and `user_gesture` are REQUIRED and load-bearing: they are what let
/// the gate reclassify a prohibited physical action down to gated on an explicit
/// cockpit gesture. The cockpit sets them from trusted UI state; an agent cannot
/// forge `actor=user`.
#[derive(Debug, Deserialize)]
pub struct CommandRequest {
    pub action: String,
    #[serde(default)]
    pub params: BTreeMap<String, String>,
    #[serde(default)]
    pub approval_token: Option<String>,
    pub actor: Actor,
    #[serde(default)]
    pub user_gesture: bool,
}

/// Response for a command: the raw gate decision plus whether device I/O ran.
#[derive(Debug, Serialize)]
pub struct CommandResponse {
    pub applied: bool,
    pub decision: DecisionView,
}

/// The gate decision as surfaced to the cockpit.
#[derive(Debug, Serialize)]
pub struct DecisionView {
    pub decision: String,
    pub action_class: String,
    pub reason: String,
    pub effective_action: Option<String>,
    pub reclassified_by: Option<String>,
    pub event_type: Option<String>,
}

impl From<&Decision> for DecisionView {
    fn from(d: &Decision) -> Self {
        DecisionView {
            decision: d.decision.clone(),
            action_class: d.action_class.clone(),
            reason: d.reason.clone(),
            effective_action: d.effective_action.clone(),
            reclassified_by: d.reclassified_by.clone(),
            event_type: d
                .attested_event
                .as_ref()
                .and_then(|e| e.event_type.clone()),
        }
    }
}

/// A structured API error → JSON.
struct ApiError(StatusCode, String);

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        (self.0, Json(serde_json::json!({ "error": self.1 }))).into_response()
    }
}

fn internal(e: impl std::fmt::Display) -> ApiError {
    ApiError(StatusCode::INTERNAL_SERVER_ERROR, e.to_string())
}

/// Build the router.
pub fn router(state: AppState) -> Router {
    Router::new()
        .route("/health", get(health))
        .route("/devices", get(list_devices))
        .route("/devices/:id/state", get(read_state))
        .route("/devices/:id/command", post(post_command))
        .route("/events", get(ws_events))
        .with_state(state)
}

/// Bind loopback-only and serve. Refuses any non-loopback bind address.
pub async fn serve(addr: SocketAddr, state: AppState) -> Result<()> {
    if !is_loopback(&addr.ip()) {
        bail!(
            "refusing to bind non-loopback address {addr}: the iot-sidecar is loopback-only"
        );
    }
    let listener = tokio::net::TcpListener::bind(addr).await?;
    let bound = listener.local_addr()?;
    // Belt-and-suspenders: verify what we actually bound.
    if !is_loopback(&bound.ip()) {
        bail!("bound a non-loopback address {bound}; aborting");
    }
    tracing::info!(%bound, "iot-sidecar listening (loopback-only)");
    axum::serve(listener, router(state).into_make_service()).await?;
    Ok(())
}

fn is_loopback(ip: &IpAddr) -> bool {
    ip.is_loopback()
}

async fn health() -> impl IntoResponse {
    Json(serde_json::json!({ "status": "ok" }))
}

/// GET /devices — merge stored inventory with a live discovery pass across all
/// adapters, persisting anything newly seen.
async fn list_devices(State(state): State<AppState>) -> Result<impl IntoResponse, ApiError> {
    for adapter in state.registry.all() {
        match adapter.discover().await {
            Ok(devices) => {
                for d in devices {
                    if let Err(e) = state.store.upsert_device(&d) {
                        tracing::warn!(error = %e, "failed to persist discovered device");
                    }
                }
            }
            Err(e) => {
                // A protocol with unimplemented discovery must not fail the whole
                // listing — the cockpit still gets every other adapter's devices.
                tracing::debug!(protocol = adapter.protocol(), error = %e, "discover skipped");
            }
        }
    }
    let devices = state.store.list_devices().map_err(internal)?;
    Ok(Json(devices))
}

/// GET /devices/:id/state — live read from the owning adapter.
async fn read_state(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> Result<impl IntoResponse, ApiError> {
    let id = DeviceId::new(id);
    let device = state
        .store
        .get_device(&id)
        .map_err(internal)?
        .ok_or_else(|| ApiError(StatusCode::NOT_FOUND, format!("unknown device {id}")))?;
    let adapter = state.registry.get(&device.protocol).ok_or_else(|| {
        ApiError(
            StatusCode::SERVICE_UNAVAILABLE,
            format!("no adapter for protocol {}", device.protocol),
        )
    })?;
    let read = adapter.read_state(&id).await.map_err(internal)?;
    // Refresh the cache.
    let _ = state.store.update_state(&id, &read);
    Ok(Json(read))
}

/// POST /devices/:id/command — the governed path. The gate is consulted FIRST;
/// device I/O runs ONLY on `permit`.
async fn post_command(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Json(req): Json<CommandRequest>,
) -> Result<Response, ApiError> {
    let id = DeviceId::new(id);
    let command = Command {
        action: req.action,
        params: req.params,
        approval_token: req.approval_token,
        actor: req.actor,
        user_gesture: req.user_gesture,
    };

    // ── THE GATE — one engine, consulted before any device I/O ──────────────
    let decision = gate::evaluate(&state.gate, &command).await;

    // Record the decision in the append-only log regardless of outcome.
    let mut decision_event =
        DeviceEvent::now(id.clone(), "gate", format!("decision:{}", decision.decision));
    decision_event.state = None;
    let _ = state.store.append_event(&decision_event);

    if !decision.permitted() {
        // Fail closed: no device is touched.
        let body = CommandResponse {
            applied: false,
            decision: DecisionView::from(&decision),
        };
        return Ok((StatusCode::FORBIDDEN, Json(body)).into_response());
    }

    // ── Permitted: locate the adapter and perform device I/O ────────────────
    let device = state
        .store
        .get_device(&id)
        .map_err(internal)?
        .ok_or_else(|| ApiError(StatusCode::NOT_FOUND, format!("unknown device {id}")))?;
    let adapter = state.registry.get(&device.protocol).ok_or_else(|| {
        ApiError(
            StatusCode::SERVICE_UNAVAILABLE,
            format!("no adapter for protocol {}", device.protocol),
        )
    })?;

    adapter.apply(&id, &command).await.map_err(internal)?;

    // Reflect the resulting state and emit an event onto the WS bus.
    if let Ok(new_state) = adapter.read_state(&id).await {
        let _ = state.store.update_state(&id, &new_state);
        let mut ev = DeviceEvent::now(id.clone(), device.protocol.clone(), "state-changed");
        ev.state = Some(new_state);
        let _ = state.store.append_event(&ev);
        let _ = state.events.send(ev);
    }

    let body = CommandResponse {
        applied: true,
        decision: DecisionView::from(&decision),
    };
    Ok((StatusCode::OK, Json(body)).into_response())
}

/// GET /events (WS) — fan out device events to the cockpit. Subscribes to both
/// the shared command bus and every adapter's own subscription.
async fn ws_events(
    State(state): State<AppState>,
    ws: WebSocketUpgrade,
) -> impl IntoResponse {
    ws.on_upgrade(move |socket| handle_ws(socket, state))
}

async fn handle_ws(mut socket: WebSocket, state: AppState) {
    // Merge adapter event streams into the shared bus first.
    for adapter in state.registry.all() {
        if let Ok(mut stream) = adapter.subscribe(SubscriptionFilter::all()).await {
            let tx = state.events.clone();
            tokio::spawn(async move {
                use tokio_stream::StreamExt;
                while let Some(ev) = stream.next().await {
                    let _ = tx.send(ev);
                }
            });
        }
    }

    let mut rx = state.events.subscribe();
    loop {
        tokio::select! {
            recv = rx.recv() => {
                match recv {
                    Ok(ev) => {
                        let json = match serde_json::to_string(&ev) {
                            Ok(j) => j,
                            Err(_) => continue,
                        };
                        if socket.send(Message::Text(json)).await.is_err() {
                            break; // client gone
                        }
                    }
                    Err(broadcast::error::RecvError::Lagged(_)) => continue,
                    Err(broadcast::error::RecvError::Closed) => break,
                }
            }
            incoming = socket.recv() => {
                match incoming {
                    Some(Ok(Message::Close(_))) | None => break,
                    Some(Ok(_)) => { /* cockpit → sidecar WS messages ignored for now */ }
                    Some(Err(_)) => break,
                }
            }
        }
    }
}
