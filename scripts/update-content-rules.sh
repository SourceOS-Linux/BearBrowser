#!/usr/bin/env bash
# Downloads EasyList + EasyPrivacy + uBlock Origin's unbreak/extra lists,
# converts them to WKContentRuleList JSON format, and saves to
# ~/Library/Application Support/BearBrowser/content-rules/rules.json
# so BearBrowser picks them up on next launch.
#
# Run this periodically (e.g. weekly via launchd) to keep rules fresh.
set -euo pipefail

out_dir="${HOME}/Library/Application Support/BearBrowser/content-rules"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

mkdir -p "$out_dir"

echo "Downloading filter lists..."

LISTS=(
  "https://easylist.to/easylist/easylist.txt"
  "https://easylist.to/easylist/easyprivacy.txt"
  "https://raw.githubusercontent.com/uBlockOrigin/uAssets/master/filters/filters.txt"
  "https://raw.githubusercontent.com/uBlockOrigin/uAssets/master/filters/privacy.txt"
  "https://raw.githubusercontent.com/uBlockOrigin/uAssets/master/filters/unbreak.txt"
  "https://raw.githubusercontent.com/uBlockOrigin/uAssets/master/filters/quick-fixes.txt"
)

combined="$tmp_dir/combined.txt"
for url in "${LISTS[@]}"; do
  name="$(basename "$url")"
  echo "  $name"
  curl -fsSL --max-time 30 "$url" >> "$combined" 2>/dev/null || echo "  WARN: could not fetch $url"
done

echo "Converting to WKContentRuleList JSON..."

python3 - "$combined" "$out_dir/rules.json" <<'PYEOF'
import sys, json, re

src = open(sys.argv[1]).read().splitlines()
out = sys.argv[2]

rules = []

# Cosmetic (CSS hide) rules
css_selectors_by_domain = {}

def abp_to_regex(pattern):
    """Convert AdBlock Plus filter pattern to a URL regex string."""
    if not pattern:
        return None
    # Strip anchors
    anchored_start = pattern.startswith('||')
    anchored_exact = pattern.startswith('|') and not anchored_start
    pattern = pattern.lstrip('|')
    # Escape regex special chars except * and ^
    escaped = re.sub(r'([.+?{}()\[\]\\])', r'\\\1', pattern)
    # ^ matches separator
    escaped = escaped.replace('^', '[^a-zA-Z0-9._%-]')
    # * is wildcard
    escaped = escaped.replace('*', '.*')
    if anchored_start:
        escaped = r'[a-z]+:\/\/' + escaped
    return escaped if escaped else None

skipped = 0
converted = 0

for line in src:
    line = line.strip()
    # Skip comments and blank lines
    if not line or line.startswith('!') or line.startswith('['):
        continue
    # Cosmetic rules (##, #@#, etc.) — convert to CSS display:none
    if '##' in line and not line.startswith('@@'):
        parts = line.split('##', 1)
        selector = parts[1].strip() if len(parts) > 1 else ''
        if selector and not selector.startswith('+js(') and not selector.startswith('script:'):
            domains_raw = parts[0].strip()
            domains = [d.strip().lstrip('~') for d in domains_raw.split(',') if d.strip() and not d.startswith('~')]
            rule = {
                "trigger": {"url-filter": ".*"},
                "action": {"type": "css-display-none", "selector": selector}
            }
            if domains:
                rule["trigger"]["if-domain"] = ["*" + d if not d.startswith("*") else d for d in domains]
            rules.append(rule)
            converted += 1
            if converted > 20000:  # WKContentRuleList cap
                break
        continue
    # Exception rules — skip (whitelist logic not supported in basic form)
    if line.startswith('@@'):
        continue
    # Network block rules
    options_str = ''
    if '$' in line:
        idx = line.rfind('$')
        options_str = line[idx+1:]
        line = line[:idx]
    options = [o.strip() for o in options_str.split(',') if o.strip()]
    # Skip rules requiring JS injection or complex options
    skip_opts = {'script','redirect','csp','rewrite','ping','websocket','xmlhttprequest',
                 'subdocument','popup','inline-script','inline-font','generichide','genericblock'}
    if any(o.lstrip('~') in skip_opts or o.startswith('redirect') for o in options):
        skipped += 1
        continue
    resource_types = []
    load_type = []
    for opt in options:
        if opt == 'third-party': load_type = ['third-party']
        elif opt == 'first-party': load_type = ['first-party']
        elif opt == 'image': resource_types.append('image')
        elif opt == 'stylesheet': resource_types.append('style-sheet')
        elif opt == 'font': resource_types.append('font')
        elif opt == 'media': resource_types.append('media')
        elif opt == 'document': resource_types.append('document')
    regex = abp_to_regex(line)
    if not regex or len(regex) < 4:
        skipped += 1
        continue
    # Limit regex complexity to avoid WKContentRuleList rejection
    if len(regex) > 200:
        skipped += 1
        continue
    trigger = {"url-filter": regex, "url-filter-is-case-sensitive": False}
    if load_type: trigger["load-type"] = load_type
    if resource_types: trigger["resource-type"] = resource_types
    rules.append({"trigger": trigger, "action": {"type": "block"}})
    converted += 1
    if converted > 49000:  # hard cap
        break

print(f"Converted {converted} rules, skipped {skipped}")
with open(out, 'w') as f:
    json.dump(rules, f, separators=(',', ':'))
print(f"Wrote {len(rules)} rules to {out}")
PYEOF

rule_count=$(python3 -c "import json; d=json.load(open('$out_dir/rules.json')); print(len(d))" 2>/dev/null || echo "?")
echo ""
echo "Done. $rule_count rules written to:"
echo "  $out_dir/rules.json"
echo ""
echo "Restart BearBrowser to apply updated rules."
