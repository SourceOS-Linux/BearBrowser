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
    // The graph surface is served by the same local brain in sovereign mode
    // (agent-machine serves 76 /api/graph/* routes), so it points at it. studio is
    // partial locally (/api/studio); the full notebook/compute plane is cloud
    // (lattice-studio), so studio degrades to read-only-ish offline.
    hellgraph: 'http://127.0.0.1:8080',
    studio: 'http://127.0.0.1:8080',
    // CAPABILITY TIERING (verified against agent-machine's route table):
    // reason / er / ie / algo / sherlock are CONNECTED-ONLY — the local agent-machine
    // serves ZERO routes for them (they're separate GKE services: owl-reasoner,
    // entity-resolution, ie-engine, algo-engine, sherlock-engine). There is no local
    // backend to map them to, so they are intentionally UNSET here: the resolver falls
    // back to /svc/* (no proxy offline) and the surfaces degrade gracefully — they're
    // built to handle an unavailable backend. Registering (connected mode) is what
    // enables them. This is the sovereign capability subset, not a gap to be filled.
  },
};
