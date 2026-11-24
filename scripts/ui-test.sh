#!/bin/zsh
# 화면 자동 테스트: 실제 앱을 띄워 주요 화면 동작을 눌러 보고 결과를 보고한다. (릴리스 전에 실행)
#
#   ./scripts/ui-test.sh            # 앱 빌드 → 테스트
#   ./scripts/ui-test.sh --no-build # build/app.noindex/GodDB.app 그대로 테스트
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
# PostgreSQL · SQL Server 도 같은 비밀번호로 붙는다 (앱은 테스트 비밀번호 하나만 쓴다)
PG_PORT=35432
MSSQL_PORT=31433
MSSQL_SA_PASSWORD='GodDb_test1!'
pg_sql() { docker exec -i -e PGOPTIONS='-c client_min_messages=warning' goddb-pg-test psql -q -v ON_ERROR_STOP=1 -U postgres -d shop >/dev/null; }
mssql_sql() { docker exec -i goddb-mssql-test /opt/mssql-tools18/bin/sqlcmd -C -b -f 65001 -S localhost -U sa -P "$MSSQL_SA_PASSWORD" >/dev/null; }

docker exec goddb-mysql-test mysqladmin -uroot -p$MYSQL_PASSWORD ping >/dev/null 2>&1 \
  || { echo "로컬 테스트 MySQL 이 없어요. 먼저 ./scripts/test-dbs.sh up"; exit 2; }
docker exec goddb-pg-test pg_isready -U postgres >/dev/null 2>&1 \
  || { echo "로컬 테스트 PostgreSQL 이 없어요. 먼저 ./scripts/test-dbs.sh up"; exit 2; }
echo "SELECT 1" | mssql_sql 2>/dev/null \
  || { echo "로컬 테스트 SQL Server 가 없어요. 먼저 ./scripts/test-dbs.sh up"; exit 2; }

if [[ $BUILD == 1 ]]; then
  echo "▶ 앱 빌드"
  ./scripts/build-app.sh > "$WORK.build.log" 2>&1 || { tail -20 "$WORK.build.log"; exit 1; }
fi

echo "▶ 테스트용 앱 복사본 준비"
pkill -f "$APP/Contents/MacOS/GodDB" 2>/dev/null || true
rm -rf "$WORK"; mkdir -p "$DATA"
cp -R build/app.noindex/GodDB.app "$APP"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1
defaults delete $BUNDLE_ID >/dev/null 2>&1 || true
rm -rf "$HOME/Library/Saved Application State/$BUNDLE_ID.savedState"
defaults write $BUNDLE_ID GodDB.update.mode manual

echo "▶ 테스트 DB · 접속 준비"
docker exec -i goddb-mysql-test mysql --default-character-set=utf8mb4 -uroot -p$MYSQL_PASSWORD shop 2>/dev/null <<'SQL'
DROP TABLE IF EXISTS ui_orders;
DROP TABLE IF EXISTS ui_customers;
DROP TABLE IF EXISTS ui_students;
DROP TABLE IF EXISTS ui_schools;
DROP TABLE IF EXISTS ui_points;
DROP TABLE IF EXISTS ui_members;
CREATE TABLE ui_customers (id INT PRIMARY KEY, name VARCHAR(50) NULL COMMENT '고객 이름', grade VARCHAR(10));
INSERT INTO ui_customers VALUES (10,'kim','gold'),(20,'lee','silver'),(30,'park','bronze');
CREATE TABLE ui_orders (id INT PRIMARY KEY, customer VARCHAR(50), amount INT, note VARCHAR(100),
  customer_id INT NULL, meta JSON NULL,
  CONSTRAINT fk_ui_orders_customer FOREIGN KEY (customer_id) REFERENCES ui_customers(id));
INSERT INTO ui_orders VALUES (1,'kim',1200,'first',10,'{"channel":"web","tags":["new","gift"],"coupon":{"code":"A-77","rate":0.1}}'),
  (2,'lee',3400,'apple, pie',20,'{"channel":"app"}'),(3,'park',560,NULL,30,NULL),
  (4,'choi',7800,'second',10,'{"channel":"web","tags":[]}'),(5,'jung',90,'last',NULL,NULL);
