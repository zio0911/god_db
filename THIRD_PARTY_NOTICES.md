# Third-party notices

GodDB는 MIT 라이선스이며 아래 오픈소스를 사용합니다. 전체 라이선스 원문은 앱의 **설정 > 라이선스** 또는 각 프로젝트 저장소에서 볼 수 있습니다.

| 이름 | 버전 | 라이선스 | 저작권 | 비고 |
|---|---|---|---|---|
| [mysql-nio](https://github.com/vapor/mysql-nio) | 1.9.3 | MIT | Copyright (c) Qutheory, LLC | MySQL 드라이버 |
| [postgres-nio](https://github.com/vapor/postgres-nio) | 1.33.3 (GodDB 패치) | MIT | Copyright (c) Tanner Nelson | PostgreSQL 드라이버 — 결과를 텍스트 형식으로 받도록 1줄 수정 (Vendor/postgres-nio/GODDB_PATCH.md) |
| [SwiftNIO](https://github.com/apple/swift-nio) | 2.105.0 | Apache-2.0 | Copyright (c) Apple Inc. and the Swift project authors |  |
| [SwiftNIO SSL](https://github.com/apple/swift-nio-ssl) | 2.37.6 | Apache-2.0 | Copyright (c) Apple Inc. and the Swift project authors | NIOSSL 에는 BoringSSL(OpenSSL/ISC 계열 라이선스)이 포함돼요. |
| [SwiftNIO Transport Services](https://github.com/apple/swift-nio-transport-services) | 1.28.0 | Apache-2.0 | Copyright (c) Apple Inc. and the Swift project authors |  |
| [Swift Crypto](https://github.com/apple/swift-crypto) | 5.1.1 | Apache-2.0 | Copyright (c) Apple Inc. and the Swift project authors |  |
| [SwiftLog](https://github.com/apple/swift-log) | 1.17.0 | Apache-2.0 | Copyright (c) Apple Inc. and the Swift project authors |  |
| [Swift Metrics](https://github.com/apple/swift-metrics) | 2.13.0 | Apache-2.0 | Copyright (c) Apple Inc. and the Swift project authors |  |
| [Swift Collections](https://github.com/apple/swift-collections) | 1.7.6 | Apache-2.0 | Copyright (c) Apple Inc. and the Swift project authors |  |
| [Swift Algorithms](https://github.com/apple/swift-algorithms) | 1.2.1 | Apache-2.0 | Copyright (c) Apple Inc. and the Swift project authors |  |
| [Swift Async Algorithms](https://github.com/apple/swift-async-algorithms) | 1.1.7 | Apache-2.0 | Copyright (c) Apple Inc. and the Swift project authors |  |
| [Swift Atomics](https://github.com/apple/swift-atomics) | 1.3.1 | Apache-2.0 | Copyright (c) Apple Inc. and the Swift project authors |  |
| [Swift Numerics](https://github.com/apple/swift-numerics) | 1.1.1 | Apache-2.0 | Copyright (c) Apple Inc. and the Swift project authors |  |
| [Swift System](https://github.com/apple/swift-system) | 1.8.1 | Apache-2.0 | Copyright (c) Apple Inc. and the Swift project authors |  |
| [Swift ASN.1](https://github.com/apple/swift-asn1) | 1.7.4 | Apache-2.0 | Copyright (c) Apple Inc. and the Swift project authors |  |
| [Swift Service Lifecycle](https://github.com/swift-server/swift-service-lifecycle) | 2.13.0 | Apache-2.0 | Copyright (c) Apple Inc. and the Swift project authors |  |
| [OpenSSL](https://www.openssl.org) | 4.x (앱에 포함) | Apache-2.0 | Copyright (c) The OpenSSL Project Authors | FreeTDS 의 암호화 연결용. libssl·libcrypto 를 GodDB.app/Contents/Frameworks 에 넣어 동적으로 연결해요. |
| [FreeTDS](https://www.freetds.org) | 1.5 (앱에 포함) | LGPL-2.0 | Copyright (c) FreeTDS contributors | SQL Server 드라이버. 고치지 않은 libsybdb 동적 라이브러리를 GodDB.app/Contents/Frameworks 에 넣어 실행 시 연결해요 (같은 이름의 라이브러리로 바꿔 끼울 수 있음). 소스: https://www.freetds.org |
