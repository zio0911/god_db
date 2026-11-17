#!/bin/zsh
# docs/FEATURES.md 의 "### X.Y.Z" 제목 아래 변경 이력을 잘라 GitHub 릴리스 노트(변경 사항 + 설치 안내)로 출력한다.
#   ./scripts/release-notes.sh 1.3.5            → 표준 출력
# 해당 버전 제목이 없으면 변경 사항 없이 설치 안내만 출력한다.
set -e
cd "$(dirname "$0")/.."
V="${1#v}"
[[ -n "$V" ]] || { echo "사용법: $0 <버전>" >&2; exit 1; }

SECTION=$(awk -v h="### $V" '
  $0 == h { on = 1; next }
  on && (/^### / || /^## /) { exit }
  on { print }
' docs/FEATURES.md | sed -e '/./,$!d' | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}')

if [[ -n "$SECTION" ]]; then
  print -r -- "## 변경 사항"
  print -r -- "$SECTION"
  print
fi
cat <<'MD'
## 설치
`GodDB-*.dmg` 를 열고 GodDB 를 Applications 로 끌어다 놓은 뒤 실행하세요. Apple 공증을 받은 앱이라 바로 열려요.
이미 1.1.0 이상을 쓰고 있으면 앱이 자동으로 업데이트를 알려줘요.
MD
