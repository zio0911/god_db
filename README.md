# GodDB (갓디비)

무료 macOS DB 클라이언트 — **MySQL / PostgreSQL / SQL Server**.
SwiftUI + [mysql-nio](https://github.com/vapor/mysql-nio) + [postgres-nio](https://github.com/vapor/postgres-nio)(텍스트 결과 패치본, `Vendor/`) + [FreeTDS](https://www.freetds.org).

상세 기능 명세: [docs/FEATURES.md](docs/FEATURES.md) · 한국어 / English (설정 `⌘,`)

라이선스: [MIT](LICENSE) © 2026 zio0911 · 사용한 오픈소스: [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)

## 기능 요약

| 기능 | 내용 |
|---|---|
| 접속 관리 | 여러 접속 저장 (`~/Library/Application Support/GodDB/profiles.json`), 비밀번호는 macOS 키체인 |
| SSH 터널 | `/usr/bin/ssh -N -L` 로 바스티온 경유. 키 파일 또는 ssh-agent 인증 |
| 읽기전용 | SELECT/SHOW/DESC/EXPLAIN 만 허용 + 서버 세션 `TRANSACTION READ ONLY` |
| 스키마 브라우저 | DB 선택, 테이블/컬럼/인덱스 트리, 검색, 더블클릭 시 SELECT |
| 쿼리 | 탭, 하이라이트, ⌘↩ (선택 영역 또는 커서 위치 구문 실행), 기본 LIMIT 500, CSV 복사 |
| 스키마 비교 | 기준 → 대상 차이 (누락/다름/대상에만 있음), 보정 `ALTER`/`CREATE` SQL 생성. **자동 실행 안 함, DROP 생성 안 함** |
| 테이블 수정 | 컬럼/인덱스/코멘트 편집 → ALTER 미리보기 → 확인 후 실행 |
| 실행 계획 | EXPLAIN + 풀스캔/filesort 등 주의사항, 트리 보기 |
| 객체 보기 | 인덱스, 뷰, 프로시저, 함수, 트리거 정의 |
| 상태창 | 모든 이벤트/오류 기록, 오류 해결 방법 안내 (⇧⌘L) |

## 준비

```bash
brew install freetds      # SQL Server 드라이버 (DB-Library)
```

## 빌드 / 실행

```bash
swift run                 # 개발 실행
./scripts/build-app.sh    # build/GodDB.app 생성 (응용 프로그램 폴더로 복사해서 사용)
./scripts/test.sh         # 단위 테스트
```

Xcode 로 열기: `open Package.swift`

## 앱 아이콘

`Resources/AppIcon.icns` (후광이 있는 DB). 다시 만들려면:

```bash
swift scripts/draw-icon.swift iconset Resources/AppIcon.iconset
iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns && rm -rf Resources/AppIcon.iconset
```

## DMG 만들기 (배포용)

```bash
./scripts/make-dmg.sh     # → build/GodDB-<버전>.dmg (GodDB.app + Applications 바로가기 + 읽어주세요.txt)
```

- 버전은 `scripts/build-app.sh` 의 `CFBundleShortVersionString` 에서 정한다.
- 지금은 개발자 서명(Developer ID)·공증(notarization) 없이 임시 서명이라, 받은 사람이 처음 열 때 "확인되지 않은 개발자" 경고가 뜬다 → 우클릭 > 열기.
- SQL Server 를 쓰려면 받는 Mac 에도 `brew install freetds` 가 필요하다.

## 로컬 테스트 DB (세 DB 통합 테스트)

```bash
./scripts/test-dbs.sh up     # MySQL 33306 / PostgreSQL 35432 / SQL Server 31433 컨테이너
./scripts/test-dbs.sh test   # 단위 + 세 DB 통합 테스트
./scripts/test-dbs.sh down   # 컨테이너 삭제
```

비밀번호는 `scripts/test-dbs.sh` 에 있다 (로컬 테스트 전용 값).

### MySQL 만 따로

```bash
docker run -d --name goddb-mysql-test -e MYSQL_ROOT_PASSWORD=goddbtest -e MYSQL_DATABASE=shop \
  -p 127.0.0.1:33306:3306 mysql:8.0
GODDB_IT_PORT=33306 GODDB_IT_PASSWORD=goddbtest ./scripts/test.sh
```

앱에서 접속: 호스트 `127.0.0.1`, 포트 `33306`, 사용자 `root`, 비밀번호 위 값, DB `shop`.

## 구조

- `Sources/GodDBCore` — UI 없는 로직 (접속/터널/키체인/SQL 유틸/스키마 비교). 테스트 대상
- `Sources/GodDB` — SwiftUI 앱
- `Tests/GodDBCoreTests` — swift-testing 단위·통합 테스트

## 이후 후보

MSSQL / PostgreSQL 지원, 표에서 데이터 편집, 자동완성, 쿼리 히스토리, 비밀번호 방식 SSH.
