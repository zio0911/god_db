#!/bin/zsh
# 갓디비.app 을 빌드해서 배포용 DMG 로 만든다.
#   ./scripts/make-dmg.sh        → build/GodDB-<버전>.dmg
# DMG 를 열면 갓디비.app 과 Applications 바로가기가 보이고, 끌어다 놓으면 설치된다.
set -e
cd "$(dirname "$0")/.."

./scripts/build-app.sh

APP="build/갓디비.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
STAGE="build/dmg"
DMG="build/GodDB-$VERSION.dmg"

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/읽어주세요.txt" <<TXT
갓디비 $VERSION

설치: 갓디비.app 을 Applications 폴더로 끌어다 놓으세요.

처음 실행할 때 "확인되지 않은 개발자" 경고가 나오면:
  Finder > 응용 프로그램 > 갓디비 를 우클릭 > 열기 > 열기
  (또는 터미널: xattr -dr com.apple.quarantine /Applications/갓디비.app)

SQL Server 를 쓰려면 FreeTDS 가 필요해요:
  brew install freetds

로컬 AI 쿼리 튜닝은 Ollama 가 있으면 동작해요: https://ollama.com
소스: https://github.com/zio0911/god_db (MIT)
TXT

hdiutil create -volname "GodDB $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
echo "완료: $(pwd)/$DMG ($(du -h "$DMG" | cut -f1))"
