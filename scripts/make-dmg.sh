#!/usr/bin/env bash
# Packages dist/MacTalk.app into dist/MacTalk.dmg (drag-to-Applications layout).
# Run scripts/build-app.sh <env> release first. Signs the DMG with $SIGN_IDENTITY if set.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ -d dist/MacTalk.app ]] || { echo "Build dist/MacTalk.app first"; exit 1; }
STAGE="$(mktemp -d)/MacTalk"
mkdir -p "$STAGE"
ditto dist/MacTalk.app "$STAGE/MacTalk.app"
ln -s /Applications "$STAGE/Applications"
rm -f dist/MacTalk.dmg
hdiutil create -volname "MacTalk" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov dist/MacTalk.dmg >/dev/null
if [[ -n "${SIGN_IDENTITY:-}" && "$SIGN_IDENTITY" != "-" ]]; then
  codesign --force --timestamp --sign "$SIGN_IDENTITY" dist/MacTalk.dmg
fi
echo "✓ dist/MacTalk.dmg ($(du -h dist/MacTalk.dmg | cut -f1))"
