#!/usr/bin/env bash
# GitHub Release를 만든다. 버전은 Resources/Info.plist의 CFBundleShortVersionString.
# 배포 전에: 1) Info.plist 버전을 올리고 2) README "Release notes"에 "### <버전>" 칸을 쓰고 3) 커밋·push.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
TAG="v$VERSION"

fail() { echo "error: $*" >&2; exit 1; }

[[ -z "$(git status --porcelain)" ]] || fail "커밋하지 않은 변경이 있다"
git fetch -q origin
[[ "$(git rev-parse HEAD)" == "$(git rev-parse '@{u}')" ]] || fail "push하지 않은 커밋이 있거나 원격이 앞서 있다"
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && fail "태그 $TAG 가 이미 있다"

# README의 "### <버전>" 칸부터 다음 "### " 또는 "## " 전까지를 Release 설명으로 쓴다.
NOTES="$(awk -v v="### $VERSION" '
  $0 == v { on = 1; next }
  on && /^##/ { exit }
  on { print }
' README.md | sed -e '/./,$!d')"
[[ -n "$NOTES" ]] || fail "README Release notes에 '### $VERSION' 칸이 없다"

./scripts/build-app.sh --zip
ZIP="build/PaperMark-$VERSION.zip"

git tag -a "$TAG" -m "PaperMark $VERSION"
git push -q origin "$TAG"
gh release create "$TAG" "$ZIP" --title "PaperMark $VERSION" --notes "$NOTES

---
Download \`PaperMark-$VERSION.zip\`, unzip, and move PaperMark.app to Applications.
The app is not notarized: on first launch, open **System Settings → Privacy & Security** and click **Open Anyway**."
echo "released: $TAG"
