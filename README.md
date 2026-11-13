# GodDB (갓디비)

무료 macOS DB 클라이언트 — **MySQL / PostgreSQL / SQL Server / Redis**.
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
| Redis | 키 브라우저(SCAN), 타입별 값 편집, 콘솔, Pub/Sub, Streams(소비자 그룹·PEL·실시간), INFO |
| 접속 공유 | 접속 정보 내보내기/가져오기(비밀번호 암호화 선택), DataGrip ⌘C → ⌘V 붙여넣기 |
| 감사 로그 | 상태창 기록을 `~/Library/Logs/GodDB` 에 날짜별 영구 보관 |
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
- 지금은 개발자 서명(Developer ID)·공증(notarization) 없이 임시 서명이라, 처음 열 때 macOS(게이트키퍼)가 막는다. macOS 15 부터는 우클릭 > 열기로 넘어가지지 않는다.
  - **방법 A (권장)**: DMG 를 열기 전에 터미널에서 `xattr -d com.apple.quarantine ~/Downloads/GodDB-*.dmg` → DMG 열고 Applications 로 옮겨 실행.
  - **방법 B**: 한 번 실행 → 경고 창 닫기 → 시스템 설정 > 개인정보 보호 및 보안 > "GodDB 이(가) 차단되었습니다" 옆 **그래도 열기**.
  - **경고 없이 Dock 아이콘만 계속 튀고 창이 안 뜨면**: 시스템 설정 > 개인정보 보호 및 보안 > "다음에서 다운로드한 응용 프로그램 허용" 을 **App Store** 로 바꿨다가 다시 **App Store 및 확인된 개발자** 로 돌린 뒤 다시 실행. (게이트키퍼 검사가 멈춘 상태가 풀린다)
  - `/Applications` 안의 앱에 `xattr -cr` 를 하면 `Operation not permitted` 가 날 수 있다(앱 관리 권한). 방법 A 처럼 DMG 단계에서 지운다.
- FreeTDS·OpenSSL 라이브러리는 앱 안(`Contents/Frameworks`)에 넣어 배포하므로 받는 Mac 에 Homebrew 가 없어도 된다. (빌드하는 Mac 에만 `brew install freetds` 필요)
- 서명·DMG 조립은 iCloud 밖 임시 폴더에서 한다. iCloud 폴더에서는 확장 속성 때문에 서명이 깨진다.

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

## 개발 흐름

이슈 → 브랜치 → PR(CI 통과) → squash 머지 → 마일스톤 단위 릴리스. 자세한 내용은 [CONTRIBUTING.md](CONTRIBUTING.md).

## 구조

- `Sources/GodDBCore` — UI 없는 로직 (접속/터널/키체인/SQL 유틸/스키마 비교). 테스트 대상
- `Sources/GodDB` — SwiftUI 앱
- `Tests/GodDBCoreTests` — swift-testing 단위·통합 테스트

## 이후 후보

MSSQL / PostgreSQL 지원, 표에서 데이터 편집, 자동완성, 쿼리 히스토리, 비밀번호 방식 SSH.
