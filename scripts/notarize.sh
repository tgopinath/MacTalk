#!/usr/bin/env bash
# Notarizes and staples dist/MacTalk.app (must be signed with a Developer ID identity).
# One-time: xcrun notarytool store-credentials mactalk --apple-id you@example.com --team-id TEAMID
set -euo pipefail
cd "$(dirname "$0")/.."
PROFILE="${NOTARY_PROFILE:-mactalk}"
ditto -c -k --keepParent dist/MacTalk.app dist/MacTalk.zip
xcrun notarytool submit dist/MacTalk.zip --keychain-profile "$PROFILE" --wait
xcrun stapler staple dist/MacTalk.app
ditto -c -k --keepParent dist/MacTalk.app dist/MacTalk.zip
echo "✓ Notarized: dist/MacTalk.zip"