CREATE TABLE ui_schools (id INT PRIMARY KEY, name VARCHAR(50) COMMENT '학교 이름') COMMENT '학교';
INSERT INTO ui_schools VALUES (1,'한빛초등학교'),(2,'푸른중학교');
CREATE TABLE ui_students (id INT PRIMARY KEY, name VARCHAR(50) COMMENT '학생 이름',
  school_id INT COMMENT '학교 번호', grade_level INT COMMENT '학년') COMMENT '학생';
INSERT INTO ui_students VALUES (1,'student1',1,3),(2,'student2',2,1);
-- AI 데이터 찾기: 코멘트 없는 영어 약어 테이블 (한글 질문 → 약어 컬럼)
DROP TABLE IF EXISTS tb_mbr_info;
DROP TABLE IF EXISTS tb_stdnt_info;
CREATE TABLE tb_mbr_info (mbr_no INT PRIMARY KEY, mbr_nm VARCHAR(50), mbr_tel_no VARCHAR(20), reg_dt DATE);
INSERT INTO tb_mbr_info VALUES (1,'kim','010-1234-5678','2026-01-02'),(2,'lee','010-2222-3333','2026-02-03');
CREATE TABLE tb_stdnt_info (stdnt_no INT PRIMARY KEY, stdnt_nm VARCHAR(50), schyr INT, ban_cd VARCHAR(5));
INSERT INTO tb_stdnt_info VALUES (1,'a',1,'A'),(2,'b',3,'B'),(3,'c',6,'A');
-- 외래 키 따라가기 추정 관계: ui_points.member_no → ui_members(member_no) (외래 키 제약 없음)
CREATE TABLE ui_members (member_no INT PRIMARY KEY, nickname VARCHAR(50));
INSERT INTO ui_members VALUES (1001,'neo'),(1002,'trinity');
CREATE TABLE ui_points (id INT PRIMARY KEY, member_no INT, point INT);
INSERT INTO ui_points VALUES (1,1001,50),(2,1002,70);
SQL
# 스키마 비교용 shop_cmp: shop 의 테이블을 그대로 복사한 뒤 두 테이블만 다르게 (컬럼 하나 없음, 코멘트 다름)
CMP_COPY=$(docker exec goddb-mysql-test mysql -uroot -p$MYSQL_PASSWORD -N -e "SELECT CONCAT('CREATE TABLE shop_cmp.', CHAR(96), table_name, CHAR(96), ' LIKE shop.', CHAR(96), table_name, CHAR(96), ';') FROM information_schema.tables WHERE table_schema = 'shop' AND table_type = 'BASE TABLE'" 2>/dev/null)
printf '%s\n' "DROP DATABASE IF EXISTS shop_cmp;" "CREATE DATABASE shop_cmp;" "$CMP_COPY" \
  "ALTER TABLE shop_cmp.ui_orders DROP COLUMN note;" \
  "ALTER TABLE shop_cmp.ui_customers MODIFY name VARCHAR(50) NULL COMMENT '이름';" \
  | docker exec -i goddb-mysql-test mysql --default-character-set=utf8mb4 -uroot -p$MYSQL_PASSWORD 2>/dev/null
# PostgreSQL: shop DB 의 public 스키마 + 비교용 shop_cmp 스키마 (note 컬럼 없음, name 코멘트 다름)
pg_sql <<'SQL'
DROP SCHEMA IF EXISTS shop_cmp CASCADE;
DROP TABLE IF EXISTS ui_orders, ui_customers;
CREATE TABLE ui_customers (id INT PRIMARY KEY, name VARCHAR(50) NULL, grade VARCHAR(10));
COMMENT ON COLUMN ui_customers.name IS '고객 이름';
INSERT INTO ui_customers VALUES (10,'kim','gold'),(20,'lee','silver'),(30,'park','bronze');
CREATE TABLE ui_orders (id INT PRIMARY KEY, customer VARCHAR(50), amount INT, note VARCHAR(100),
  customer_id INT NULL CONSTRAINT fk_ui_orders_customer REFERENCES ui_customers(id));
