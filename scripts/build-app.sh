#!/usr/bin/env bash
# PaperMark.app 번들(Apple Silicon + Intel 유니버설)을 build/에 만든다.
#   --library  PaperMark 대신 라이브러리 앱 PaperLibrary.app을 만든다(Resources/PaperLibrary/의 Info.plist와 아이콘).
#   --install  ~/Applications 에 설치한다.
#   --zip      배포용 build/<앱>-<버전>.zip 을 만든다(GitHub Releases에 올리는 파일).
set -euo pipefail
cd "$(dirname "$0")/.."

NAME=PaperMark
RES=Resources
for arg in "$@"; do
  if [ "$arg" = --library ]; then NAME=PaperLibrary; RES=Resources/PaperLibrary; fi
done

ARCHS=(--arch arm64 --arch x86_64)
swift build -c release --product "$NAME" "${ARCHS[@]}"
BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path)/$NAME"
APP="build/$NAME.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$NAME"
# SwiftPM은 링크한 SDK 버전을 최소 버전(14.0)으로 적어 넣는다. 그러면 새 macOS가 앱을 옛 SDK용으로 보고
# 호환 모양(평평한 신호등, 옛 제목 표시줄과 툴바)으로 그리므로, 실제로 빌드한 SDK 버전으로 고쳐 쓴다.
MIN_OS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$RES/Info.plist")"
vtool -set-build-version macos "$MIN_OS" "$(xcrun --sdk macosx --show-sdk-version)" -replace \
  -output "$APP/Contents/MacOS/$NAME" "$APP/Contents/MacOS/$NAME" 2>/dev/null
cp "$RES/Info.plist" "$APP/Contents/Info.plist"
cp "$RES/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"
echo "built: $APP ($(lipo -archs "$APP/Contents/MacOS/$NAME"))"

for arg in "$@"; do
  case "$arg" in
    --install)
      mkdir -p "$HOME/Applications"
      rm -rf "$HOME/Applications/$NAME.app"
      cp -R "$APP" "$HOME/Applications/"
      /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
        -f "$HOME/Applications/$NAME.app"
      echo "installed: $HOME/Applications/$NAME.app"
      ;;
    --zip)
      VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$RES/Info.plist")"
      ZIP="build/$NAME-$VERSION.zip"
      rm -f "$ZIP"
      # ditto는 서명과 확장 속성을 보존한 채 Finder 압축과 같은 형식으로 묶는다.
      ditto -c -k --keepParent "$APP" "$ZIP"
      echo "zipped: $ZIP"
      ;;
  esac
done
