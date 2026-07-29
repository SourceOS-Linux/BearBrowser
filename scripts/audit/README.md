# BearBrowser attack-surface audit

Measures what a **real website** can reach — content scope, not the privileged
chrome scope the Browser Console shows (`ChromeUtils`, `Services`, `Cc/Ci` are
chrome-only and NOT visible to pages; don't confuse the two).

    node scripts/audit/surface-audit-server.mjs &
    open -n /Applications/BearBrowser.app --args -no-remote \
      -profile /tmp/bb-audit "http://127.0.0.1:8099/"

Writes `surface-report.json`. Diff two reports to prove a pref actually closed a
surface — never assume a pref works, measure it.

## Measured 2026-07-29 (v150.0.1)
Closed by this pass (verified true -> false in the report):
WebGPU, WebMIDI, SpeechSynthesis, Notification, PushManager; GPC on; DNT on.
Confirmed already working: RFP timezone spoof (Atlantic/Reykjavik), timer
quantization, canvas randomization (hash differs per session), WebGL context
null, Battery/Gamepad/Bluetooth/USB/Serial/HID/NFC/IdleDetector/NetworkInformation
absent, PrivateAttribution + Glean NOT exposed to content.

## 🔴 Open, measured leaks
- `navigator.hardwareConcurrency` returns the REAL core count (8).
  `dom.maxHardwareConcurrency=2` did NOT take effect — suspect our
  `anti-fp-*.patch` / `RFPTargets.inc` disabled the HardwareConcurrency RFP
  target. Needs a source-level fix, not a pref.
- `navigator.plugins`=5 / `mimeTypes`=2 (non-zero = entropy).
- `mediaDevices.enumerateDevices` still callable (device-set fingerprint).
- WebRTC `RTCPeerConnection` still exposed (kept on purpose: disabling breaks
  video calls; `media.peerconnection.ice.no_host` is set). Decide explicitly.
