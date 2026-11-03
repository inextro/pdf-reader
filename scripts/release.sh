#!/usr/bin/env bash
# GitHub Release를 만든다. PaperMark와 PaperLibrary의 zip을 같은 릴리스에 올린다.
# 버전은 Resources/Info.plist의 CFBundleShortVersionString이고, PaperLibrary(Resources/PaperLibrary/Info.plist)도 같은 버전이어야 한다.
# 배포 전에: 1) 두 Info.plist 버전을 올리고 2) CHANGELOG.md 맨 위에 "## <버전>" 칸을 쓰고 3) 커밋·push.
# PaperMark의 업데이트 확인은 이름이 PaperMark-<버전>.zip인 파일만 받으므로 PaperLibrary zip이 같이 있어도 된다.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
TAG="v$VERSION"

fail() { echo "error: $*" >&2; exit 1; }

LIBRARY_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/PaperLibrary/Info.plist)"
[[ "$LIBRARY_VERSION" == "$VERSION" ]] || fail "PaperLibrary 버전($LIBRARY_VERSION)이 PaperMark 버전($VERSION)과 다르다"

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
./scripts/build-app.sh --library --zip
ZIP="build/PaperMark-$VERSION.zip"
LIBRARY_ZIP="build/PaperLibrary-$VERSION.zip"
[[ -f "$ZIP" && -f "$LIBRARY_ZIP" ]] || fail "zip을 만들지 못했다"

git tag -a "$TAG" -m "PaperMark $VERSION"
git push -q origin "$TAG"
gh release create "$TAG" "$ZIP" "$LIBRARY_ZIP" --title "PaperMark $VERSION" --notes "$NOTES

---
- \`PaperMark-$VERSION.zip\`: the PDF reader.
- \`PaperLibrary-$VERSION.zip\`: the paper library. It opens PDFs in PaperMark, so install both. Its Chrome extension is inside the app: choose **PaperLibrary → Install Chrome Extension…**.

Unzip each file and move the app to Applications. The apps are not notarized: on first launch, open **System Settings → Privacy & Security** and click **Open Anyway**."
echo "released: $TAG"
