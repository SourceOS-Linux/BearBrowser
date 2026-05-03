import fs from 'node:fs';

const pkg = JSON.parse(fs.readFileSync(new URL('../package.json', import.meta.url), 'utf8'));
const dependencies = pkg.dependencies || {};
const failures = [];

for (const [name, version] of Object.entries(dependencies)) {
  if (/^[~^]/.test(version)) {
    failures.push(`${name} uses floating semver range: ${version}`);
  }
  if (version.includes('*') || version === 'latest') {
    failures.push(`${name} uses non-deterministic version: ${version}`);
  }
}

if (dependencies.playwright !== '1.55.0') {
  failures.push(`playwright must remain pinned to 1.55.0 until update policy is executed; found ${dependencies.playwright}`);
}

if (dependencies['@browserbasehq/stagehand'] !== '2.5.0') {
  failures.push(`@browserbasehq/stagehand must remain pinned to 2.5.0 until Stagehand API review is executed; found ${dependencies['@browserbasehq/stagehand']}`);
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
  allowFloatingRanges: false,
  requireLockfileBeforeRelease: true
}, null, 2));
