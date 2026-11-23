#!/bin/zsh
# Vendor/ 에 복사해 고친 드라이버(mysql-nio, postgres-nio)가 원본보다 뒤처졌거나 보안 권고에 걸리는지 본다.
# 복사본은 Dependabot 등이 알려 주지 않으므로 PR CI 와 릴리스 때 이 검사로 확인한다.
#   ./scripts/check-vendor-updates.sh          → 결과 출력 (CI 에서는 ::warning:: 으로 표시)
#   ./scripts/check-vendor-updates.sh --strict → 보안 권고에 걸리면 종료 코드 1
# 기준 버전은 각 Vendor/<이름>/GODDB_PATCH.md 의 "원본: https://github.com/<owner>/<repo> <버전>" 줄.
set -u
cd "$(dirname "$0")/.."
STRICT=0; [[ "${1:-}" == "--strict" ]] && STRICT=1
CI_MODE=0; [[ -n "${GITHUB_ACTIONS:-}" ]] && CI_MODE=1
api() { gh api "$1" 2>/dev/null || curl -fsSL -H "Accept: application/vnd.github+json" "https://api.github.com/$1" 2>/dev/null; }
warn() { if (( CI_MODE )); then print -r -- "::warning title=Vendor 드라이버::$1"; else print -r -- "⚠️  $1"; fi; }
vulnerable=0
for f in Vendor/*/GODDB_PATCH.md; do
  line=$(grep -m1 -E '^원본: https://github.com/[^ ]+ [0-9][^ ]*' "$f") || { warn "$f 에 '원본: URL 버전' 줄이 없어요"; continue; }
  repo=$(print -r -- "$line" | sed -E 's#^원본: https://github.com/([^ ]+) .*#\1#')
  base=$(print -r -- "$line" | sed -E 's#^원본: https://github.com/[^ ]+ ([0-9][^ ]*).*#\1#')
  latest=$(api "repos/$repo/releases/latest" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("tag_name",""))' 2>/dev/null)
  latest=${latest#v}
  advisories=$(api "advisories?ecosystem=swift&affects=github.com/$repo@$base" | python3 -c '
import sys, json
try:
    items = json.load(sys.stdin)
except Exception:
    items = []
for a in items:
    v = (a.get("vulnerabilities") or [{}])[0]
    fixed = v.get("first_patched_version") or "?"
    print("%s (%s) 고친 버전 %s: %s" % (a.get("ghsa_id"), a.get("severity"), fixed, a.get("summary")))
' 2>/dev/null)
  if [[ -z "$latest" ]]; then
    warn "$repo 최신 릴리스를 확인하지 못했어요 (네트워크 · API 제한)"
  elif [[ "$latest" != "$base" ]]; then
    warn "$repo: 복사본 $base, 원본 최신 $latest — 원본 변경 사항(특히 보안)을 보고 $f 의 패치를 다시 적용할지 정하세요"
  else
    print -r -- "✅ $repo $base (원본 최신과 같음)"
  fi
  if [[ -n "$advisories" ]]; then
    vulnerable=1
    while IFS= read -r a; do warn "$repo $base 보안 권고: $a"; done <<< "$advisories"
  fi
done
(( STRICT && vulnerable )) && exit 1
exit 0
