# 릴리스 (자동)

`vX.Y.Z` 태그를 푸시하면 GitHub Actions(`.github/workflows/release.yml`)가 **빌드 → Developer ID 서명 → DMG → Apple 공증 → stapler → 업데이트 서명(appcast.xml) → GitHub 릴리스**까지 한다.
`release` 환경에 묶여 있어 **저장소 주인이 Actions 화면에서 승인해야** 서명 단계가 시작된다. `v*` 태그에서만 실행할 수 있다.

## 릴리스 순서

```bash
git switch main && git pull
# VERSION 파일과 docs/FEATURES.md 변경 이력(### X.Y.Z) 수정
git commit -am "X.Y.Z 릴리스 준비: 버전·변경 이력" && git push
git tag vX.Y.Z && git push origin vX.Y.Z
# → Actions > Release > Review deployments > release 승인 → 약 10~15분 뒤 릴리스 생성
```

같은 태그로 다시 만들려면 Actions > Release > Run workflow 에 태그를 넣는다 (파일만 다시 올림).

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

```bash
gh secret set DEVELOPER_ID_P12 --env release --repo zio0911/god_db < <(base64 -i DeveloperID.p12)
gh secret set DEVELOPER_ID_P12_PASSWORD --env release --repo zio0911/god_db     # 프롬프트에 붙여넣기
gh secret set APPLE_ID --env release --repo zio0911/god_db
gh secret set APPLE_TEAM_ID --env release --repo zio0911/god_db --body ZKVKMA7N59
gh secret set APPLE_APP_PASSWORD --env release --repo zio0911/god_db
gh secret set SPARKLE_PRIVATE_KEY --env release --repo zio0911/god_db < sparkle_key.txt
rm DeveloperID.p12 sparkle_key.txt   # 등록 후 파일은 지운다 (백업은 안전한 곳에 따로)
```

## 키 백업 · 갱신

- **Developer ID 인증서**: 만료 2027-12-13. 그 전에 같은 방법(CSR → 다운로드)으로 새로 받고 `DEVELOPER_ID_P12` 를 바꾼다. 이미 배포한 앱은 타임스탬프·공증 덕분에 만료 뒤에도 열린다.
- **Sparkle 업데이트 키**: 잃어버리면 설치된 앱들이 새 업데이트를 거부한다 (수동 재설치 필요). `.p12` 와 함께 암호 관리자 등 안전한 곳에 백업.
- **Apple 개발자 멤버십**: 1년마다 갱신.

## 로컬에서 릴리스 (CI 없이)

`./scripts/make-dmg.sh` 가 이 Mac 키체인의 인증서·공증 프로필(`goddb`)·업데이트 키로 같은 일을 한다. 그 뒤 `gh release create vX.Y.Z build/GodDB-X.Y.Z.dmg build/appcast.xml --verify-tag --generate-notes`.