INSERT INTO ui_orders VALUES (1,'kim',1200,'first',10),(2,'lee',3400,'apple, pie',20),(3,'park',560,NULL,30),
  (4,'choi',7800,'second',10),(5,'jung',90,'last',NULL);
CREATE SCHEMA shop_cmp;
CREATE TABLE shop_cmp.ui_customers (LIKE public.ui_customers INCLUDING ALL);
CREATE TABLE shop_cmp.ui_orders (LIKE public.ui_orders INCLUDING ALL);
ALTER TABLE shop_cmp.ui_orders DROP COLUMN note;
COMMENT ON COLUMN shop_cmp.ui_customers.name IS '이름';
SQL
# SQL Server: 테스트 전용 로그인 uitest (비밀번호 = 테스트 비밀번호) + shop · shop_cmp DB
mssql_sql <<SQL
IF SUSER_ID('uitest') IS NULL CREATE LOGIN uitest WITH PASSWORD = '$MYSQL_PASSWORD', CHECK_POLICY = OFF;
ALTER SERVER ROLE sysadmin ADD MEMBER uitest;
IF DB_ID('shop') IS NULL CREATE DATABASE shop;
IF DB_ID('shop_cmp') IS NOT NULL BEGIN ALTER DATABASE shop_cmp SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE shop_cmp; END
CREATE DATABASE shop_cmp;
GO
USE shop;
DROP TABLE IF EXISTS ui_orders;
DROP TABLE IF EXISTS ui_customers;
CREATE TABLE ui_customers (id INT PRIMARY KEY, name NVARCHAR(50) NULL, grade NVARCHAR(10));
EXEC sp_addextendedproperty 'MS_Description', N'고객 이름', 'SCHEMA', 'dbo', 'TABLE', 'ui_customers', 'COLUMN', 'name';
INSERT INTO ui_customers VALUES (10,'kim','gold'),(20,'lee','silver'),(30,'park','bronze');
CREATE TABLE ui_orders (id INT PRIMARY KEY, customer NVARCHAR(50), amount INT, note NVARCHAR(100),
  customer_id INT NULL CONSTRAINT fk_ui_orders_customer REFERENCES ui_customers(id));
INSERT INTO ui_orders VALUES (1,'kim',1200,'first',10),(2,'lee',3400,'apple, pie',20),(3,'park',560,NULL,30),
  (4,'choi',7800,'second',10),(5,'jung',90,'last',NULL);
GO
USE shop_cmp;
CREATE TABLE ui_customers (id INT PRIMARY KEY, name NVARCHAR(50) NULL, grade NVARCHAR(10));
EXEC sp_addextendedproperty 'MS_Description', N'이름', 'SCHEMA', 'dbo', 'TABLE', 'ui_customers', 'COLUMN', 'name';
CREATE TABLE ui_orders (id INT PRIMARY KEY, customer NVARCHAR(50), amount INT,
  customer_id INT NULL CONSTRAINT fk_ui_orders_customer REFERENCES ui_customers(id));
GO
SQL

