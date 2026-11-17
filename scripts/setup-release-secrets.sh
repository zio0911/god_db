#!/bin/zsh
# GitHub Actions 릴리스(release.yml)에 필요한 값을 `release` 환경 Secrets 에 등록한다.
# 값은 화면에 보이지 않게 입력받아 gh 로 바로 보내고, 만든 임시 파일은 지운다. 저장소에는 아무것도 남지 않는다.
#
# 준비:
#   1. 키체인 접근 > 내 인증서 > "Developer ID Application: …" 우클릭 > 내보내기 → .p12 (암호 지정)
#   2. account.apple.com > 로그인 및 보안 > 앱 암호 → 공증용 앱 암호 (기존 것을 모르면 새로 만든다)
#
# 사용: ./scripts/setup-release-secrets.sh ~/Desktop/DeveloperID.p12
set -e
cd "$(dirname "$0")/.."
REPO=zio0911/god_db
TEAM_ID=ZKVKMA7N59
P12="$1"
[[ -f "$P12" ]] || { echo "사용법: $0 <Developer ID .p12 경로>"; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# 1) Sparkle 업데이트 서명 키 (이 Mac 키체인에서 꺼냄 — 키체인 접근 허용 창이 뜨면 허용)
GEN=.build/artifacts/sparkle/Sparkle/bin/generate_keys
[[ -x "$GEN" ]] || swift package resolve >/dev/null
"$GEN" -x "$TMP/sparkle.txt" >/dev/null
[[ -s "$TMP/sparkle.txt" ]] || { echo "Sparkle 키를 꺼내지 못했어요"; exit 1; }

# 2) 입력 (화면에 안 보임)
read -rs "P12_PASS?.p12 암호: "; echo
openssl pkcs12 -in "$P12" -passin "pass:$P12_PASS" -nokeys -legacy >/dev/null 2>&1 \
  || openssl pkcs12 -in "$P12" -passin "pass:$P12_PASS" -nokeys >/dev/null 2>&1 \
  || { echo ".p12 암호가 맞지 않아요"; exit 1; }
read -r "APPLE_ID?Apple ID (개발자 계정 이메일): "
read -rs "APP_PASS?공증용 앱 암호: "; echo
read -rs "FORBIDDEN?앱 안에 있으면 안 되는 단어 정규식 (선택, 엔터=건너뜀): "; echo

# 3) 등록 (값은 표준 입력으로만 보낸다 — 명령줄 인자로 넘기면 다른 프로세스에서 보일 수 있다)
set_secret() { gh secret set "$1" --env release --repo "$REPO" >/dev/null; echo "  ✓ $1"; }
echo "release 환경에 등록:"
base64 -i "$P12" | set_secret DEVELOPER_ID_P12
print -rn -- "$P12_PASS" | set_secret DEVELOPER_ID_P12_PASSWORD
print -rn -- "$APPLE_ID" | set_secret APPLE_ID
print -rn -- "$TEAM_ID" | set_secret APPLE_TEAM_ID
print -rn -- "$APP_PASS" | set_secret APPLE_APP_PASSWORD
set_secret SPARKLE_PRIVATE_KEY < "$TMP/sparkle.txt"
[[ -n "$FORBIDDEN" ]] && print -rn -- "$FORBIDDEN" | set_secret FORBIDDEN_WORDS_REGEX
unset P12_PASS APP_PASS FORBIDDEN

echo
gh secret list --env release --repo "$REPO"
echo
echo "끝. 내보낸 .p12 파일은 지우세요: rm '$P12'"
