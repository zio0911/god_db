# 테이블 설명 JSON 양식 (AI 참고)

AI 어시스턴트 · 데이터 찾기가 참고하는 **테이블 · 컬럼 · 데이터(코드 값) 설명** 파일 양식이다 (#178, 기능 명세 39절).
사이드바 DB 머리 우클릭 > **테이블 설명 (AI 참고)…** 에서 접속 · DB 마다 가져온다.

## 만드는 순서

1. **테이블 설명 (AI 참고)…** 창에서 [양식 저장…] → 지금 테이블 · 컬럼 이름 · 코멘트 · FK 만 든 빈 양식 (데이터 값 없음)
2. [복사] 로 분석 요청문을 복사해, 빈 양식 · 소스 저장소와 함께 Claude 에 붙여넣는다
3. 돌려받은 JSON 을 [JSON 가져오기…] — 양식이 어긋나면 어디가 틀렸는지 알려 준다

GodDB 는 이 과정에서 아무것도 클라우드로 보내지 않는다. 회사 규칙상 소스 · 스키마를 외부 AI 에 보내도 되는지는 먼저 확인할 것.

## 양식

```json
{
  "format": "goddb-table-descriptions",
  "version": 1,
  "database": "shop",
  "generatedBy": "Claude (소스 분석)",
  "generatedAt": "2026-11-24",
  "overview": "쇼핑몰 회원 · 주문 · 상품 DB. 주문은 orders → order_items 로 나뉜다.",
  "tables": [
    {
      "name": "orders",
      "title": "주문",
      "description": "회원이 결제한 주문 한 건. 취소해도 행은 남고 status 가 X",
      "terms": ["주문", "결제 내역"],
      "columns": [
        { "name": "member_id", "title": "회원", "references": "members.id" },
        { "name": "status", "title": "주문 상태",
          "values": { "P": "결제 대기", "C": "완료", "X": "취소" } },
        { "name": "deleted_at", "title": "삭제일시", "description": "값이 있으면 지운 주문 (소프트 삭제)" }
      ],
      "notes": ["조회할 땐 deleted_at IS NULL 조건을 붙인다"]
    }
  ]
}
```

| 칸 | 필수 | 뜻 |
|---|---|---|
| `format` | | `goddb-table-descriptions` (다르면 거절) |
| `version` | | `1` (더 크면 "GodDB 를 업데이트해 주세요") |
| `database` | | DB · 스키마 이름. 지금 DB 와 다르면 넣을지 묻는다 |
| `generatedBy` · `generatedAt` | | 누가 · 언제 만들었는지 (참고용) |
| `overview` | | DB 전체 업무 도메인 2~3문장 |
| `tables[].name` | ✔ | 테이블 이름 (`public.orders` · `orders` 같게 본다, 대소문자 무시) |
| `tables[].title` | | 업무 이름. DB 코멘트가 비어 있으면 논리명으로 쓴다 |
| `tables[].description` | | 행 하나가 무엇인지 |
| `tables[].terms` | | 이 데이터를 찾을 때 쓰는 말. 질문에 나오면 이 테이블을 자세히 본다 |
| `tables[].notes` | | 조회 규칙 (소프트 삭제, 상태 조건, 조인 방법) |
| `columns[].name` | ✔ | 컬럼 이름 |
| `columns[].title` · `description` · `terms` | | 테이블과 같음 |
| `columns[].values` | | 코드 값의 뜻 `{"값": "뜻"}` — 실제 데이터 행이 아니라 코드의 enum · 상수 |
| `columns[].references` | | DB 에 FK 가 없어도 코드에서 잇는 곳 `"테이블.컬럼"` |

모르는 칸은 빼면 된다. 실제 데이터 행 · 개인 정보는 넣지 않는다.

## 분석 요청문

창의 [복사] 가 아래 글을 (DB 이름 · 종류를 채워) 복사한다. 영어 설정이면 영어로.

```text
이 저장소의 소스 코드를 보고 PostgreSQL DB `shop` 의 모든 테이블을 설명해 줘.
지금 테이블 · 컬럼 이름이 들어 있는 빈 양식 JSON 을 붙였어. 같은 양식을 지켜 채운 JSON 만 돌려줘.

- format "goddb-table-descriptions", version 1, database "shop", generatedBy, generatedAt (YYYY-MM-DD)
- overview: 이 DB 의 업무 도메인을 2~3문장으로
- tables[].title: 업무 이름, description: 행 하나가 무엇인지, terms: 사람들이 이 데이터를 찾을 때 쓰는 말
- tables[].columns[]: title, description (뻔하지 않을 때만), terms, references (FK 가 없어도 코드에서 잇는 곳 "테이블.컬럼")
- columns[].values: 코드 값의 뜻, 예 {"P": "결제 대기", "C": "완료"} — 코드의 enum · 상수에서
- tables[].notes: 조회할 때 규칙 (소프트 삭제, 상태 조건, 어떤 컬럼으로 잇는지)

규칙: 빈 양식에 있는 이름만 쓰고, 코드에 근거해서 쓰고, 확실하지 않으면 그 칸은 빼고, 실제 데이터 행이나 개인 정보는 넣지 마.
```

테이블이 많으면 도메인별로 나눠 맡긴 뒤 `tables` 를 한 파일로 합쳐 가져온다.
