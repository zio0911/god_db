# GodDB 패치

원본: https://github.com/vapor/postgres-nio 1.33.3 (MIT)

변경 1줄: `Sources/PostgresNIO/New/PostgresFrontendMessageEncoder.swift` 의 Bind 메시지에서
결과 컬럼 형식을 `binary` → `text` 로 바꿨다.

이유: 원본은 결과를 항상 바이너리로 받는데, DB 클라이언트인 GodDB는 모든 타입(numeric, timestamp,
interval, 배열, 사용자 정의 타입 …)을 psql 과 같은 문자열로 보여줘야 한다. 텍스트 형식이면 서버가
문자열로 변환해 보내므로 타입별 디코딩이 필요 없다.

원본을 업데이트할 때는 이 한 줄만 다시 적용하면 된다.

## 변경 2: 빌드 경고 숨기기 (`Package.swift`)

`swiftSettings` 에 `.unsafeFlags(["-suppress-warnings"])` 를 넣었다. 원본 코드의 경고(macOS 13 이전 Sendable,
안 쓰는 반환값, 기본값 추론 등)가 GodDB 빌드 출력을 덮어 GodDB 자체 경고를 찾기 어려웠다. 동작에는 영향이 없다.
원본을 업데이트할 때 이 한 줄도 다시 넣는다.

## 변경 3: 서버 인증서 확인 콜백 (F9-3, #122)

- `Sources/PostgresNIO/Connection/PostgresConnection+Configuration.swift` — `Configuration.TLS` 에
  `customVerificationCallback`(NIOSSL 사용자 정의 확인 콜백, 기본 nil) 속성을 더했다.
- `Sources/PostgresNIO/Connection/PostgresConnection.swift` — TLS 핸들러를 만들 때 콜백이 있으면
  `NIOSSLClientHandler(context:serverHostname:customVerificationCallback:)` 를 쓴다.

이유: GodDB 는 "시스템 신뢰 저장소 확인 → 실패 시 고정 지문 비교" 를 직접 하고, 실패한 인증서 정보를 화면에 보여 줘야 한다.
원본은 `NIOSSLContext` 만 받아 콜백을 넣을 수 없다. 원본을 업데이트할 때 이 두 곳도 다시 적용한다.
