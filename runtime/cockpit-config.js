// cockpit-config.js — sovereign runtime config for the embedded SocioProphet cockpit.
//
// build-cockpit.sh copies this into Contents/Resources/cockpit/ and injects a
// <script src="./cockpit-config.js"> into index.html so it runs BEFORE the app
// bundle. The client-vue runtime resolver (src/config/cockpitRuntime.ts) reads
// window.__COCKPIT_CONFIG__ at boot; this file is what puts the cockpit in
// SOVEREIGN mode against loopback sidecars, with no off-device egress.
//
// The ports here are the sovereign DEFAULTS. BearBrowser rewrites this file at
// launch with the live sidecar ports (they're ephemeral — see the sidecar
// launchers), so the committed values are just a usable pre-rewrite fallback.
window.__COCKPIT_CONFIG__ = {
  mode: 'sovereign',
  bases: {
    // The Noetica agent-machine loopback sidecar — the local brain. server.ts serves
    // 823 /api/* routes (graph, pipelines, devspace, knowledge, chat) on 127.0.0.1.
    // BearBrowser injects the live port; 8080 is the agent-machine default.
    agentMachine: 'http://127.0.0.1:8080',
    // The graph + studio surfaces are served by the same local brain in sovereign
    // mode (agent-machine's /api/graph/*, /api/studio/*), so they point at it too.
    hellgraph: 'http://127.0.0.1:8080',
    studio: 'http://127.0.0.1:8080',
    // ie / algo / sherlock / reason / er are the CONNECTED cloud decomposition
    // (separate GKE services). In sovereign mode they either resolve into the
    // agent-machine's /api or degrade until the per-service loopback map lands
    // (mode-semantics follow-up — composition-plan gap #3). Left unset here so the
    // resolver's fallback governs, rather than pointing at a port that 404s.
  },
};
