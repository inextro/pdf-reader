#!/usr/bin/env bash
# GitHub Release를 만든다. Quillo(예전 PaperLibrary, PDF 리더 PaperMark를 품었다)의 zip을 올린다.
# 버전은 Resources/PaperLibrary/Info.plist의 CFBundleShortVersionString이다.
# 배포 전에: 1) Info.plist 버전(CFBundleShortVersionString, CFBundleVersion)을 올리고 2) CHANGELOG.md 맨 위에 "## <버전>" 칸을 쓰고 3) 커밋·push.
# 앱의 업데이트 확인은 이름이 <자기 이름>-<버전>.zip인 파일만 받는다.
# PaperLibrary-<버전>.zip은 1.0.4 이하 PaperLibrary가 Quillo로 업데이트하는 데 쓴다(내용은 Quillo와 같다).
# PaperMark는 1.0.4가 마지막이라 zip을 올리지 않는다. PaperMark 1.0.4는 새 릴리스 노트를 보여 주고 Install을 누르면 릴리스 페이지를 연다.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/PaperLibrary/Info.plist)"
TAG="v$VERSION"

fail() { echo "error: $*" >&2; exit 1; }


[[ -z "$(git status --porcelain)" ]] || fail "커밋하지 않은 변경이 있다"
git fetch -q origin
[[ "$(git rev-parse HEAD)" == "$(git rev-parse '@{u}')" ]] || fail "push하지 않은 커밋이 있거나 원격이 앞서 있다"
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && fail "태그 $TAG 가 이미 있다"

# CHANGELOG.md의 "## <버전>" 칸부터 다음 "## " 전까지를 Release 설명으로 쓴다.
NOTES="$(awk -v v="## $VERSION" '
  $0 == v { on = 1; next }
  on && /^##/ { exit }
  on { print }
' CHANGELOG.md | sed -e '/./,$!d')"
[[ -n "$NOTES" ]] || fail "CHANGELOG.md에 '## $VERSION' 칸이 없다"

./scripts/build-app.sh --zip
LIBRARY_ZIP="build/Quillo-$VERSION.zip"
LEGACY_ZIP="build/PaperLibrary-$VERSION.zip"
[[ -f "$LIBRARY_ZIP" && -f "$LEGACY_ZIP" ]] || fail "zip을 만들지 못했다"

git tag -a "$TAG" -m "Quillo $VERSION"
git push -q origin "$TAG"
gh release create "$TAG" "$LIBRARY_ZIP" "$LEGACY_ZIP" --title "Quillo $VERSION" --notes "$NOTES

---
- \`Quillo-$VERSION.zip\`: the paper library with its built-in PDF reader (formerly PaperLibrary and PaperMark). Its Chrome extension is inside the app: choose **Quillo → Install Chrome Extension…**.
- \`PaperLibrary-$VERSION.zip\`: the same Quillo app, for PaperLibrary 1.0.4 and earlier to update in place. Download Quillo instead.

Unzip it and move Quillo.app to Applications. The app is not notarized: on first launch, open **System Settings → Privacy & Security** and click **Open Anyway**."
echo "released: $TAG"
