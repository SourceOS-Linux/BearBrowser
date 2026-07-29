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
- `navigator.hardwareConcurrency` returned the REAL core count (8). Ruled out by
  measurement: `dom.maxHardwareConcurrency=2` (no effect) and
  `privacy.fingerprintingProtection=true` (no effect); RFP *was* active on the
  same page (timezone + timer spoofing both confirmed). Our anti-fp patches were
  also cleared — they ADD RFP targets (WebAudioFarble, CanvasTextMetrics), they
  do not remove HardwareConcurrency. **Now clamped to 2 in BearTrapChild's
  existing getter interception** (rides `bearbrowser.honeypot.enabled`) —
  ⚠️ NOT yet verified in a build; re-run this audit after the next build.
- `mediaDevices.enumerateDevices` still callable (device-set fingerprint).

## Corrected — NOT a leak
- `navigator.plugins`=5 / `mimeTypes`=2 looked like entropy but is not: modern
  Firefox reports a FIXED, identical PDF-viewer set for every user. Uniform
  values are anti-fingerprinting; zeroing them would make us MORE unique.
- WebRTC `RTCPeerConnection` still exposed (kept on purpose: disabling breaks
  video calls; `media.peerconnection.ice.no_host` is set). Decide explicitly.