cat > "$DATA/profiles.json" <<JSON
[
 {"id":"00000000-0000-4000-8000-0000000000A1","kind":"mysql","name":"UI MySQL","host":"127.0.0.1","port":$MYSQL_PORT,
  "username":"root","database":"shop","useTLS":false,"readOnly":false,"savePassword":false,"environment":"development"},
 {"id":"00000000-0000-4000-8000-0000000000A2","kind":"mysql","name":"UI MySQL Prod","host":"127.0.0.1","port":$MYSQL_PORT,
  "username":"root","database":"shop","useTLS":false,"readOnly":false,"savePassword":false,"environment":"production","group":"UI 그룹"},
 {"id":"00000000-0000-4000-8000-0000000000A3","kind":"mysql","name":"UI 닫힌 포트","host":"127.0.0.1","port":1,
  "username":"root","database":"shop","useTLS":false,"readOnly":false,"savePassword":false,"environment":"development","group":"UI 그룹"},
 {"id":"00000000-0000-4000-8000-0000000000A4","kind":"mysql","name":"UI 둘째 그룹 접속","host":"127.0.0.1","port":1,
  "username":"root","database":"shop","useTLS":false,"readOnly":false,"savePassword":false,"environment":"development","group":"UI 둘째 그룹"},
 {"id":"00000000-0000-4000-8000-0000000000A5","kind":"postgres","name":"UI PostgreSQL","host":"127.0.0.1","port":$PG_PORT,
  "username":"postgres","database":"shop","useTLS":false,"readOnly":false,"savePassword":false,"environment":"development"},
 {"id":"00000000-0000-4000-8000-0000000000A6","kind":"mssql","name":"UI SQL Server","host":"127.0.0.1","port":$MSSQL_PORT,
  "username":"uitest","database":"shop","useTLS":false,"readOnly":false,"savePassword":false,"environment":"development"}
]
JSON

# AI 데이터 찾기 시나리오는 이 PC 의 Ollama 가 필요하다. 꺼져 있으면 켜고 응답할 때까지 기다린다.
if [[ ${#SCENARIOS[@]} -eq 0 || " ${SCENARIOS[*]} " == *" dataFinder "* || " ${SCENARIOS[*]} " == *" assistantInterrupt "* ]]; then
  if ! curl -s -m 3 http://localhost:11434/api/tags >/dev/null 2>&1; then
    echo "▶ Ollama 켜기"
    if [[ -d /Applications/Ollama.app ]]; then
      open -g -a Ollama
    elif command -v ollama >/dev/null; then
      nohup ollama serve > "$WORK.ollama.log" 2>&1 &
    fi
    for i in {1..30}; do curl -s -m 2 http://localhost:11434/api/tags >/dev/null 2>&1 && break; sleep 1; done
  fi
  if curl -s -m 3 http://localhost:11434/api/tags 2>/dev/null | grep -q '"qwen3.8:27b-mlx"'; then
    echo "  Ollama 준비됨 (qwen3.8:27b-mlx)"
  else
    echo "  ⚠️ Ollama 가 켜지지 않았거나 qwen3.8:27b-mlx 가 없어요 — AI 데이터 찾기 시나리오는 실패할 수 있어요 (ollama pull qwen3.8:27b-mlx)"
  fi
fi

# 테이블 설명 시나리오용 JSON (#178)
cat > "$WORK/table-descriptions.json" <<'JSON'
{ "format": "goddb-table-descriptions", "version": 1, "database": "shop",
  "tables": [
    { "name": "tb_mbr_info", "title": "회원 정보",
      "columns": [ { "name": "mbr_tel_no", "title": "회원 전화번호", "terms": ["연락처"] },
                   { "name": "mbr_nm", "values": { "kim": "김", "lee": "이" } } ] },
    { "name": "no_such_table" } ] }
JSON
export GODDB_UI_DESC_JSON="$WORK/table-descriptions.json"

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
  docker exec goddb-mysql-test mysql -uroot -p$MYSQL_PASSWORD shop \
    -e "DROP TABLE IF EXISTS ui_orders, ui_customers, ui_students, ui_schools, ui_points, ui_members, tb_mbr_info, tb_stdnt_info; DROP DATABASE IF EXISTS shop_cmp" 2>/dev/null || true
  echo "DROP SCHEMA IF EXISTS shop_cmp CASCADE; DROP TABLE IF EXISTS ui_orders, ui_customers;" | pg_sql 2>/dev/null || true
  printf '%s\n' "IF DB_ID('shop_cmp') IS NOT NULL BEGIN ALTER DATABASE shop_cmp SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE shop_cmp; END" \
    "USE shop; DROP TABLE IF EXISTS ui_orders; DROP TABLE IF EXISTS ui_customers;" | mssql_sql 2>/dev/null || true
fi
echo
echo "보고서: $WORK/report.txt"
exit $RESULT
