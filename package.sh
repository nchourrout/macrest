#!/usr/bin/env bash
# Package a built MacRest.app for download: a drag-to-Applications disk
# image, a zip of the same bundle (for scripted installs), and a SHA-256 for
# each. Usage: ./package.sh <path/to/MacRest.app> <version> [out dir]
set -euo pipefail

APP="$1"
VERSION="$2"
OUT="${3:-$(dirname "$APP")}"
NAME="MacRest-${VERSION}"
mkdir -p "$OUT"

# The disk image: the app beside an Applications shortcut, so installing is
# one drag.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/MacRest.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$OUT/$NAME.dmg"
hdiutil create -volname "MacRest" -srcfolder "$STAGE" -fs APFS -format UDZO -ov -quiet "$OUT/$NAME.dmg"

# ditto keeps the bundle's symlinks, permissions and signature intact, which
# plain zip does not.
ditto -c -k --keepParent "$APP" "$OUT/$NAME.zip"

cd "$OUT"
for f in "$NAME.dmg" "$NAME.zip"; do shasum -a 256 "$f" > "$f.sha256"; done
echo "packaged $OUT/$NAME.dmg and $OUT/$NAME.zip"
