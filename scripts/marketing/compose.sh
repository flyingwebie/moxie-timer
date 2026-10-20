#!/bin/bash
# Composes docs/images/{hero,focus,time,insights}.png (1600×900) from raw screen captures.
#   scripts/marketing/compose.sh <shots-dir>
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="$ROOT/scripts/marketing"
SHOTS="$(cd "$1" && pwd)"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
WORK="$(mktemp -d /tmp/moxie-compose.XXXX)"
trap 'rm -rf "$WORK"' EXIT

cp "$HERE/style.css" "$WORK/"
for page in hero focus time insights; do
  sed -e "s#{{SHOTS}}#$SHOTS#g" -e "s#{{ROOT}}#$ROOT#g" "$HERE/$page.html" > "$WORK/$page.html"
  "$CHROME" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=1 --user-data-dir="$WORK/chrome" \
    --allow-file-access-from-files --window-size=1600,900 --screenshot="$ROOT/docs/images/$page.png" "file://$WORK/$page.html" >/dev/null 2>&1
  echo "  docs/images/$page.png"
done
