#!/bin/zsh
# 통합 테스트용 MySQL / PostgreSQL / SQL Server 컨테이너
#   ./scripts/test-dbs.sh up    컨테이너 생성/시작
#   ./scripts/test-dbs.sh test  세 DB 통합 테스트 포함 전체 테스트
#   ./scripts/test-dbs.sh down  컨테이너 삭제
set -e
cd "$(dirname "$0")/.."
case "$1" in
  up)
    docker start goddb-mysql-test 2>/dev/null || docker run -d --name goddb-mysql-test \
      -e MYSQL_ROOT_PASSWORD=goddbtest -e MYSQL_DATABASE=shop -p 127.0.0.1:33306:3306 mysql:8.0
    docker start goddb-pg-test 2>/dev/null || docker run -d --name goddb-pg-test \
      -e POSTGRES_PASSWORD=goddbtest -e POSTGRES_DB=shop -p 127.0.0.1:35432:5432 postgres:16
    # SQL Server 는 Intel 이미지라 Apple 칩에서는 에뮬레이션으로 돈다 (가끔 종료되면 up 을 다시 실행)
    docker start goddb-mssql-test 2>/dev/null || docker run -d --name goddb-mssql-test --platform linux/amd64 \
      -e ACCEPT_EULA=Y -e 'MSSQL_SA_PASSWORD=GodDb_test1!' -p 127.0.0.1:31433:1433 mcr.microsoft.com/mssql/server:2022-latest
    echo "SQL Server 준비 대기…"
    for i in $(seq 1 60); do nc -z 127.0.0.1 31433 2>/dev/null && break; sleep 2; done
    ;;
  test)
    GODDB_IT_PORT=33306 GODDB_IT_PASSWORD=goddbtest GODDB_PG_PORT=35432 GODDB_MSSQL_PORT=31433 ./scripts/test.sh
    ;;
  down)
    docker rm -f goddb-mysql-test goddb-pg-test goddb-mssql-test
    ;;
  *)
    echo "사용법: $0 up|test|down"; exit 1 ;;
esac
