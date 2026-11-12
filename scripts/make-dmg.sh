#!/bin/zsh
# GodDB.app 을 빌드해서 배포용 DMG 로 만든다.
#   ./scripts/make-dmg.sh        → build/GodDB-<버전>.dmg
# DMG 를 열면 GodDB.app 과 Applications 바로가기가 보이고, 끌어다 놓으면 설치된다.
set -e
cd "$(dirname "$0")/.."

./scripts/build-app.sh

APP="build/GodDB.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
STAGE="build/dmg"
DMG="build/GodDB-$VERSION.dmg"

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
# DMG 를 마운트했을 때 디스크 아이콘도 앱 아이콘으로
cp Resources/AppIcon.icns "$STAGE/.VolumeIcon.icns"
cat > "$STAGE/읽어주세요.txt" <<TXT
GodDB $VERSION

설치: GodDB.app 을 Applications 폴더로 끌어다 놓으세요.

처음 실행할 때 "확인되지 않은 개발자" 경고가 나오면:
  Finder > 응용 프로그램 > GodDB 를 우클릭 > 열기 > 열기
  (또는 터미널: xattr -dr com.apple.quarantine /Applications/GodDB.app)

SQL Server 를 쓰려면 FreeTDS 가 필요해요:
  brew install freetds

로컬 AI 쿼리 튜닝은 Ollama 가 있으면 동작해요: https://ollama.com
소스: https://github.com/zio0911/god_db (MIT)
TXT

# 읽기/쓰기 이미지로 만들어 볼륨 아이콘 표시를 켠 뒤 압축 이미지로 변환
RW="build/GodDB-rw.dmg"
rm -f "$RW"
hdiutil create -volname "GodDB $VERSION" -srcfolder "$STAGE" -ov -format UDRW "$RW" >/dev/null 2>&1
MNT=$(mktemp -d)
hdiutil attach "$RW" -nobrowse -mountpoint "$MNT" >/dev/null 2>&1
if command -v SetFile >/dev/null 2>&1; then SetFile -a C "$MNT"; else xattr -wx com.apple.FinderInfo "0000000000000000040000000000000000000000000000000000000000000000" "$MNT"; fi
hdiutil detach "$MNT" >/dev/null 2>&1
hdiutil convert "$RW" -format UDZO -ov -o "$DMG" >/dev/null 2>&1
rm -f "$RW"; rmdir "$MNT" 2>/dev/null || true
rm -rf "$STAGE"
echo "완료: $(pwd)/$DMG ($(du -h "$DMG" | cut -f1))"
