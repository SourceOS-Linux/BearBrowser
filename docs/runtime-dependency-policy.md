# BearBrowser Runtime Dependency Policy

BearBrowser automation runtime dependencies are security-sensitive. They control browser execution, capture, extraction, and agent-facing automation surfaces.

## Current pins

```json
{
  "playwright": "1.55.1",
  "@browserbasehq/stagehand": "3.3.0"
}
```

## Policy

- Do not use floating semver ranges for automation runtime dependencies.
- Do not use `latest`.
- Do not update Playwright or Stagehand without an explicit dependency review.
- Do not enable full live Stagehand execution until the installed Stagehand package version and API surface are verified against BearBrowser runtime code.
- Commit a lockfile before any release artifact depends on these packages.
- Run dependency verification before promotion.

## Audit-driven promotion rationale

The first npm audit run against the conservative v2/v1.55.0 pins reported:

- a high-severity Playwright advisory affecting versions below `1.55.1`,
- transitive Stagehand v2 vulnerabilities through `ai` and `jsondiffpatch`,
- npm's non-breaking remediation could not clear the Stagehand track without a major upgrade.

BearBrowser therefore promotes:

- Playwright to `1.55.1`, the minimum patched line for the reported advisory.
- Stagehand to `3.3.0`, while keeping live Stagehand execution guarded until API/provider/PolicyFabric review is complete.

## Update procedure

1. Check official npm metadata for `playwright` and `@browserbasehq/stagehand`.
2. Read upstream changelogs and migration notes.
3. Update `package.json` pins.
4. Update `runtime/verify-runtime-deps.mjs` expected versions.
5. Regenerate and commit the lockfile.
6. Run `npm audit --omit=dev`.
7. Run `npm run bearbrowser:deps:verify`.
8. Run Playwright dry-run and guarded live smoke test.
9. Run Stagehand compatibility check.
10. Update this document with rationale.

## Release gate

A BearBrowser release cannot rely on automation runtime dependencies unless:

- dependency pins are exact,
- lockfile exists,
- dependency verifier passes,
- known vulnerabilities are reviewed,
- live execution remains policy-gated,
- provenance events remain emitted for governed operations.
