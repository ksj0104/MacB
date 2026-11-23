#!/bin/bash
# MacB.app 번들을 만든다. Xcode 없이 Command Line Tools만 있으면 된다.
#
#   Scripts/build-app.sh             build/MacB.app 생성
#   Scripts/build-app.sh --run       만든 뒤 실행 (실행 중이던 MacB는 종료)
#   Scripts/build-app.sh --install   /Applications 에 복사 (--run 과 함께 쓰면 거기서 실행)
#   Scripts/build-app.sh --universal  arm64 + x86_64 유니버설 바이너리로 빌드
#   Scripts/build-app.sh --out DIR    build/ 대신 DIR/MacB.app 에 만든다 (배포용, Scripts/make-release.sh 참고)
#
# 서명: 기본은 임시(ad-hoc) 서명이다. 이 경우 다시 빌드할 때마다 macOS가 다른 앱으로 보아서
# 화면 기록·손쉬운 사용 권한을 다시 허용해야 한다. 키체인에 코드 서명 인증서를 만들어 두고
# MACB_SIGN_IDENTITY="인증서 이름" 으로 넘기면 권한이 유지된다. (README 참고)
set -euo pipefail
cd "$(dirname "$0")/.."

INSTALL=0
RUN=0
UNIVERSAL=0
OUT="build"
while [ $# -gt 0 ]; do
    case "$1" in
        --install) INSTALL=1 ;;
        --run) RUN=1 ;;
        --universal) UNIVERSAL=1 ;;
        --out)
            [ $# -ge 2 ] || { echo "--out 에는 폴더를 지정해야 합니다" >&2; exit 2; }
            OUT="$2"; shift ;;
        *) echo "알 수 없는 옵션: $1" >&2; exit 2 ;;
    esac
    shift
done

if [ "$UNIVERSAL" = 1 ]; then
    echo "▸ 빌드 (release, arm64 + x86_64)"
    BINS=()
    for ARCH in arm64 x86_64; do
        SCRATCH=".build-release-$ARCH"
        swift build -c release --product MacB --triple "$ARCH-apple-macosx14.0" --scratch-path "$SCRATCH"
        BINS+=("$(swift build -c release --triple "$ARCH-apple-macosx14.0" --scratch-path "$SCRATCH" --show-bin-path)/MacB")
    done
    mkdir -p "$OUT"
    BIN="$OUT/MacB-universal"
    lipo -create "${BINS[@]}" -output "$BIN"
else
    echo "▸ 빌드 (release)"
    swift build -c release --product MacB
    BIN="$(swift build -c release --show-bin-path)/MacB"
fi

APP="$OUT/MacB.app"
mkdir -p "$OUT"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MacB"
cp Resources/Info.plist "$APP/Contents/Info.plist"

echo "▸ 아이콘"
ICONSET="$OUT/AppIcon.iconset"
rm -rf "$ICONSET"
"$BIN" --make-icon "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

IDENTITY="${MACB_SIGN_IDENTITY:--}"
if [ "$IDENTITY" = "-" ]; then
    echo "▸ 서명 (임시 서명)"
else
    echo "▸ 서명 ($IDENTITY)"
fi
codesign --force --sign "$IDENTITY" "$APP"
if [ "$UNIVERSAL" = 1 ]; then rm -f "$BIN"; fi

TARGET="$APP"
if [ "$INSTALL" = 1 ]; then
    TARGET="/Applications/MacB.app"
    echo "▸ 설치: $TARGET"
    pkill -x MacB 2>/dev/null || true
    rm -rf "$TARGET"
    cp -R "$APP" "$TARGET"
fi

if [ "$RUN" = 1 ]; then
    echo "▸ 실행"
    pkill -x MacB 2>/dev/null || true
    # 이전 인스턴스가 완전히 내려간 뒤에 띄운다.
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        pgrep -x MacB >/dev/null 2>&1 || break
        sleep 0.2
    done
    open "$TARGET"
fi

echo "✓ $TARGET"
if [ "$IDENTITY" = "-" ]; then
    echo "  (임시 서명: 권한을 이미 허용했더라도 다시 빌드하면 한 번 더 허용해야 합니다)"
fi
