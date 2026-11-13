#!/bin/zsh
# 통합 테스트용 MySQL / PostgreSQL / SQL Server / Redis 컨테이너
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
    docker start goddb-redis-test 2>/dev/null || docker run -d --name goddb-redis-test \
      -p 127.0.0.1:36379:6379 redis:7 redis-server --requirepass goddbtest
    # Redis Cluster: 한 컨테이너에 노드 3개 (37000~37002), 호스트에서 같은 포트로 접근
    docker start goddb-redis-cluster 2>/dev/null || docker run -d --name goddb-redis-cluster \
      -p 127.0.0.1:37000-37002:37000-37002 redis:7 sh -c '
        for p in 37000 37001 37002; do
          redis-server --port $p --cluster-enabled yes --cluster-config-file /tmp/n$p.conf --cluster-announce-ip 127.0.0.1 \
            --requirepass goddbtest --masterauth goddbtest --appendonly no --daemonize yes
        done
        sleep 1
        redis-cli -a goddbtest --no-auth-warning --cluster create 127.0.0.1:37000 127.0.0.1:37001 127.0.0.1:37002 --cluster-replicas 0 --cluster-yes
        tail -f /dev/null'
    # Redis Sentinel: 마스터 36380 + 센티널 36381 (마스터 이름 mymaster)
    docker start goddb-redis-sentinel 2>/dev/null || docker run -d --name goddb-redis-sentinel \
      -p 127.0.0.1:36380-36381:36380-36381 redis:7 sh -c '
        redis-server --port 36380 --requirepass goddbtest --masterauth goddbtest --daemonize yes
        printf "port 36381\nsentinel resolve-hostnames yes\nsentinel monitor mymaster 127.0.0.1 36380 1\nsentinel auth-pass mymaster goddbtest\n" > /tmp/s.conf
        redis-sentinel /tmp/s.conf'
    echo "SQL Server 준비 대기…"
    for i in $(seq 1 60); do nc -z 127.0.0.1 31433 2>/dev/null && break; sleep 2; done
    ;;
  test)
    GODDB_IT_PORT=33306 GODDB_IT_PASSWORD=goddbtest GODDB_PG_PORT=35432 GODDB_MSSQL_PORT=31433 GODDB_REDIS_PORT=36379 GODDB_REDIS_CLUSTER_PORT=37000 GODDB_REDIS_SENTINEL_PORT=36381 ./scripts/test.sh
    ;;
  down)
    docker rm -f goddb-mysql-test goddb-pg-test goddb-mssql-test goddb-redis-test goddb-redis-cluster goddb-redis-sentinel
    ;;
  *)
    echo "사용법: $0 up|test|down"; exit 1 ;;
esac
