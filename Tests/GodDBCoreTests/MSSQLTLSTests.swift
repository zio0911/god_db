import Foundation
import Testing
@testable import GodDBCore

/// F9-3 SQL Server 인증서 확인 — PRELOGIN 패킷 · FreeTDS 확인 설정 · 연결별 설정 파일
@Suite("SQL Server TLS", .serialized)
struct MSSQLTLSTests {
    @Test func preloginPacket() {
        let payload = MSSQLTLS.preloginPayload()
        // 옵션 5개(5바이트씩) + 끝(0xFF) 뒤에 값, ENCRYPTION = ON
        #expect(payload[25] == 0xFF)
        #expect(MSSQLTLS.encryption(inPreloginResponse: payload) == .on)
        let packets = MSSQLTLS.packets(payload)
        #expect(Array(packets.prefix(8)) == [0x12, 0x01, 0x00, UInt8(payload.count + 8), 0, 0, 1, 0])
        // 큰 페이로드는 나눠 담고 마지막에만 EOM
        let big = MSSQLTLS.packets([UInt8](repeating: 7, count: 5000), maxSize: 4096)
        #expect(big.count == 5000 + 16)
        #expect(big[1] == 0x00 && (Int(big[2]) << 8 | Int(big[3])) == 4096)
        #expect(big[4096 + 1] == 0x01 && big[4096 + 6] == 2)
    }

    @Test func preloginResponseEncryption() {
        // 테스트 서버의 실제 응답: VERSION · ENCRYPTION=ON · INSTOPT · THREADID · MARS
        let response: [UInt8] = [0x00, 0x00, 0x1a, 0x00, 0x06, 0x01, 0x00, 0x20, 0x00, 0x01, 0x02, 0x00, 0x21, 0x00, 0x01,
                                 0x03, 0x00, 0x22, 0x00, 0x00, 0x04, 0x00, 0x22, 0x00, 0x01, 0xff,
                                 0x10, 0x00, 0x10, 0xdb, 0x00, 0x00, 0x01, 0x00, 0x00]
        #expect(MSSQLTLS.encryption(inPreloginResponse: response) == .on)
        var notSup = response
        notSup[32] = 0x02
        #expect(MSSQLTLS.encryption(inPreloginResponse: notSup) == .notSupported)
        #expect(MSSQLTLS.encryption(inPreloginResponse: [0x01, 0x00]) == nil)
    }

    @Test func freeTDSCheckFromVerdict() throws {
        let der = try TLSVerifyTests.selfSignedDER()
        // 고정 · 자체 서명 → 그 인증서만 CA 로, 이름 확인 안 함
        let pinned = MSSQLTLS.freeTDSCheck(verdict: .pinned, chain: [der], hostname: "db.example.com")
        #expect(pinned?.hostname == nil)
        #expect(pinned?.caPEM == MSSQLTLS.pem(der))
        #expect(TLSVerify.der(fromPEM: MSSQLTLS.pem(der)) == der)
        // 유효 기간 밖이면 FreeTDS 는 확인하지 못함 → 암호화만
        #expect(MSSQLTLS.freeTDSCheck(verdict: .pinned, chain: [der], hostname: nil,
                                      now: Date(timeIntervalSince1970: 2_200_000_000)) == nil)
        // 확인 안 함 · 거부는 FreeTDS 설정 없음
        #expect(MSSQLTLS.freeTDSCheck(verdict: .unchecked, chain: [der], hostname: nil) == nil)
        #expect(MSSQLTLS.freeTDSCheck(verdict: .pinMismatch, chain: [der], hostname: nil) == nil)
        #expect(MSSQLTLS.systemRootsPEM.contains("-----BEGIN CERTIFICATE-----"))
    }

    @Test func configSection() throws {
        let text = MSSQLConfigFile.sectionText(name: "goddb-x", ip: "10.0.0.5", port: 1433, caFile: "/tmp/x.pem", hostname: "db.example.com")
        #expect(text.contains("[goddb-x]\n\thost = 10.0.0.5\n\tport = 1433\n"))
        #expect(text.contains("\tencryption = require\n\tca file = /tmp/x.pem\n"))
        #expect(text.contains("\tcheck certificate hostname = yes\n\tcertificate hostname = db.example.com\n"))
        #expect(MSSQLConfigFile.sectionText(name: "n", ip: "1", port: 1, caFile: "c", hostname: nil)
            .contains("check certificate hostname = no"))

        // 0600 파일로 쓰고, 빼면 지운다
        let entry = try MSSQLConfigFile.add(ip: "127.0.0.1", port: 1, check: MSSQLTLS.FreeTDSCheck(caPEM: "x", hostname: nil))
        let attrs = try FileManager.default.attributesOfItem(atPath: MSSQLConfigFile.path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let caAttrs = try FileManager.default.attributesOfItem(atPath: entry.caFile.path)
        #expect((caAttrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(try String(contentsOfFile: MSSQLConfigFile.path, encoding: .utf8).contains("[\(entry.name)]"))
        MSSQLConfigFile.remove(entry)
        #expect(!FileManager.default.fileExists(atPath: entry.caFile.path))
    }
}
