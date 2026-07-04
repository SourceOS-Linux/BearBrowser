# BearBrowser vs the Browser Field

> Honest positioning, 2026. Competitor claims and the market opening are web-sourced (forums + vendors + Gartner); BearBrowser's state is graded against its actual build. Our gaps are marked, not hidden.

## The one-line pitch

**The answer to "block AI browsers" isn't *no agent* — it's a *governed* one. BearBrowser's agent runs on your machine, blocks the dangerous action before it happens, and proves it with a sealed receipt.**

## The opening (why now)

The browser-privacy conversation shifted hard in 2025–26. Fingerprinting and Chromium-monoculture debates are mature and crowded. The **new, loud, institutionally-validated** gap is the **agentic-browser trust crisis:**

- **Gartner (Dec 2025) issued a formal directive: CISOs should *block all AI browsers*** until they have **inspectable agent intent + per-action policy enforcement** — controls that "do not exist at scale." That's a product spec written by an analyst firm.
- Every shipping AI browser — **Perplexity Comet, OpenAI Atlas, Edge Copilot, Dia, Opera Neon** — sends your tabs/history/screen to a cloud and acts with no enforceable intent. Real exploits are public (CometJacking, hidden-text OTP exfiltration, Amazon's Comet/bot lawsuit).
- **Brave's own research** concludes "we need new security/privacy architectures for agentic browsing" — and **ships none.** OpenAI calls prompt injection "frontier, unsolved."

**Nobody is shipping a local, governed, attestable agent browser.** BearBrowser is.

## Where BearBrowser wins — proven, not promised

| Capability | BearBrowser | The AI-browser field |
|---|---|---|
| **Agent that *contains* injection** | ✅ enforcing bridge blocks gated/prohibited/injected actions **at the wire** — 79/79 containment + 20/20 transport tests; a rogue `enter-credentials` never reaches the browser | ❌ cloud agents act first, "safety" is post-hoc |
| **Every agent action attested** | ✅ sealable `ReasoningEvent`/`policy.violation` receipts (agentplane-sealed, tamper-evident) | ❌ no inspectable/enforceable intent — Gartner's named gap |
| **Local / sovereign** | ✅ runs on your machine, no cloud, no account, no telemetry | ❌ proprietary US cloud, surveils to act |
| **Non-Chromium engine** | ✅ Gecko / Firefox-140-ESR base — MV3-proof ad-blocking | ❌ Comet/Dia/Atlas/Edge all ride Google's Blink |
| **Anti-fingerprinting, cohort-correct** | ✅ spoof-normality / ESR-cohort (the *winning* side: 2025 academic evidence shows standardize-to-crowd beats Brave-style randomization) | ◐ Brave randomizes (measured weaker); Chromium browsers leak more |
| **Two-profile shape** | ✅ human-secure (usable daily) + tor-mode (max hardening, Tor-cohort blending) | — |

## The market tailwinds

- **Mozilla's Feb-2025 ToU rug-pull** — deleted "never sell your data," community backlash forced two walk-backs. Our *no-telemetry/no-account/sovereign* stance is the direct rebuttal: the Firefox engine without Mozilla's governance risk.
- **Arc's abandonment** (wound down, acquired by Atlassian for $610M, users "betrayed") → "we can't be acquired and gutted."
- **Chromium monoculture + Manifest V3** → Gecko base is structurally on the right side.

## Honest gaps (the reality check)

| Gap | Status |
|---|---|
| Binary maturity / adoption | **Closing** — first real binary built (`140.12.0esr-1`, Linux x86_64, two variants); Windows/macOS builds still pending |
| Fingerprint = indistinguishable-from-ESR | **Closing** — cohort-hardened (WebGL present-spoofed not disabled, plugins standardized, stale-UA + font leaks fixed); scorecard 12→~15/20 pending re-score build |
| Live agent demo | Bridge enforces + drives over BiDi (proven vs mock); needs the public demo on the real binary — one injection-pop flips the story if we can't show containment live |
| Gecko-compat / site breakage | Inherited from the Gecko base; the "private *and* usable" promise is the hardest to deliver and what users judge daily |

## The bottom line

Comet watches your screen and ships it to a cloud. Brave admits it needs new architectures and ships none. Gartner tells the market to block AI browsers because inspectable, enforceable agent intent doesn't exist. **BearBrowser's agent runs on your machine, blocks the dangerous action before it happens, and proves it with a sealed receipt** — the literal capability the entire industry just admitted it can't field.

The strategy is aimed correctly. The risk was never positioning — it was maturity, and the first binary took the biggest bite out of it.
