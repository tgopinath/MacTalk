#!/usr/bin/env bash
# Builds MacTalk.app.
#   scripts/build-app.sh [development|staging|production] [debug|release]
# Signing:
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"  (default: ad-hoc "-")
#   BUNDLE_ID=app.mactalk.MacTalk  VERSION=1.0.0  BUILD=1
set -euo pipefail
cd "$(dirname "$0")/.."

ENVIRONMENT="${1:-development}"
CONFIG="${2:-debug}"
BUNDLE_ID="${BUNDLE_ID:-app.mactalk.MacTalk}"
VERSION="${VERSION:-1.0.0}"
BUILD="${BUILD:-$(date +%Y%m%d%H%M)}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
ENV_FILE="Config/${ENVIRONMENT}.env"

[[ -f "$ENV_FILE" ]] || { echo "Missing $ENV_FILE (copy Config/example.env)"; exit 1; }
# shellcheck disable=SC1090
source "$ENV_FILE"

ARCH_FLAGS=()
[[ "$CONFIG" == "release" ]] && ARCH_FLAGS=(--arch arm64 --arch x86_64)

echo "▸ Building ($CONFIG, $ENVIRONMENT)…"
swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --product MacTalk
BIN_DIR="$(swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"

APP="dist/MacTalk.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

cp "$BIN_DIR/MacTalk" "$APP/Contents/MacOS/MacTalk"
WEBRTC="$(find .build/artifacts -path '*macos*' -name WebRTC.framework -type d | head -1)"
ditto "$WEBRTC" "$APP/Contents/Frameworks/WebRTC.framework"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/MacTalk" 2>/dev/null || true

sed -e "s|__BUNDLE_ID__|$BUNDLE_ID|" -e "s|__VERSION__|$VERSION|" -e "s|__BUILD__|$BUILD|" \
    -e "s|__ENV__|$ENVIRONMENT|" -e "s|__SUPABASE_URL__|${SUPABASE_URL}|" -e "s|__SUPABASE_ANON_KEY__|${SUPABASE_ANON_KEY}|" \
    Resources/Info.plist > "$APP/Contents/Info.plist"

ICONSET="$(mktemp -d)/AppIcon.iconset"
swift scripts/make-icon.swift "$ICONSET" >/dev/null
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

echo "▸ Signing with identity: $SIGN_IDENTITY"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  # Local ad-hoc build: hardened runtime library validation needs a Team ID, so it's off here.
  codesign --force --sign - "$APP/Contents/Frameworks/WebRTC.framework"
  codesign --force --entitlements Resources/MacTalk.entitlements --sign - "$APP"
else
  # Developer ID build: hardened runtime + secure timestamp (required for notarization).
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP/Contents/Frameworks/WebRTC.framework"
  codesign --force --options runtime --timestamp --entitlements Resources/MacTalk.entitlements --sign "$SIGN_IDENTITY" "$APP"
fi
codesign --verify --deep --strict "$APP"
echo "✓ $APP"
