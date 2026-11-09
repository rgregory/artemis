#!/bin/bash
# Builds Artemis.app into ./build. Usage: ./build.sh [run|install]
# Artemis is deliberately NOT sandboxed: it has to read other apps' signatures.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/Artemis"
APP="build/Artemis.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Artemis"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - --options runtime "$APP"
echo "Built $APP"

case "${1:-}" in
  run)     open "$APP" ;;
  install) rm -rf /Applications/Artemis.app && cp -R "$APP" /Applications/ && open /Applications/Artemis.app ;;
esac
