#!/usr/bin/env python3
"""
BearBrowser WebDriver-BiDi transport — the live wire UNDER the enforcement gate.
================================================================================
A minimal WebDriver-BiDi WebSocket client that lets the agent-control-bridge
drive a real BearBrowser binary. It is deliberately dumb: it knows how to open a
loopback WebSocket, authenticate with a per-session token, complete the BiDi
`session.new` handshake, and send `{id, method, params}` command frames reading
back `{id, result}` / `{id, error}`.

It knows NOTHING about policy. Policy lives entirely in
`agent-control-bridge.py::ControlBridge.evaluate_action`, which runs BEFORE any
method here is ever called. This module cannot originate an action — the bridge
gates first, then (only on permit) asks this transport to emit the mapped BiDi
command. A denied action never reaches a `send_command` call, so no frame is
ever put on the wire for it.

Transport tiers (graceful degradation):

  1. `websocket-client` (the `websocket` module) if installed — used for the live
     wire. This is the ONLY optional dependency and it is behind a guarded import.
  2. A pure-stdlib RFC 6455 client (raw socket + hand-rolled framing) as the
     fallback, so a live loopback browser can still be driven with zero deps.
  3. Enforce-only / headless: no transport at all. The bridge still evaluates and
     attests every action; it simply never constructs a BidiClient. This path has
     NO dependency and needs NO browser, so containment is provable anywhere.

Loopback is mandatory: a non-loopback `bidi_url` is refused before any socket is
opened (the control endpoint is loopback-only per the contract).
"""
from __future__ import annotations

import base64
import json
import os
import socket
import struct
from typing import Any, Optional
from urllib.parse import urlparse

LOOPBACK_HOSTS = ("127.0.0.1", "localhost", "::1")

# Optional live-transport dependency, behind a guarded import. Absence is fine:
# enforce-only mode never needs it and the stdlib client covers the live path.
try:  # pragma: no cover - import presence is environment-dependent
    import websocket as _ws_client  # type: ignore
    HAVE_WS_CLIENT = True
except Exception:  # pragma: no cover
    _ws_client = None  # type: ignore
    HAVE_WS_CLIENT = False


class BidiError(RuntimeError):
    """A BiDi command returned an {id, error} frame, or the transport failed."""


def parse_loopback(url: str) -> tuple[Optional[str], int, str]:
    """Return (host, port, path) for a ws URL, or (None, 0, "") if unparseable.

    The caller is responsible for enforcing loopback; this only parses.
    """
    try:
        u = urlparse(url if "://" in url else f"ws://{url}")
        host = u.hostname or None
        port = u.port or (443 if (u.scheme or "").endswith("s") else 80)
        path = u.path or "/session"
        return host, port, path
    except Exception:
        return None, 0, ""


def is_loopback(host: Optional[str]) -> bool:
    return host in LOOPBACK_HOSTS


# ---------------------------------------------------------------------------
# Pure-stdlib RFC 6455 WebSocket client (fallback — no third-party dep).
# Text frames only, client-masked, single-frame messages. Enough for BiDi's
# newline-free JSON command/response envelopes on a trusted loopback socket.
# ---------------------------------------------------------------------------

class _StdlibWebSocket:
    def __init__(self, host: str, port: int, path: str, timeout: float):
        self._sock = socket.create_connection((host, port), timeout=timeout)
        self._sock.settimeout(timeout)
        self._buf = b""
        self._handshake(host, port, path)

    def _handshake(self, host: str, port: int, path: str) -> None:
        key = base64.b64encode(os.urandom(16)).decode("ascii")
        req = (
            f"GET {path} HTTP/1.1\r\n"
            f"Host: {host}:{port}\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\n"
            "Sec-WebSocket-Version: 13\r\n"
            "\r\n"
        )
        self._sock.sendall(req.encode("ascii"))
        # read until end of headers
        data = b""
        while b"\r\n\r\n" not in data:
            chunk = self._sock.recv(4096)
            if not chunk:
                raise BidiError("websocket handshake: connection closed")
            data += chunk
        status_line = data.split(b"\r\n", 1)[0]
        if b"101" not in status_line:
            raise BidiError(f"websocket handshake failed: {status_line!r}")
        # any bytes after the header terminator belong to the frame stream
        self._buf = data.split(b"\r\n\r\n", 1)[1]

    def send(self, text: str) -> None:
        payload = text.encode("utf-8")
        header = bytearray()
        header.append(0x81)  # FIN + text opcode
        mask_bit = 0x80
        length = len(payload)
        if length < 126:
            header.append(mask_bit | length)
        elif length < (1 << 16):
            header.append(mask_bit | 126)
            header.extend(struct.pack(">H", length))
        else:
            header.append(mask_bit | 127)
            header.extend(struct.pack(">Q", length))
        mask = os.urandom(4)
        header.extend(mask)
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        self._sock.sendall(bytes(header) + masked)

    def _recv_into_buf(self) -> None:
        chunk = self._sock.recv(4096)
        if not chunk:
            raise BidiError("websocket: connection closed while reading")
        self._buf += chunk

    def _read_exact(self, n: int) -> bytes:
        while len(self._buf) < n:
            self._recv_into_buf()
        out, self._buf = self._buf[:n], self._buf[n:]
        return out

    def recv(self) -> str:
        while True:
            first2 = self._read_exact(2)
            b0, b1 = first2[0], first2[1]
            opcode = b0 & 0x0F
            masked = (b1 & 0x80) != 0
            length = b1 & 0x7F
            if length == 126:
                length = struct.unpack(">H", self._read_exact(2))[0]
            elif length == 127:
                length = struct.unpack(">Q", self._read_exact(8))[0]
            mask = self._read_exact(4) if masked else b""
            payload = self._read_exact(length)
            if masked:
                payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
            if opcode == 0x8:  # close
                raise BidiError("websocket: server sent close frame")
            if opcode in (0x9, 0xA):  # ping/pong control frames — ignore
                continue
            return payload.decode("utf-8", errors="replace")

    def close(self) -> None:
        try:
            # client-masked close frame
            self._sock.sendall(b"\x88\x80" + os.urandom(4))
        except Exception:
            pass
        try:
            self._sock.close()
        except Exception:
            pass


