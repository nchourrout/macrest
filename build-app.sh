#!/usr/bin/env bash
# Build MacRest.app and install it at $1 (default ~/Applications/MacRest.app).
#
# The playbook runs this on every pass, so it is idempotent on its own: a hash
# of everything that goes into the bundle is stamped inside it, and a tree that
# hashes the same prints "unchanged" and builds nothing. A release build takes
# a minute or two; a run that touches nothing here should not pay for one.
#
# Command Line Tools are enough, no Xcode: see Package.swift for what that
# rules out.

set -euo pipefail

cd "$(dirname "$0")"
DEST="${1:-$HOME/Applications/MacRest.app}"
# The marketing version: the release workflow passes the tag (v1.2.0 -> 1.2.0);
# a local build describes itself from git ("0.1.0-2-gf299038": two commits
# after 0.1.0), so its About panel says what it is built from.
VERSION="${MACREST_VERSION:-$(git describe --tags --always 2>/dev/null | sed 's/^v//')}"
VERSION="${VERSION:-dev}"

HASH=$(
  { echo "$VERSION"
    cat Package.swift build-app.sh render-icon.swift
    find Sources -type f -name '*.swift' -print0 | sort -z | xargs -0 cat
  } | shasum -a 256 | cut -d' ' -f1
)
STAMP="$DEST/Contents/Resources/source-hash"
if [[ -f "$STAMP" && "$(cat "$STAMP")" == "$HASH" ]]; then
  echo "unchanged"
  exit 0
fi

swift build -c release --product MacRest
BIN="$(swift build -c release --show-bin-path)/MacRest"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
APP="$WORK/MacRest.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MacRest"

# LSUIElement starts the app as a menu bar app, with no Dock icon flashing
# up at login. It takes a Dock icon at run time while its window is open, or
# for good when the menu bar icon is turned off (AppDelegate).
ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
swift render-icon.swift "$WORK/icon.png"
for s in 16 32 128 256 512; do
  sips -z "$s" "$s" "$WORK/icon.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) "$WORK/icon.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns -o "$APP/Contents/Resources/AppIcon.icns" "$ICONSET"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                 <string>MacRest</string>
    <key>CFBundleDisplayName</key>          <string>MacRest</string>
    <key>CFBundleIdentifier</key>           <string>com.nchourrout.macrest</string>
    <key>CFBundleExecutable</key>           <string>MacRest</string>
    <key>CFBundleIconFile</key>             <string>AppIcon</string>
    <key>CFBundlePackageType</key>          <string>APPL</string>
    <key>CFBundleShortVersionString</key>   <string>${VERSION}</string>
    <key>CFBundleVersion</key>              <string>${HASH:0:12}</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>LSMinimumSystemVersion</key>       <string>26.0</string>
    <key>LSUIElement</key>                  <true/>
    <key>NSPrincipalClass</key>             <string>NSApplication</string>
</dict>
</plist>
EOF
echo "$HASH" > "$APP/Contents/Resources/source-hash"

# Ad-hoc signature over the whole bundle, so it is sealed with its Info.plist
# and resources: an unsealed bundle gets a generic identity in notification
# settings.
codesign --force --sign - "$APP"

mkdir -p "$(dirname "$DEST")"
rm -rf "$DEST"
mv "$APP" "$DEST"
echo "installed $DEST"
