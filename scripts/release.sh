#!/usr/bin/env bash
# Publishes a new MacTalk version that installed copies pick up automatically.
#   scripts/release.sh 1.0.2 "What changed in this version"
# Builds a signed universal app, creates the DMG (for new installs) and a Sparkle-signed
# zip (for auto-updates), creates GitHub release v<version>, and adds the version to
# appcast.xml, which GitHub Pages serves at https://tgopinath.github.io/MacTalk/appcast.xml.
# The EdDSA private key lives in the login Keychain (created by .tools/bin/generate_keys).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/release.sh <version> \"notes\"}"
NOTES="${2:-Improvements and fixes.}"
BUILD="$(date +%Y%m%d%H%M)"
REPO="tgopinath/MacTalk"
GH="${GH:-$HOME/.local/bin/gh}"
export SIGN_IDENTITY="${SIGN_IDENTITY:-Apple Development: tgopinath1992@gmail.com (RQ3GQW48D8)}"

if [[ ! -x .tools/bin/sign_update ]]; then
  mkdir -p .tools && curl -sL https://github.com/sparkle-project/Sparkle/releases/download/2.10.1/Sparkle-2.10.1.tar.xz | tar -xJ -C .tools
fi

VERSION="$VERSION" BUILD="$BUILD" scripts/build-app.sh production release
scripts/make-dmg.sh
ZIP="dist/MacTalk-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent dist/MacTalk.app "$ZIP"
SIGNATURE="$(.tools/bin/sign_update "$ZIP")"   # sparkle:edSignature="…" length="…"

"$GH" release create "v$VERSION" dist/MacTalk.dmg "$ZIP" -R "$REPO" --title "MacTalk $VERSION" --notes "$NOTES"

python3 - "$VERSION" "$BUILD" "$NOTES" "$SIGNATURE" <<'PY'
import sys, html, email.utils, pathlib
version, build, notes, signature = sys.argv[1:]
path = pathlib.Path("appcast.xml")
if not path.exists():
    path.write_text('<?xml version="1.0" encoding="utf-8"?>\n<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">\n<channel>\n<title>MacTalk</title>\n<link>https://tgopinath.github.io/MacTalk/appcast.xml</link>\n<!-- ITEMS -->\n</channel>\n</rss>\n')
item = f'''<!-- ITEMS -->
<item>
  <title>Version {version}</title>
  <pubDate>{email.utils.formatdate(usegmt=True)}</pubDate>
  <sparkle:version>{build}</sparkle:version>
  <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
  <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
  <description><![CDATA[<p>{html.escape(notes)}</p>]]></description>
  <enclosure url="https://github.com/tgopinath/MacTalk/releases/download/v{version}/MacTalk-{version}.zip" {signature} type="application/octet-stream"/>
</item>'''
path.write_text(path.read_text().replace("<!-- ITEMS -->", item, 1))
PY

git add appcast.xml
git commit -q -m "Release $VERSION" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git push -q
echo "✓ Released $VERSION (build $BUILD). Installed copies update within an hour."
