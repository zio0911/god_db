# 릴리스 (자동)

`vX.Y.Z` 태그를 푸시하면 GitHub Actions(`.github/workflows/release.yml`)가 **빌드 → Developer ID 서명 → DMG → Apple 공증 → stapler → 업데이트 서명(appcast.xml) → GitHub 릴리스**까지 한다.
`release` 환경에 묶여 있어 **저장소 주인이 Actions 화면에서 승인해야** 서명 단계가 시작된다. `v*` 태그에서만 실행할 수 있다.

## 릴리스 전 확인

```bash
./scripts/test-dbs.sh up && ./scripts/test-dbs.sh test   # 단위 + 실제 DB 통합 테스트
./scripts/ui-test.sh                                      # 화면 자동 테스트 (약 2분)
```

`ui-test.sh` 는 실제 앱을 띄워 마우스 · 키보드로 주요 화면 동작(연결, 실행, 위험 문장 확인, 주석 · 정렬, 쿼리 취소, 결과 복사 · 필터,
히스토리, 빠른 찾기, 탭 닫기, 운영 접속 확인, 레이아웃)을 눌러 보고 `PASS / FAIL` 을 낸다.

- 실행하는 동안(약 2분) **마우스 · 키보드를 쓰지 않는다** — 실제 화면을 쓴다.
- 실제 접속 목록 · 탭 · 히스토리 · 감사 로그 · 설정은 건드리지 않는다 (번들 ID 를 바꾼 복사본 + 임시 데이터 폴더, 로컬 Docker MySQL 만 사용).
- 처음 한 번: 시스템 설정 > 개인정보 보호 및 보안 > **손쉬운 사용** 에서 실행하는 앱(터미널 등)을 허용.
- 일부만: `./scripts/ui-test.sh --no-build connect run grid`, 끝난 뒤 앱을 보려면 `--keep`.

## 릴리스 순서

```bash
git switch main && git pull
# VERSION 파일과 docs/FEATURES.md 변경 이력(### X.Y.Z) 수정
git commit -am "chore: X.Y.Z 릴리스 준비" && git push
git tag vX.Y.Z && git push origin vX.Y.Z
# → Actions > Release > Review deployments > release 승인 → 약 10~15분 뒤 릴리스 생성
```

같은 태그로 다시 만들려면 Actions > Release > Run workflow 에 태그를 넣는다 (파일만 다시 올림).

### 릴리스 노트

릴리스 노트 맨 위 **"변경 사항"** 은 `docs/FEATURES.md` 의 `### X.Y.Z` 제목 아래 내용을 그대로 쓴다 (`scripts/release-notes.sh`).
그 아래에 설치 안내와 PR 목록(`skip-changelog` 라벨 제외)이 붙는다. 변경 이력은 **FEATURES.md 한 곳에만** 쓴다.

미리 보기: `./scripts/release-notes.sh X.Y.Z`

### GitHub 웹에서 릴리스 (터미널 없이)

1. `VERSION` 파일을 새 버전으로, `docs/FEATURES.md` 맨 위 버전 줄과 `### X.Y.Z` 변경 이력을 고쳐 main 에 커밋한다. (VERSION 과 태그가 다르면 워크플로가 멈춘다)
2. Releases > **Draft a new release** > 태그 `vX.Y.Z` (Create new tag on publish, target `main`) > 제목 `GodDB X.Y.Z` > Generate release notes > **Publish release**
3. Actions > Release 가 시작되면 **Review deployments** > `release` 승인. 자동으로 시작되지 않으면 Actions > Release > **Run workflow** 에 `vX.Y.Z`.
4. 약 10분 뒤 DMG · appcast.xml 이 붙고, 노트 맨 위에 FEATURES.md 변경 이력이 들어간다.

웹에서 먼저 만들면 빌드가 끝날 때까지(약 10분) 최신 릴리스에 appcast.xml 이 없어 그 사이 앱의 업데이트 확인이 한 번 실패할 수 있다. 터미널에서 태그를 먼저 올리면 이 공백이 없다.

## 처음 한 번: `release` 환경 Secrets 등록

값은 **본인이 직접** 넣는다. 저장소 코드·로그에는 남지 않는다 (로그에서는 `***`).
등록: GitHub 저장소 > Settings > Environments > `release` > Environment secrets, 또는 아래 `gh` 명령.

| 이름 | 내용 | 만드는 법 |
|---|---|---|
| `DEVELOPER_ID_P12` | Developer ID 인증서 + 개인 키 (.p12, base64) | 키체인 접근 > 내 인증서 > "Developer ID Application: …" 우클릭 > 내보내기 → `.p12` (암호 지정) |
| `DEVELOPER_ID_P12_PASSWORD` | 위 .p12 암호 | 내보낼 때 정한 암호 |
| `APPLE_ID` | 개발자 계정 Apple ID 이메일 | |
| `APPLE_TEAM_ID` | 팀 ID (예: `ZKVKMA7N59`) | developer.apple.com > Membership |
| `APPLE_APP_PASSWORD` | 공증용 앱 전용 암호 | account.apple.com > 앱 암호 |
| `SPARKLE_PRIVATE_KEY` | 업데이트 서명 개인 키 | `.build/artifacts/sparkle/Sparkle/bin/generate_keys -x sparkle_key.txt` |
| `FORBIDDEN_WORDS_REGEX` (선택) | 앱 안에 있으면 안 되는 단어 정규식 | 예: 회사명·내부 도메인 |

한 번에 등록 (값은 화면에 안 보이게 입력받는다):

```bash
./scripts/setup-release-secrets.sh ~/Desktop/DeveloperID.p12
rm ~/Desktop/DeveloperID.p12   # 등록 후 내보낸 파일은 지운다
```

- Secrets 는 저장 후 아무도 (저장소 주인도) 값을 다시 볼 수 없고, 로그에서는 `***` 로 가려진다.
- fork 에서 온 PR 의 CI 에는 전달되지 않는다. `release` 환경 승인 전에는 서명 단계가 시작되지 않는다.

## 키 백업 · 갱신

- **Developer ID 인증서**: 만료 2027-12-13. 그 전에 같은 방법(CSR → 다운로드)으로 새로 받고 `DEVELOPER_ID_P12` 를 바꾼다. 이미 배포한 앱은 타임스탬프·공증 덕분에 만료 뒤에도 열린다.
- **Sparkle 업데이트 키**: 잃어버리면 설치된 앱들이 새 업데이트를 거부한다 (수동 재설치 필요). `.p12` 와 함께 암호 관리자 등 안전한 곳에 백업.
- **Apple 개발자 멤버십**: 1년마다 갱신.

## 로컬에서 릴리스 (CI 없이)

`./scripts/make-dmg.sh` 가 이 Mac 키체인의 인증서·공증 프로필(`goddb`)·업데이트 키로 같은 일을 한다. 그 뒤:

```bash
./scripts/release-notes.sh X.Y.Z > /tmp/notes.md
gh release create vX.Y.Z build/GodDB-X.Y.Z.dmg build/appcast.xml --verify-tag --title "GodDB X.Y.Z" --generate-notes --notes-file /tmp/notes.md
```

태그를 올리면 Actions 릴리스도 시작되니, 로컬로 할 때는 그 실행을 취소한다.
