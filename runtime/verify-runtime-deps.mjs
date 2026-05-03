import fs from 'node:fs';

const pkg = JSON.parse(fs.readFileSync(new URL('../package.json', import.meta.url), 'utf8'));
const dependencies = pkg.dependencies || {};
const failures = [];

const expected = {
  playwright: '1.55.1',
  '@browserbasehq/stagehand': '3.3.0'
};

for (const [name, version] of Object.entries(dependencies)) {
  if (/^[~^]/.test(version)) {
    failures.push(`${name} uses floating semver range: ${version}`);
  }
  if (version.includes('*') || version === 'latest') {
    failures.push(`${name} uses non-deterministic version: ${version}`);
  }
}

for (const [name, version] of Object.entries(expected)) {
  if (dependencies[name] !== version) {
    failures.push(`${name} must remain pinned to ${version} until dependency policy is executed; found ${dependencies[name]}`);
  }
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
  expected,
  allowFloatingRanges: false,
  requireLockfileBeforeRelease: true
}, null, 2));
