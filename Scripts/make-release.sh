#!/bin/bash
# 배포용 디스크 이미지(DMG)를 만든다.
#
#   Scripts/make-release.sh
#
# 결과: dist/MacB-<버전>.dmg 와 dist/MacB-<버전>.dmg.sha256
# 버전은 Resources/Info.plist 의 CFBundleShortVersionString 을 따른다.
# 앱은 arm64 + x86_64 유니버설로 빌드하고, DMG 안에는 MacB.app 과 Applications 바로가기를 넣는다.
# 서명은 build-app.sh 와 같다 (기본 임시 서명, MACB_SIGN_IDENTITY 로 지정 가능).
# 개발 중에 쓰는 build/MacB.app 은 건드리지 않는다.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
DIST="dist"
STAGE="$DIST/stage"
DMG="$DIST/MacB-$VERSION.dmg"

rm -rf "$STAGE" "$DMG" "$DMG.sha256"
mkdir -p "$STAGE"

Scripts/build-app.sh --universal --out "$STAGE"

echo "▸ 확인"
codesign --verify --strict "$STAGE/MacB.app"
lipo -info "$STAGE/MacB.app/Contents/MacOS/MacB"

echo "▸ DMG ($DMG)"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "MacB" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
rm -rf "$STAGE"

(cd "$DIST" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")

echo "✓ $DMG ($(du -h "$DMG" | cut -f1))"
cat "$DMG.sha256"
