#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

tmp="$(mktemp -d)"
port="18765"
server_pid=""
cleanup() {
  if [ -n "$server_pid" ]; then
    kill "$server_pid" >/dev/null 2>&1 || true
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT

export HOME="$tmp/home"
mkdir -p "$HOME"

python3 scripts/bearbrowser-propose-action.py \
  --action-type share_page_with_agent \
  --profile bootstrap \
  --actor-type human \
  --actor-id ci \
  --target-kind page \
  --target-label ci-interactive-sidecar \
  >/dev/null

python3 scripts/bearbrowser-memory-candidate.py create \
  --text "Remember that interactive sidecar can resolve memory candidates." \
  --actor-type human \
  --actor-id ci \
  --source-kind note \
  --source-label ci-interactive-sidecar \
  >/dev/null

python3 scripts/bearbrowser-page-summary.py create \
  --text "Interactive sidecar renders read-only page summary proposals." \
  --actor-type human \
  --actor-id ci \
  --source-kind page \
  --source-label ci-interactive-summary \
  >/dev/null

python3 scripts/bearbrowser-page-comparison.py create \
  --left-text "Interactive sidecar renders held page comparison proposals." \
  --right-text "Held comparison proposals are visible and auditable." \
  --left-kind page \
  --right-kind note \
  --left-label ci-interactive-left-comparison \
  --right-label ci-interactive-right-comparison \
  >/dev/null

url="$(python3 scripts/bearbrowser-sidecar-server.py --port "$port" --print-url)"
python3 scripts/bearbrowser-sidecar-server.py --port "$port" >"$tmp/server.log" 2>&1 &
server_pid=$!

python3 - "$url" <<'PY'
import sys, time, urllib.request
url = sys.argv[1]
for _ in range(30):
    try:
        with urllib.request.urlopen(url, timeout=0.5) as response:
            if response.status == 200:
                raise SystemExit(0)
    except Exception:
        time.sleep(0.1)
raise SystemExit("server did not become ready")
PY

python3 - "$url" >"$tmp/page.html" <<'PY'
import sys, urllib.request
with urllib.request.urlopen(sys.argv[1], timeout=2) as response:
    print(response.read().decode())
PY

grep -q 'BearBrowser Governance Queue' "$tmp/page.html"
grep -q 'ci-interactive-sidecar' "$tmp/page.html"
grep -q 'Recent Page Summaries' "$tmp/page.html"
grep -q 'ci-interactive-summary' "$tmp/page.html"
grep -q 'Recent Page Comparisons' "$tmp/page.html"
grep -q 'ci-interactive-left-comparison' "$tmp/page.html"
grep -q 'Allow' "$tmp/page.html"
grep -q 'Reject' "$tmp/page.html"

action_id="$(python3 - <<'PY'
import json, pathlib
path = pathlib.Path.home() / 'Library/Application Support/BearBrowser/policy/actions.jsonl'
for line in path.read_text().splitlines():
    item = json.loads(line)
    if item.get('decision', {}).get('state') == 'hold':
        print(item['actionId'])
        break
PY
)"

memory_id="$(python3 - <<'PY'
import json, pathlib
path = pathlib.Path.home() / 'Library/Application Support/BearBrowser/memory/candidates.jsonl'
for line in path.read_text().splitlines():
    item = json.loads(line)
    if item.get('state') == 'candidate':
        print(item['memoryId'])
        break
PY
)"

token="${url#*token=}"

python3 - "$port" "$token" "$action_id" <<'PY'
import sys, urllib.parse, urllib.request
port, token, action_id = sys.argv[1:]
data = urllib.parse.urlencode({'action_id': action_id}).encode()
url = f'http://127.0.0.1:{port}/action/deny?token={urllib.parse.quote(token)}'
request = urllib.request.Request(url, data=data, method='POST')
with urllib.request.urlopen(request, timeout=3) as response:
    body = response.read().decode()
    if 'Denied held action.' not in body:
        raise SystemExit(body[:500])
PY

python3 - "$port" "$token" "$memory_id" <<'PY'
import sys, urllib.parse, urllib.request
port, token, memory_id = sys.argv[1:]
data = urllib.parse.urlencode({'memory_id': memory_id}).encode()
url = f'http://127.0.0.1:{port}/memory/reject?token={urllib.parse.quote(token)}'
request = urllib.request.Request(url, data=data, method='POST')
with urllib.request.urlopen(request, timeout=3) as response:
    body = response.read().decode()
    if 'Rejected memory candidate.' not in body:
        raise SystemExit(body[:500])
PY

python3 scripts/bearbrowser-verify-actions.py
python3 scripts/bearbrowser-verify-memory.py
python3 scripts/bearbrowser-verify-summaries.py
python3 scripts/bearbrowser-verify-comparisons.py
python3 scripts/bearbrowser-verify-provenance.py

python3 scripts/bearbrowser-governance-queue.py --format json >"$tmp/queue.json"
grep -q '"heldActionCount": 1' "$tmp/queue.json"
grep -q '"pendingMemoryCount": 0' "$tmp/queue.json"

python3 scripts/bearbrowser-sidecar-server.py --host 0.0.0.0 --print-url >/tmp/bearbrowser-sidecar-invalid 2>&1 && {
  echo "ERROR: sidecar server accepted non-local bind" >&2
  exit 1
} || true

echo "BearBrowser interactive sidecar verified"
