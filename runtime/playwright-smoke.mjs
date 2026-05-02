import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const url = process.env.BEARBROWSER_URL || 'about:blank';
const mode = process.env.BEARBROWSER_MODE || 'agent-runtime';
const live = process.env.BEARBROWSER_ENABLE_LIVE_PLAYWRIGHT === '1';
const policyDecisionId = process.env.BEARBROWSER_POLICY_DECISION_ID || '';
const provenanceDir = process.env.BEARBROWSER_PROVENANCE_PATH || path.join(os.tmpdir(), 'bearbrowser-provenance');

const event = {
  eventType: 'browser.session.started',
  eventVersion: 'v1alpha1',
  timestamp: new Date().toISOString(),
  sessionId: process.env.BEARBROWSER_SESSION_ID || `bb-${Date.now()}`,
  agentId: process.env.BEARBROWSER_AGENT_ID || 'local-smoke',
  workspaceId: process.env.BEARBROWSER_WORKSPACE_ID || 'local',
  profileMode: mode,
  policyDecisionId: policyDecisionId || null,
  url,
  liveExecution: live,
  controlPlane: 'playwright'
};

console.log('BearBrowser Playwright smoke');
console.log(JSON.stringify(event, null, 2));

if (!policyDecisionId && mode === 'agent-runtime') {
  console.error('ERROR: BEARBROWSER_POLICY_DECISION_ID is required for live agent-runtime Playwright execution.');
  if (!live) {
    console.log('Dry-run mode accepted without live execution.');
    process.exit(0);
  }
  process.exit(64);
}

if (!live) {
  console.log('Dry run complete. Set BEARBROWSER_ENABLE_LIVE_PLAYWRIGHT=1 to run a guarded live smoke test.');
  process.exit(0);
}

const { chromium } = await import('playwright');
fs.mkdirSync(provenanceDir, { recursive: true });
fs.writeFileSync(path.join(provenanceDir, `${event.sessionId}.started.json`), JSON.stringify(event, null, 2));

const browser = await chromium.launch({ headless: true });
try {
  const context = await browser.newContext({ acceptDownloads: false });
  const page = await context.newPage();
  console.log(JSON.stringify({
    eventType: 'browser.navigation.requested',
    timestamp: new Date().toISOString(),
    sessionId: event.sessionId,
    url,
    policyDecisionId
  }, null, 2));
  await page.goto(url, { waitUntil: 'domcontentloaded' });
  console.log(JSON.stringify({
    eventType: 'browser.navigation.completed',
    timestamp: new Date().toISOString(),
    sessionId: event.sessionId,
    url: page.url(),
    title: await page.title()
  }, null, 2));
} finally {
  await browser.close();
  console.log(JSON.stringify({
    eventType: 'browser.session.ended',
    timestamp: new Date().toISOString(),
    sessionId: event.sessionId,
    cleanupStatus: 'browserClosed'
  }, null, 2));
}
