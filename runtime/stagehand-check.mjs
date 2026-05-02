const url = process.env.BEARBROWSER_URL || 'about:blank';
const operation = process.env.BEARBROWSER_STAGEHAND_OPERATION || 'observe';
const live = process.env.BEARBROWSER_ENABLE_LIVE_STAGEHAND === '1';
const policyDecisionId = process.env.BEARBROWSER_POLICY_DECISION_ID || '';

console.log('BearBrowser Stagehand compatibility check');
console.log(JSON.stringify({
  eventType: 'browser.stagehand.check',
  eventVersion: 'v1alpha1',
  timestamp: new Date().toISOString(),
  operation,
  url,
  policyDecisionId: policyDecisionId || null,
  liveExecution: live,
  controlPlane: 'stagehand'
}, null, 2));

let stagehandModule;
try {
  stagehandModule = await import('@browserbasehq/stagehand');
} catch (error) {
  console.error('ERROR: @browserbasehq/stagehand is not installed. Run npm install in the BearBrowser repo or install the runtime package.');
  process.exit(2);
}

console.log(JSON.stringify({
  eventType: 'browser.stagehand.dependency.available',
  timestamp: new Date().toISOString(),
  exports: Object.keys(stagehandModule).sort()
}, null, 2));

if (!live) {
  console.log('Dry run complete. Set BEARBROWSER_ENABLE_LIVE_STAGEHAND=1 only after PolicyFabric and provider credentials are configured.');
  process.exit(0);
}

if (!policyDecisionId) {
  console.error('ERROR: BEARBROWSER_POLICY_DECISION_ID is required for live Stagehand execution.');
  process.exit(64);
}

console.error('ERROR: live Stagehand execution is intentionally not wired until provider credentials and PolicyFabric adapter are implemented.');
process.exit(64);
