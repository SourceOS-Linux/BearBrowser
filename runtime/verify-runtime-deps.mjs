import fs from 'node:fs';

const pkg = JSON.parse(fs.readFileSync(new URL('../package.json', import.meta.url), 'utf8'));
const dependencies = pkg.dependencies || {};
const peerDependencies = pkg.peerDependencies || {};
const policy = pkg.bearbrowser?.dependencyPolicy || {};
const failures = [];

const expectedDependencies = {
  playwright: '1.55.1'
};

const expectedOptionalPeers = {
  '@browserbasehq/stagehand': '3.3.0'
};

for (const collection of [dependencies, peerDependencies]) {
  for (const [name, version] of Object.entries(collection)) {
    if (/^[~^]/.test(version)) {
      failures.push(`${name} uses floating semver range: ${version}`);
    }
    if (version.includes('*') || version === 'latest') {
      failures.push(`${name} uses non-deterministic version: ${version}`);
    }
  }
}

for (const [name, version] of Object.entries(expectedDependencies)) {
  if (dependencies[name] !== version) {
    failures.push(`${name} must remain pinned to ${version}; found ${dependencies[name]}`);
  }
}

for (const [name, version] of Object.entries(expectedOptionalPeers)) {
  if (peerDependencies[name] !== version) {
    failures.push(`${name} must remain an optional peer pinned to ${version}; found ${peerDependencies[name]}`);
  }
}

if (dependencies['@browserbasehq/stagehand']) {
  failures.push('@browserbasehq/stagehand must not be a default dependency until its transitive audit findings are resolved');
}

if (policy.stagehandDefaultInstall !== false) {
  failures.push('bearbrowser.dependencyPolicy.stagehandDefaultInstall must be false until Stagehand audit findings are resolved');
}

if (failures.length) {
  for (const failure of failures) {
    console.error(`ERROR: ${failure}`);
  }
  process.exit(1);
}

console.log('BearBrowser runtime dependency policy verified');
console.log(JSON.stringify({
  dependencies,
  peerDependencies,
  expectedDependencies,
  expectedOptionalPeers,
  allowFloatingRanges: false,
  requireLockfileBeforeRelease: true
}, null, 2));
