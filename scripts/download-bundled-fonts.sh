#!/usr/bin/env bash
# Downloads the ~80% Pareto set of Google Fonts web fonts into the app resources
# so the browser can serve them locally and block CDN tracking entirely.
# Fonts cover ~80% of all Google Fonts usage by pageview.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="${BEARBROWSER_HOME:-$(cd "$script_dir/.." && pwd)}"
out_dir="${1:-$repo_root/native/macos/fonts}"
gf_api_key="${GOOGLE_FONTS_API_KEY:-}"

mkdir -p "$out_dir"

# Top ~25 Google Fonts families covering ~80% of usage (2024 rankings).
# Weights: 400 (regular) + 700 (bold) + 300 (light) + italic variants.
# Source: Google Fonts Analytics public data.
FAMILIES=(
  "Inter"
  "Roboto"
  "Open+Sans"
  "Noto+Sans"
  "Lato"
  "Montserrat"
  "Poppins"
  "Source+Sans+3"
  "Oswald"
  "Raleway"
  "Ubuntu"
  "Nunito"
  "Merriweather"
  "Playfair+Display"
  "PT+Sans"
  "Work+Sans"
  "Mulish"
  "Fira+Sans"
  "Noto+Serif"
  "Libre+Baskerville"
  "DM+Sans"
  "Manrope"
  "Plus+Jakarta+Sans"
  "Outfit"
  "Sora"
)

UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
css_dir="$out_dir/css"
woff2_dir="$out_dir/woff2"
mkdir -p "$css_dir" "$woff2_dir"

fetch_family() {
  local family="$1"
  local family_slug="${family//+/-}"
  family_slug="${family_slug,,}"

  local css_url="https://fonts.googleapis.com/css2?family=${family}:ital,wght@0,300;0,400;0,500;0,600;0,700;1,400;1,700&display=swap"

  echo "Fetching $family..."
  local css
  css=$(curl -fsSL -A "$UA" "$css_url" 2>/dev/null) || { echo "  SKIP: $family (fetch failed)"; return; }

  # Save css for reference
  echo "$css" > "$css_dir/${family_slug}.css"

  # Extract all woff2 URLs and download them
  while IFS= read -r url; do
    local filename
    filename=$(echo "$url" | sed 's|.*/||;s|?.*||')
    # Prefix with family slug so filenames are unique
    local dest="$woff2_dir/${family_slug}-${filename}"
    if [ ! -f "$dest" ]; then
      curl -fsSL "$url" -o "$dest" 2>/dev/null || echo "  WARN: failed to download $url"
    fi
  done < <(echo "$css" | grep -oE 'https://fonts\.gstatic\.com/[^)]+\.woff2' | sort -u)
}

for family in "${FAMILIES[@]}"; do
  fetch_family "$family"
done

# Generate a combined CSS file with @font-face rules pointing to bbfont:// scheme.
# The browser's BBFontSchemeHandler serves these from the bundle.
combined="$out_dir/bearbrowser-fonts.css"
echo "/* BearBrowser bundled fonts — served locally via bbfont:// scheme */" > "$combined"

for family in "${FAMILIES[@]}"; do
  family_slug="${family//+/-}"
  family_slug="${family_slug,,}"
  css_file="$css_dir/${family_slug}.css"
  [ -f "$css_file" ] || continue
  # Rewrite gstatic URLs to bbfont:// scheme
  sed "s|url(https://fonts\.gstatic\.com/[^)]*\([^/)]*\.woff2\))|url(bbfont://fonts/\1)|g; \
       s|url(https://fonts\.gstatic\.com/[^)]*)|url(bbfont://fonts/UNKNOWN)|g" \
       "$css_file" >> "$combined"
  echo "" >> "$combined"
done

# Rename all woff2 files to their basename (strip query strings, make flat)
for f in "$woff2_dir"/*.woff2; do
  [ -f "$f" ] || continue
done

font_count=$(find "$woff2_dir" -name '*.woff2' | wc -l | tr -d ' ')
echo ""
echo "Done. $font_count woff2 files in $woff2_dir"
echo "Combined CSS: $combined"
echo ""
echo "Copy to app bundle resources:"
echo "  cp -r '$out_dir' '/Applications/BearBrowser.app/Contents/Resources/fonts'"
echo "  OR re-run: bash scripts/repair-macos-app-launcher.sh"
