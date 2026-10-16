#!/usr/bin/env bash
# PaperMark.app 번들(Apple Silicon + Intel 유니버설)을 build/에 만든다.
#   --install  ~/Applications 에 설치한다.
#   --zip      배포용 build/PaperMark-<버전>.zip 을 만든다(GitHub Releases에 올리는 파일).
set -euo pipefail
cd "$(dirname "$0")/.."

ARCHS=(--arch arm64 --arch x86_64)
swift build -c release --product PaperMark "${ARCHS[@]}"
BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path)/PaperMark"
APP="build/PaperMark.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/PaperMark"
# SwiftPM은 링크한 SDK 버전을 최소 버전(14.0)으로 적어 넣는다. 그러면 새 macOS가 앱을 옛 SDK용으로 보고
# 호환 모양(평평한 신호등, 옛 제목 표시줄과 툴바)으로 그리므로, 실제로 빌드한 SDK 버전으로 고쳐 쓴다.
MIN_OS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Resources/Info.plist)"
vtool -set-build-version macos "$MIN_OS" "$(xcrun --sdk macosx --show-sdk-version)" -replace \
  -output "$APP/Contents/MacOS/PaperMark" "$APP/Contents/MacOS/PaperMark" 2>/dev/null
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"
echo "built: $APP ($(lipo -archs "$APP/Contents/MacOS/PaperMark"))"

for arg in "$@"; do
  case "$arg" in
    --install)
      mkdir -p "$HOME/Applications"
      rm -rf "$HOME/Applications/PaperMark.app"
      cp -R "$APP" "$HOME/Applications/"
      /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
        -f "$HOME/Applications/PaperMark.app"
      echo "installed: $HOME/Applications/PaperMark.app"
      ;;
    --zip)
      VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
      ZIP="build/PaperMark-$VERSION.zip"
      rm -f "$ZIP"
      # ditto는 서명과 확장 속성을 보존한 채 Finder 압축과 같은 형식으로 묶는다.
      ditto -c -k --keepParent "$APP" "$ZIP"
      echo "zipped: $ZIP"
      ;;
  esac
done
