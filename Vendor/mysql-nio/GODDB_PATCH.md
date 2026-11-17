# GodDB 패치

원본: https://github.com/vapor/mysql-nio 1.9.3 (MIT)

변경:
1. `Sources/MySQLNIO/Protocol/MySQLProtocol+CapabilityFlags.swift` — 접속할 때 `CLIENT_MULTI_RESULTS` 를 보낸다.
2. `Sources/MySQLNIO/MySQLSimpleQueryCommand.swift` — 결과 집합 끝 / OK 패킷의 `SERVER_MORE_RESULTS_EXISTS` 를 보고
   다음 결과 집합(또는 프로시저의 마지막 상태 OK)까지 이어서 받는다.

이유: 원본은 `CLIENT_MULTI_RESULTS` 를 보내지 않아 MySQL 서버가 결과 집합을 돌려주는 프로시저의 `CALL` 을
"can't return a result set in the given context" 로 거부한다.

원본을 업데이트할 때는 위 두 곳만 다시 적용하면 된다.