# ---------------------------------------------------------------------------
# BiDi client — loopback + token, session.new handshake, send_command.
# ---------------------------------------------------------------------------

class BidiClient:
    """A connected WebDriver-BiDi client. Constructing it opens the socket and
    completes `session.new`. Refuses non-loopback endpoints before connecting.

    This class NEVER decides whether an action is allowed. It is only ever
    reached after ControlBridge.evaluate_action returns permit.
    """

    def __init__(self, bidi_url: str, token: str, timeout: float = 0.5):
        host, port, path = parse_loopback(bidi_url)
        if host is None:
            raise BidiError(f"unparseable bidi_url: {bidi_url!r}")
        if not is_loopback(host):
            # loopback-only control endpoint — refuse before opening a socket
            raise BidiError(
                f"refused non-loopback bidi control endpoint: {host!r} "
                "(control endpoint must be 127.0.0.1/localhost/::1)"
            )
        self.host, self.port, self.path = host, port, path
        self.token = token
        self.timeout = timeout
        self._id = 0
        self.session_id: Optional[str] = None
        self._ws = self._open_ws()
        self._handshake_session()

    # -- transport selection: prefer the dep, fall back to stdlib --
    def _open_ws(self) -> Any:
        url = f"ws://{self.host}:{self.port}{self.path}"
        header = [f"Authorization: Bearer {self.token}"] if self.token else []
        if HAVE_WS_CLIENT:
            try:
                ws = _ws_client.create_connection(  # type: ignore[union-attr]
                    url, timeout=self.timeout, header=header,
                )
                return ws
            except Exception as exc:  # fall through to stdlib
                raise BidiError(f"websocket-client connect failed: {exc}") from exc
        # stdlib fallback: token is carried in session.new params below since the
        # hand-rolled handshake does not add arbitrary headers by default.
        return _StdlibWebSocket(self.host, self.port, self.path, self.timeout)

    def _next_id(self) -> int:
        self._id += 1
        return self._id

    def _raw_send(self, obj: dict[str, Any]) -> None:
        self._ws.send(json.dumps(obj))

    def _raw_recv(self) -> dict[str, Any]:
        raw = self._ws.recv()
        if isinstance(raw, (bytes, bytearray)):
            raw = raw.decode("utf-8", errors="replace")
        return json.loads(raw)

    def send_command(self, method: str, params: Optional[dict[str, Any]] = None) -> dict[str, Any]:
        """Send one BiDi command and return its `result` (or raise on `error`).

        Skips async event frames (those without a matching `id`) until the
        response to this command arrives.
        """
        cmd_id = self._next_id()
        frame: dict[str, Any] = {"id": cmd_id, "method": method, "params": params or {}}
        # Carry the session token in-band too, so a stdlib socket (no auth header)
        # still authenticates. A live browser ignores unknown top-level keys.
        if self.token:
            frame["sessionToken"] = self.token
        self._raw_send(frame)
        while True:
            msg = self._raw_recv()
            if msg.get("id") != cmd_id:
                # BiDi event push (no id) or an unrelated response — skip.
                continue
            if "error" in msg:
                raise BidiError(f"{method}: {msg.get('error')}: {msg.get('message', '')}")
            return msg.get("result", {})

    def _handshake_session(self) -> None:
        result = self.send_command("session.new", {"capabilities": {}})
        self.session_id = (result or {}).get("sessionId")

    def close(self) -> None:
        try:
            self.send_command("session.end", {})
        except Exception:
            pass
        try:
            self._ws.close()
        except Exception:
            pass


