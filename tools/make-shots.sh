#!/bin/zsh
# Builds the portfolio assets in prototype/shots from the SwiftUI renders in docs/screens:
# 600-wide JPEGs, a 256 px icon and a 1440x900 desktop scene (tools/desk.html, headless Chrome).
# Re-run after re-rendering docs/screens. Needs dist/MacTalk.app (scripts/build-app.sh) for the icon.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p prototype/shots
sips -s format png --resampleWidth 256 dist/MacTalk.app/Contents/Resources/AppIcon.icns --out prototype/shots/icon-256.png >/dev/null
for p in docs/screens/*.png; do
  f=${p:t:r}; w=$(sips -g pixelWidth "$p" | awk '/pixelWidth/{print $2}')
  if (( w > 600 )); then sips -s format jpeg -s formatOptions 86 --resampleWidth 600 "$p" --out "prototype/shots/$f.jpg" >/dev/null
  else sips -s format jpeg -s formatOptions 86 "$p" --out "prototype/shots/$f.jpg" >/dev/null; fi
done
T=$(mktemp -d)
cp tools/desk.html "$T/"; cp prototype/shots/icon-256.png "$T/icon.png"
cp docs/screens/{popover-light,incoming-light}.png "$T/"
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless=new --disable-gpu --hide-scrollbars \
  --window-size=1440,900 --screenshot="$T/desk.png" "file://$T/desk.html" 2>/dev/null
sips -s format jpeg -s formatOptions 86 "$T/desk.png" --out prototype/shots/desktop.jpg >/dev/null
rm -rf "$T"
echo "Wrote prototype/shots/"
