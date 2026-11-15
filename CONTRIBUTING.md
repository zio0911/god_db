# 개발 흐름

1. **이슈** — 기능 하나 / 버그 하나당 이슈 하나. 템플릿(기능 요청 · 버그 신고)을 쓰고 라벨과 마일스톤을 붙인다.
   - 종류: `type:feature` · `type:bug` · `type:chore` · `type:docs`
   - 영역: `area:sql` · `area:redis` · `area:modeling` · `area:ai` · `area:ui`
2. **브랜치** — `main` 에서 `feature/<이슈번호>-<짧은-이름>` (버그는 `fix/…`, 설정은 `chore/…`).
3. **PR** — 본문에 `Closes #<이슈번호>`. 템플릿의 테스트 · 공개 저장소 점검 항목을 채운다. CI(빌드 + 단위 테스트)가 통과해야 머지한다.
4. **머지** — squash merge. 브랜치는 머지 후 자동 삭제.
5. **릴리스** — 마일스톤의 이슈·PR 이 모두 머지되면 `VERSION` · 변경 이력을 main 에 바로 커밋하고 `vX.Y.Z` 태그를 푸시한다. GitHub Actions 가 서명·공증·업데이트 목록·릴리스까지 한다 (승인 필요). 자세한 절차와 Secrets 등록은 [docs/RELEASING.md](docs/RELEASING.md).

## 로컬 개발

```bash
brew install freetds
./scripts/test.sh                 # 단위 테스트
./scripts/test-dbs.sh up && ./scripts/test-dbs.sh test   # Docker DB 통합 테스트
./scripts/build-app.sh            # build/GodDB.app
```

## 공개 저장소 주의

회사 호스트명 · IP · 계정 · 실제 데이터는 코드, 문서, 스크린샷, 이슈에 올리지 않는다.