# ---------------------------------------------------------------------------
# Action → BiDi command map. Pure data + a builder; NO policy here.
# Only actions that are permitted ever reach build_bidi_command; gated/
# prohibited actions map to None (never a command) as a defense-in-depth
# backstop even if this were somehow called without the gate.
# ---------------------------------------------------------------------------

# actions that, even if reached, must NEVER produce a BiDi command.
_NEVER_A_COMMAND = frozenset({
    "enter-credentials", "enter-payment-details", "enter-government-id",
    "modify-access-controls", "bypass-captcha", "execute-trade-or-transfer",
    "submit-form", "file-download", "oauth-grant", "payment-autofill",
    "cross-origin-post", "clipboard-write", "geolocation", "camera-mic",
})


def build_bidi_command(action: str, params: dict[str, Any],
                       context: Optional[str] = None) -> Optional[tuple[str, dict[str, Any]]]:
    """Map a PERMITTED action to a (method, params) BiDi command, or None.

    None means "no BiDi command for this action" — used for gated/prohibited
    actions as a backstop. The caller (dispatch) must ALREADY have gated; this
    map does not grant anything, it only translates already-permitted intent.
    """
    params = params or {}
    ctx = context or params.get("context") or "default-context"

    if action in _NEVER_A_COMMAND:
        return None

    if action == "navigate":
        url = params.get("url", "")
        return "browsingContext.navigate", {"context": ctx, "url": url, "wait": "complete"}

    if action in ("read-dom", "extract-text", "query-selector"):
        selector = params.get("selector", "")
        expr = {
            "read-dom": "document.documentElement.outerHTML",
            "extract-text": f"document.querySelector({json.dumps(selector)})?.textContent ?? ''"
                            if selector else "document.body.innerText",
            "query-selector": f"!!document.querySelector({json.dumps(selector)})"
                              if selector else "false",
        }[action]
        return "script.evaluate", {
            "expression": expr,
            "target": {"context": ctx},
            "awaitPromise": True,
            "resultOwnership": "none",
        }

    if action == "scroll":
        dy = params.get("deltaY", params.get("dy", 600))
        dx = params.get("deltaX", params.get("dx", 0))
        return "script.evaluate", {
            "expression": f"window.scrollBy({int(dx)}, {int(dy)})",
            "target": {"context": ctx},
            "awaitPromise": True,
            "resultOwnership": "none",
        }

    if action == "wait":
        ms = int(params.get("ms", params.get("timeout", 500)))
        return "script.evaluate", {
            "expression": f"new Promise(r=>setTimeout(r,{ms}))",
            "target": {"context": ctx},
            "awaitPromise": True,
            "resultOwnership": "none",
        }

    if action == "click":
        x = int(params.get("x", 0))
        y = int(params.get("y", 0))
        return "input.performActions", {
            "context": ctx,
            "actions": [{
                "type": "pointer",
                "id": "mouse",
                "parameters": {"pointerType": "mouse"},
                "actions": [
                    {"type": "pointerMove", "x": x, "y": y},
                    {"type": "pointerDown", "button": 0},
                    {"type": "pointerUp", "button": 0},
                ],
            }],
        }

    if action == "fill-form-field":
        # only reaches here for the ALLOWED (non-credential/payment/gov-id) shape;
        # credential/payment/gov-id fills are reclassified to prohibited upstream.
        text = params.get("value", "")
        return "input.performActions", {
            "context": ctx,
            "actions": [{
                "type": "key",
                "id": "keyboard",
                "actions": [{"type": "keyDown", "value": c} for c in text]
                           + [{"type": "keyUp", "value": c} for c in text],
            }],
        }

    if action == "screenshot":
        return "browsingContext.captureScreenshot", {"context": ctx}

    # unknown/unmapped action → no command (fail-closed at the transport map too)
    return None


def summarize_result(action: str, result: Any) -> str:
    """A SAFE one-line trace summary of a BiDi result — never raw page content.

    We record shape/keys and small scalars only, never DOM text, screenshots, or
    field values.
    """
    if result is None:
        return f"{action}: no result"
    if isinstance(result, dict):
        keys = ",".join(sorted(result.keys())[:6])
        if action == "browsingContext.navigate" or action == "navigate":
            return f"navigate ok (result keys: {keys})"
        if action == "browsingContext.captureScreenshot" or action == "screenshot":
            data = result.get("data")
            n = len(data) if isinstance(data, str) else 0
            return f"screenshot captured ({n} b64 bytes, not stored in trace)"
        return f"{action} ok (result keys: {keys})"
    if isinstance(result, (int, float, bool)):
        return f"{action} ok (result={result})"
    if isinstance(result, str):
        return f"{action} ok (result: {len(result)} chars, not stored in trace)"
    return f"{action} ok"
