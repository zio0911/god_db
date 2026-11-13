#!/bin/zsh
# GodDB.app 을 빌드해서 배포용 DMG 로 만든다.
#   ./scripts/make-dmg.sh        → build/GodDB-<버전>.dmg
# DMG 를 열면 GodDB.app 과 Applications 바로가기가 보이고, 끌어다 놓으면 설치된다.
set -e
cd "$(dirname "$0")/.."

# build-app.sh 와 같은 규칙으로 서명 인증서를 정해 넘긴다 (DMG 서명·공증에도 씀)
if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"')
fi
[[ -z "$SIGN_IDENTITY" ]] && SIGN_IDENTITY="-"
export SIGN_IDENTITY

./scripts/build-app.sh

# 서명은 iCloud 밖에서 했으므로, DMG 도 그 사본으로 iCloud 밖에서 만든다.
WORK="${TMPDIR:-/tmp}/goddb-build"
APP="$WORK/GodDB.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
STAGE="$WORK/dmg"
DMG="build/GodDB-$VERSION.dmg"

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/GodDB.app"
ln -s /Applications "$STAGE/Applications"
# DMG 를 마운트했을 때 디스크 아이콘도 앱 아이콘으로
cp Resources/AppIcon.icns "$STAGE/.VolumeIcon.icns"
if [[ "$SIGN_IDENTITY" == "-" || -z "$SIGN_IDENTITY" ]]; then
  FIRST_RUN='처음 실행할 때 "확인되지 않은 개발자" 경고가 나오면:
  시스템 설정 > 개인정보 보호 및 보안 > "그래도 열기"'
else
  FIRST_RUN="Apple 공증을 받은 앱이라 바로 열려요."
fi
cat > "$STAGE/읽어주세요.txt" <<TXT
GodDB $VERSION

설치: GodDB.app 을 Applications 폴더로 끌어다 놓으세요.

$FIRST_RUN

로컬 AI 쿼리 튜닝은 Ollama 가 있으면 동작해요: https://ollama.com
소스: https://github.com/zio0911/god_db (MIT)
TXT

# 읽기/쓰기 이미지로 만들어 볼륨 아이콘 표시를 켠 뒤 압축 이미지로 변환
RW="$WORK/GodDB-rw.dmg"
rm -f "$RW"
hdiutil create -volname "GodDB $VERSION" -srcfolder "$STAGE" -ov -format UDRW "$RW" >/dev/null 2>&1
MNT=$(mktemp -d)
hdiutil attach "$RW" -nobrowse -mountpoint "$MNT" >/dev/null 2>&1
if command -v SetFile >/dev/null 2>&1; then SetFile -a C "$MNT"; else xattr -wx com.apple.FinderInfo "0000000000000000040000000000000000000000000000000000000000000000" "$MNT"; fi
hdiutil detach "$MNT" >/dev/null 2>&1
hdiutil convert "$RW" -format UDZO -ov -o "$DMG" >/dev/null 2>&1
rm -f "$RW"; rmdir "$MNT" 2>/dev/null || true
rm -rf "$STAGE"

# 정식 서명이면 DMG 도 서명하고 Apple 공증 → 공증 결과를 DMG 에 붙인다(stapler).
# 공증 암호는 키체인 프로필에만 둔다: xcrun notarytool store-credentials goddb --apple-id <ID> --team-id <팀ID>
NOTARY_PROFILE="${NOTARY_PROFILE:-goddb}"
if [[ "$SIGN_IDENTITY" != "-" && -n "$SIGN_IDENTITY" ]]; then
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
  if [[ "$SKIP_NOTARIZE" == "1" ]]; then
    echo "공증: 건너뜀 (SKIP_NOTARIZE=1)"
  elif xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    echo "공증: Apple 에 제출하고 결과를 기다려요 (보통 몇 분)…"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
    spctl -a -t open --context context:primary-signature -vv "$DMG"
  else
    echo "공증: 키체인 프로필 '$NOTARY_PROFILE' 이 없어 건너뜀 — xcrun notarytool store-credentials $NOTARY_PROFILE 로 먼저 저장하세요" >&2
  fi
fi
echo "완료: $(pwd)/$DMG ($(du -h "$DMG" | cut -f1))"
