# GodDB 패치

원본: https://github.com/vapor/mysql-nio 1.9.3 (MIT)

변경:
1. `Sources/MySQLNIO/Protocol/MySQLProtocol+CapabilityFlags.swift` — 접속할 때 `CLIENT_MULTI_RESULTS` 를 보낸다.
2. `Sources/MySQLNIO/MySQLSimpleQueryCommand.swift` — 결과 집합 끝 / OK 패킷의 `SERVER_MORE_RESULTS_EXISTS` 를 보고
   다음 결과 집합(또는 프로시저의 마지막 상태 OK)까지 이어서 받는다.

이유: 원본은 `CLIENT_MULTI_RESULTS` 를 보내지 않아 MySQL 서버가 결과 집합을 돌려주는 프로시저의 `CALL` 을
"can't return a result set in the given context" 로 거부한다.

3. 서버 인증서 확인 · TLS 필수 (F9-3, #122)
   - `Sources/MySQLNIO/MySQLConnection.swift` — `connect(...)` 에 `customVerificationCallback`(NIOSSL 사용자 정의 확인 콜백)과
     `requireTLS` 인자를 더했다 (기본값 nil / false 라 원본 호출은 그대로 동작). `MySQLConnection.tlsNotSupportedMessage` 상수 추가.
   - `Sources/MySQLNIO/MySQLConnectionHandler.swift` — `HandshakeState` 에 두 값을 담고, TLS 로 올릴 때 콜백이 있으면
     `NIOSSLClientHandler(context:serverHostname:customVerificationCallback:)` 로 만든다.
     `requireTLS` 인데 서버가 `CLIENT_SSL` 을 알리지 않으면 평문으로 내려가지 않고
     `MySQLError.unsupportedServer(message: MySQLConnection.tlsNotSupportedMessage)` 로 실패한다.

   이유: 원본은 `TLSConfiguration` 만 받아 GodDB 가 "시스템 신뢰 저장소 확인 → 실패 시 고정 지문 비교" 를 넣을 수 없고,
   서버가 TLS 를 안 하면 조용히 평문으로 접속한다.

원본을 업데이트할 때는 위 세 가지를 다시 적용하면 된다.
