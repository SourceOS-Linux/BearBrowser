# BearBrowser Runtime Dependency Policy

BearBrowser automation runtime dependencies are security-sensitive. They control browser execution, capture, extraction, and agent-facing automation surfaces.

## Current pins

```json
{
  "playwright": "1.55.0",
  "@browserbasehq/stagehand": "2.5.0"
}
```

## Policy

- Do not use floating semver ranges for automation runtime dependencies.
- Do not use `latest`.
- Do not update Playwright or Stagehand without an explicit dependency review.
- Do not enable full live Stagehand execution until the installed Stagehand package version and API surface are verified against BearBrowser runtime code.
- Commit a lockfile before any release artifact depends on these packages.
- Run dependency verification before promotion.

## Why Stagehand is pinned conservatively

Stagehand public package and documentation signals can differ by major version and API surface. BearBrowser currently pins Stagehand to the v2 track until the v3 API, provider credential model, and PolicyFabric integration are reviewed.

## Update procedure

1. Check official npm metadata for `playwright` and `@browserbasehq/stagehand`.
2. Read upstream changelogs and migration notes.
3. Update `package.json` pins.
4. Regenerate and commit the lockfile.
5. Run `npm audit --omit=dev`.
6. Run `npm run bearbrowser:deps:verify`.
7. Run Playwright dry-run and guarded live smoke test.
8. Run Stagehand compatibility check.
9. Update this document with rationale.

## Release gate

A BearBrowser release cannot rely on automation runtime dependencies unless:

- dependency pins are exact,
- lockfile exists,
- dependency verifier passes,
- known vulnerabilities are reviewed,
- live execution remains policy-gated,
- provenance events remain emitted for governed operations.
