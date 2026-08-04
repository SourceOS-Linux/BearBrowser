# BearBrowser OCI Packaging

The OCI lane packages `bearbrowser-agent-runtime` as a governed browser runtime for agents.

## Runtime requirements

- Run as non-root.
- Use explicit governed mounts only.
- Do not mount `$HOME`.
- Do not mount SSH, cloud, Kubernetes, GitHub CLI, or container socket credentials.
- Default to policy-mediated egress.
- Emit provenance events to `/run/sourceos/provenance`.
- Read runtime policy from `/run/sourceos/policy`.

## Required mounts

- `/workspace/downloads`
- `/workspace/browser-profile`
- `/workspace/browser-captures`
- `/run/sourceos/policy`
- `/run/sourceos/provenance`

## Optional mounts

- `/workspace/browser-cache`
- `/workspace/input`

## Next implementation step

Replace the runtime scaffold with a multi-stage image:

1. Build BearBrowser agent-runtime from the Nix package or upstream-derived workspace.
2. Copy only the required runtime closure into the OCI image.
3. Run browser automation through a policy-mediated entrypoint.
4. Export session artifacts through governed mounts.
