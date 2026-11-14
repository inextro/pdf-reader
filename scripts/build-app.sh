#!/usr/bin/env bash
# PaperMark.app 번들(Apple Silicon + Intel 유니버설)을 build/에 만든다.
#   --library  PaperMark 대신 라이브러리 앱 Quillo.app을 만든다(Resources/PaperLibrary/의 Info.plist와 아이콘).
#              SwiftPM 제품과 실행 파일 이름은 예전 이름 PaperLibrary 그대로다. 앱 파일 이름만 Quillo다.
#   --install  ~/Applications 에 설치한다.
#   --library면 Chrome 확장(Extension/Chrome)을 앱의 Contents/Resources/ChromeExtension에 넣는다. 앱이 켤 때 Application Support로 복사해 둔다.
#   --zip      배포용 build/<앱>-<버전>.zip 을 만든다(GitHub Releases에 올리는 파일).
#   --dev      확인용: arm64만, debug로 빌드한다(빠르고 CPU를 덜 쓴다). 배포에는 쓰지 않는다.
set -euo pipefail
cd "$(dirname "$0")/.."

NAME=PaperMark
PRODUCT=PaperMark
RES=Resources
CONFIG=release
ARCHS=(--arch arm64 --arch x86_64)
for arg in "$@"; do
  if [ "$arg" = --library ]; then NAME=Quillo; PRODUCT=PaperLibrary; RES=Resources/PaperLibrary; fi
  if [ "$arg" = --dev ]; then CONFIG=debug; ARCHS=(--arch arm64); fi
done

swift build -c "$CONFIG" --product "$PRODUCT" "${ARCHS[@]}"
BIN="$(swift build -c "$CONFIG" "${ARCHS[@]}" --show-bin-path)/$PRODUCT"
APP="build/$NAME.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$PRODUCT"
# SwiftPM은 링크한 SDK 버전을 최소 버전(14.0)으로 적어 넣는다. 그러면 새 macOS가 앱을 옛 SDK용으로 보고
# 호환 모양(평평한 신호등, 옛 제목 표시줄과 툴바)으로 그리므로, 실제로 빌드한 SDK 버전으로 고쳐 쓴다.
MIN_OS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$RES/Info.plist")"
vtool -set-build-version macos "$MIN_OS" "$(xcrun --sdk macosx --show-sdk-version)" -replace \
  -output "$APP/Contents/MacOS/$PRODUCT" "$APP/Contents/MacOS/$PRODUCT" 2>/dev/null
cp "$RES/Info.plist" "$APP/Contents/Info.plist"
cp "$RES/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
if [ "$NAME" = Quillo ]; then cp -R Extension/Chrome "$APP/Contents/Resources/ChromeExtension"; fi
codesign --force --sign - "$APP"
echo "built: $APP ($(lipo -archs "$APP/Contents/MacOS/$PRODUCT"))"

for arg in "$@"; do
  case "$arg" in
    --install)
      mkdir -p "$HOME/Applications"
      rm -rf "$HOME/Applications/$NAME.app"
      # 이름을 바꾸기 전에 설치한 같은 앱(bundle ID가 같다)을 치운다.
      if [ "$NAME" = Quillo ]; then rm -rf "$HOME/Applications/PaperLibrary.app"; fi
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
      # 1.0.4까지의 PaperLibrary는 PaperLibrary-<버전>.zip 안의 PaperLibrary.app만 받는다. 같은 앱을 그 이름으로도 묶는다.
      # 받은 앱은 처음 켤 때 스스로 Quillo.app으로 이름을 바꾼다(UpdateController.adoptCurrentName).
      if [ "$NAME" = Quillo ]; then
        LEGACY="build/legacy/PaperLibrary.app"
        rm -rf build/legacy
        mkdir -p build/legacy
        cp -R "$APP" "$LEGACY"
        LEGACY_ZIP="build/PaperLibrary-$VERSION.zip"
        rm -f "$LEGACY_ZIP"
        ditto -c -k --keepParent "$LEGACY" "$LEGACY_ZIP"
        echo "zipped: $LEGACY_ZIP"
      fi
      ;;
  esac
done
