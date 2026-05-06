import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';

const url = process.env.BEARBROWSER_URL || 'about:blank';
const mode = process.env.BEARBROWSER_MODE || 'agent-runtime';
const live = process.env.BEARBROWSER_ENABLE_LIVE_PLAYWRIGHT === '1';
const policyDecisionId = process.env.BEARBROWSER_POLICY_DECISION_ID || '';
const provenanceDir = process.env.BEARBROWSER_PROVENANCE_PATH || path.join(os.tmpdir(), 'bearbrowser-provenance');

const sessionId = process.env.BEARBROWSER_SESSION_ID || `bb-${Date.now()}`;
const agentId = process.env.BEARBROWSER_AGENT_ID || 'local-smoke';
const workspaceId = process.env.BEARBROWSER_WORKSPACE_ID || 'local';

// Generate the hex suffix for the receipt URN.
const receiptHexId = crypto.randomBytes(8).toString('hex');
const receiptId = `urn:srcos:receipt:browser-automation:${receiptHexId}`;

function buildReceipt(status, extra = {}) {
  const receipt = {
    schemaVersion: 'bearbrowser.browser_automation_receipt.v1',
    receiptId,
    sessionRef: sessionId,
    ownerRef: agentId,
    transport: 'cdp',
    permissionScope: ['read_dom', 'click', 'type'],
    origin: 'local',
    userVisible: true,
    revocable: true,
    policyDecisionRef: policyDecisionId || 'not-yet-assigned',
    evidenceRefs: [],
    capturedAt: new Date().toISOString(),
    status,
    displayName: `${agentId} (playwright smoke)`,
    ...extra,
  };
  return receipt;
}

function emitReceipt(status, extra = {}) {
  const receipt = buildReceipt(status, extra);
  console.log(JSON.stringify({ eventType: 'browser.automation.receipt', receipt }, null, 2));
  return receipt;
}

const event = {
  eventType: 'browser.session.started',
  eventVersion: 'v1alpha1',
  timestamp: new Date().toISOString(),
  sessionId,
  agentId,
  workspaceId,
  profileMode: mode,
  policyDecisionId: policyDecisionId || null,
  automationReceiptId: receiptId,
  url,
  liveExecution: live,
  controlPlane: 'playwright'
};

console.log('BearBrowser Playwright smoke');
console.log(JSON.stringify(event, null, 2));

if (!policyDecisionId && mode === 'agent-runtime') {
  console.error('ERROR: BEARBROWSER_POLICY_DECISION_ID is required for live agent-runtime Playwright execution.');
  // Emit a denied receipt so the session is not silently orphaned.
  emitReceipt('denied');
  if (!live) {
    console.log('Dry-run mode accepted without live execution.');
    process.exit(0);
  }
  process.exit(64);
}

if (!live) {
  console.log('Dry run complete. Set BEARBROWSER_ENABLE_LIVE_PLAYWRIGHT=1 to run a guarded live smoke test.');
  // Emit an ended receipt for observability in dry-run mode.
  emitReceipt('ended');
  process.exit(0);
}

const { chromium } = await import('playwright');
fs.mkdirSync(provenanceDir, { recursive: true });

// Emit and persist the active automation receipt before the transport starts.
const activeReceipt = emitReceipt('active');
const receiptPath = path.join(provenanceDir, `${sessionId}.receipt.json`);
fs.writeFileSync(receiptPath, JSON.stringify(activeReceipt, null, 2));

fs.writeFileSync(path.join(provenanceDir, `${sessionId}.started.json`), JSON.stringify(event, null, 2));

const browser = await chromium.launch({ headless: true });
try {
  const context = await browser.newContext({ acceptDownloads: false });
  const page = await context.newPage();
  console.log(JSON.stringify({
    eventType: 'browser.navigation.requested',
    timestamp: new Date().toISOString(),
    sessionId,
    automationReceiptId: receiptId,
    url,
    policyDecisionId
  }, null, 2));
  await page.goto(url, { waitUntil: 'domcontentloaded' });
  console.log(JSON.stringify({
    eventType: 'browser.navigation.completed',
    timestamp: new Date().toISOString(),
    sessionId,
    automationReceiptId: receiptId,
    url: page.url(),
    title: await page.title()
  }, null, 2));
} finally {
  await browser.close();
  // Update the receipt to ended state.
  const endedReceipt = emitReceipt('ended');
  fs.writeFileSync(receiptPath, JSON.stringify(endedReceipt, null, 2));
  console.log(JSON.stringify({
    eventType: 'browser.session.ended',
    timestamp: new Date().toISOString(),
    sessionId,
    automationReceiptId: receiptId,
    cleanupStatus: 'browserClosed',
    receiptStatus: 'ended'
  }, null, 2));
}
