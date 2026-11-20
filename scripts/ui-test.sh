#!/bin/zsh
# 화면 자동 테스트: 실제 앱을 띄워 주요 화면 동작을 눌러 보고 결과를 보고한다. (릴리스 전에 실행)
#
#   ./scripts/ui-test.sh            # 앱 빌드 → 테스트
#   ./scripts/ui-test.sh --no-build # build/GodDB.app 그대로 테스트
#   ./scripts/ui-test.sh --keep     # 끝나도 테스트 앱을 닫지 않음 (눈으로 확인)
#   ./scripts/ui-test.sh --no-build connect run   # 일부 시나리오만
#
# 필요: scripts/test-dbs.sh up (로컬 Docker MySQL), 시스템 설정 > 개인정보 보호 > 손쉬운 사용 에서 터미널(또는 실행 앱) 허용
# 실제 접속 목록 · 탭 · 히스토리 · 감사 로그 · 설정은 건드리지 않는다:
#   - 번들 ID 를 바꾼 복사본(local.goddb.app.uitest)으로 실행 → 설정 · 캐시가 따로
#   - GODDB_UI_TEST=1 + GODDB_DATA_DIR → 접속 목록 · 탭 · 기록은 임시 폴더, 감사 로그 · 업데이트 꺼짐
set -e
cd "$(dirname "$0")/.."
BUILD=1; KEEP=0; SCENARIOS=()
for a in "$@"; do
  case $a in
    --no-build) BUILD=0 ;;
    --keep) KEEP=1 ;;
    *) SCENARIOS+=("$a") ;;
  esac
done

WORK="${TMPDIR:-/tmp}goddb-uitest"
APP="$WORK/GodDB.app"
DATA="$WORK/data"
BUNDLE_ID=local.goddb.app.uitest
MYSQL_PORT=33306
MYSQL_PASSWORD=goddbtest

docker exec goddb-mysql-test mysqladmin -uroot -p$MYSQL_PASSWORD ping >/dev/null 2>&1 \
  || { echo "로컬 테스트 MySQL 이 없어요. 먼저 ./scripts/test-dbs.sh up"; exit 2; }

if [[ $BUILD == 1 ]]; then
  echo "▶ 앱 빌드"
  ./scripts/build-app.sh > "$WORK.build.log" 2>&1 || { tail -20 "$WORK.build.log"; exit 1; }
fi

echo "▶ 테스트용 앱 복사본 준비"
pkill -f "$APP/Contents/MacOS/GodDB" 2>/dev/null || true
rm -rf "$WORK"; mkdir -p "$DATA"
cp -R build/GodDB.app "$APP"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1
defaults delete $BUNDLE_ID >/dev/null 2>&1 || true
rm -rf "$HOME/Library/Saved Application State/$BUNDLE_ID.savedState"
defaults write $BUNDLE_ID GodDB.update.mode manual

echo "▶ 테스트 DB · 접속 준비"
docker exec -i goddb-mysql-test mysql --default-character-set=utf8mb4 -uroot -p$MYSQL_PASSWORD shop 2>/dev/null <<'SQL'
DROP TABLE IF EXISTS ui_orders;
CREATE TABLE ui_orders (id INT PRIMARY KEY, customer VARCHAR(50), amount INT, note VARCHAR(100));
INSERT INTO ui_orders VALUES (1,'kim',1200,'first'),(2,'lee',3400,'apple, pie'),(3,'park',560,NULL),
  (4,'choi',7800,'second'),(5,'jung',90,'last');
DROP TABLE IF EXISTS ui_customers;
CREATE TABLE ui_customers (id INT PRIMARY KEY, name VARCHAR(50) NULL COMMENT '고객 이름', grade CHAR(1) NULL);
SQL
# 스키마 비교용 shop_cmp: shop 의 테이블을 그대로 복사한 뒤 두 테이블만 다르게 (컬럼 하나 없음, 코멘트 다름)
CMP_COPY=$(docker exec goddb-mysql-test mysql -uroot -p$MYSQL_PASSWORD -N -e "SELECT CONCAT('CREATE TABLE shop_cmp.', CHAR(96), table_name, CHAR(96), ' LIKE shop.', CHAR(96), table_name, CHAR(96), ';') FROM information_schema.tables WHERE table_schema = 'shop' AND table_type = 'BASE TABLE'" 2>/dev/null)
printf '%s\n' "DROP DATABASE IF EXISTS shop_cmp;" "CREATE DATABASE shop_cmp;" "$CMP_COPY" \
  "ALTER TABLE shop_cmp.ui_orders DROP COLUMN note;" \
  "ALTER TABLE shop_cmp.ui_customers MODIFY name VARCHAR(50) NULL COMMENT '이름';" \
  | docker exec -i goddb-mysql-test mysql --default-character-set=utf8mb4 -uroot -p$MYSQL_PASSWORD 2>/dev/null
cat > "$DATA/profiles.json" <<JSON
[
 {"id":"00000000-0000-4000-8000-0000000000A1","kind":"mysql","name":"UI MySQL","host":"127.0.0.1","port":$MYSQL_PORT,
  "username":"root","database":"shop","useTLS":false,"readOnly":false,"savePassword":false,"environment":"development"},
 {"id":"00000000-0000-4000-8000-0000000000A2","kind":"mysql","name":"UI MySQL Prod","host":"127.0.0.1","port":$MYSQL_PORT,
  "username":"root","database":"shop","useTLS":false,"readOnly":false,"savePassword":false,"environment":"production","group":"UI 그룹"},
 {"id":"00000000-0000-4000-8000-0000000000A3","kind":"mysql","name":"UI 닫힌 포트","host":"127.0.0.1","port":1,
  "username":"root","database":"shop","useTLS":false,"readOnly":false,"savePassword":false,"environment":"development","group":"UI 그룹"}
]
JSON

echo "▶ 앱 실행"
GODDB_UI_TEST=1 GODDB_DATA_DIR="$DATA" GODDB_UI_TEST_PASSWORD=$MYSQL_PASSWORD \
  "$APP/Contents/MacOS/GodDB" -ApplePersistenceIgnoreState YES > "$WORK/app.log" 2>&1 &
APP_PID=$!
sleep 4

echo "▶ 시나리오 실행"
swiftc -O -o "$WORK/uitest" scripts/ui-test/UITest.swift
set +e
"$WORK/uitest" $APP_PID "${SCENARIOS[@]}" | tee "$WORK/report.txt"
RESULT=${pipestatus[1]}
set -e

if [[ $KEEP == 0 ]]; then
  kill $APP_PID 2>/dev/null || true
  docker exec goddb-mysql-test mysql -uroot -p$MYSQL_PASSWORD shop -e "DROP TABLE IF EXISTS ui_orders, ui_customers; DROP DATABASE IF EXISTS shop_cmp" 2>/dev/null || true
fi
echo
echo "보고서: $WORK/report.txt"
exit $RESULT
