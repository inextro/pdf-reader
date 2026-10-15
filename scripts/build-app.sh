#!/usr/bin/env bash
# PaperMark.app 번들을 build/에 만든다. --install 을 주면 ~/Applications 에 설치한다.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product PaperMark
BIN="$(swift build -c release --show-bin-path)/PaperMark"
APP="build/PaperMark.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/PaperMark"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
echo "built: $APP"

if [[ "${1:-}" == "--install" ]]; then
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/PaperMark.app"
  cp -R "$APP" "$HOME/Applications/"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$HOME/Applications/PaperMark.app"
  echo "installed: $HOME/Applications/PaperMark.app"
fi
