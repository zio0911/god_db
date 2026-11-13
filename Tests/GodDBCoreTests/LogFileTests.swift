import Foundation
import Testing
@testable import GodDBCore

@Suite("LogFile")
struct LogFileTests {
    @Test func writesOneTabSeparatedLinePerAuditedAction() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("goddb-log-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = LogFile(directory: dir)
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        file.append(LogEntry(date: date, level: .success, source: .query, message: "실행 1행", detail: "UPDATE t\nSET a = 1",
                             audit: AuditRecord(.update, target: "dev/shop", result: "1행 · 3ms", statement: "UPDATE t\nSET\ta = 1")))
        // 감사 대상이 아니면 파일에 남지 않는다 (AI 질문 내용, 화면 이동 등)
        file.append(LogEntry(date: date, level: .info, source: .schema, message: "다이어그램 AI", detail: "오늘 날씨 알려줘"))
        file.append(LogEntry(date: date, level: .error, source: .connection, message: "연결 실패",
                             audit: AuditRecord(.connect, target: "dev", result: "실패: 비밀번호 오류")))
        file.flush()
        #expect(file.url(for: date).lastPathComponent.hasPrefix("goddb-audit-"))
        let data = try Data(contentsOf: file.url(for: date))
        #expect(data.prefix(3) == Data([0xEF, 0xBB, 0xBF]))
        let text = try String(contentsOf: file.url(for: date), encoding: .utf8)
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines.count == 3)
        #expect(lines[0] == "시각\t사용자@PC\t구분\t대상\t결과\t내용")
        let cols = lines[1].components(separatedBy: "\t")
        #expect(cols.count == 6)
        #expect(cols[2] == "수정" && cols[3] == "dev/shop" && cols[4] == "1행 · 3ms" && cols[5] == "UPDATE t SET a = 1")
        #expect(lines[2].components(separatedBy: "\t")[2] == "접속")
        #expect(!text.contains("날씨"))
        let perms = try FileManager.default.attributesOfItem(atPath: file.url(for: date).path)[.posixPermissions] as? Int
        #expect(perms == 0o600)
    }

    @Test func removesFilesOlderThanKeepDays() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("goddb-log-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let old = dir.appendingPathComponent("goddb-2000-01-01.log")
        try Data("x".utf8).write(to: old)
        let file = LogFile(directory: dir, keepDays: 30)
        file.append(LogEntry(level: .info, source: .app, message: "시작", audit: AuditRecord(.appStart)))
        file.flush()
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: file.url(for: Date()).path))
    }

    @Test func keepsOldFilesByDefault() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("goddb-log-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let old = dir.appendingPathComponent("goddb-2000-01-01.log")
        try Data("x".utf8).write(to: old)
        let file = LogFile(directory: dir)
        file.append(LogEntry(level: .info, source: .app, message: "시작", audit: AuditRecord(.appStart)))
        file.flush()
        #expect(FileManager.default.fileExists(atPath: old.path))
    }
}

@Suite("ClientInfo")
struct ClientInfoTests {
    /// 이름 읽기는 네트워크 조회 없이 바로 끝나야 한다 (앱 시작이 멈추던 문제)
    @Test func namesAreQuickAndNonEmpty() {
        let start = Date()
        #expect(!ClientInfo.computerName.isEmpty)
        #expect(!ClientInfo.hostName.isEmpty)
        #expect(!ClientInfo.identity.contains(" "))
        #expect(Date().timeIntervalSince(start) < 1)
    }

    @Test func identityAndSummary() {
        #expect(ClientInfo.identity.hasPrefix(NSUserName() + "@"))
        #expect(!ClientInfo.identity.contains(" "))
        let s = ClientInfo.summary()
        #expect(s.contains("user: \(NSUserName())") && s.contains("computer:") && s.contains("ip:") && s.contains("os: macOS"))
        #expect(LogFile.format(LogEntry(level: .info, source: .app, message: "m", audit: AuditRecord(.appStart)), identity: "kim@pc")
            .components(separatedBy: "\t")[1] == "kim@pc")
    }

    @Test func sourceIPToLocalhostAndAddresses() {
        #expect(ClientInfo.sourceIP(toward: "127.0.0.1", port: 3306) == "127.0.0.1")
        #expect(ClientInfo.addresses().allSatisfy { !$0.ip.hasPrefix("127.") && !$0.ip.lowercased().hasPrefix("fe80") })
        #expect(ClientInfo.connectionNote(host: "127.0.0.1", port: 1, ssh: nil) == "client 127.0.0.1 → 127.0.0.1:1")
        #expect(ClientInfo.connectionNote(host: "db", port: 3306, ssh: SSHConfig(host: "127.0.0.1", port: 22)).hasPrefix("client 127.0.0.1 → ssh 127.0.0.1:22 → db:3306"))
    }
}


@Suite("Audit classify")
struct AuditClassifyTests {
    @Test func sqlActions() {
        #expect(AuditRecord.classify(sql: "-- 메모\nSELECT 1") == .read)
        #expect(AuditRecord.classify(sql: "show tables") == .read)
        #expect(AuditRecord.classify(sql: "INSERT INTO t VALUES (1)") == .insert)
        #expect(AuditRecord.classify(sql: "update t set a=1") == .update)
        #expect(AuditRecord.classify(sql: "DELETE FROM t WHERE id=1") == .delete)
        #expect(AuditRecord.classify(sql: "TRUNCATE TABLE t") == .delete)
        #expect(AuditRecord.classify(sql: "ALTER TABLE t ADD c int") == .ddl)
        #expect(AuditRecord.classify(sql: "DROP TABLE t") == .ddl)
        #expect(AuditRecord.classify(sql: "GRANT SELECT ON t TO u") == .grant)
        #expect(AuditRecord.classify(sql: "CALL p()") == .execute)
        #expect(AuditRecord.classify(sql: "WITH x AS (SELECT 1) SELECT * FROM x") == .read)
        #expect(AuditRecord.classify(sql: "WITH x AS (SELECT id FROM a) DELETE FROM b USING x") == .delete)
    }

    @Test func redisActions() {
        #expect(AuditRecord.classify(redis: ["get", "k"]) == .read)
        #expect(AuditRecord.classify(redis: ["HGETALL", "k"]) == .read)
        #expect(AuditRecord.classify(redis: ["SET", "k", "v"]) == .update)
        #expect(AuditRecord.classify(redis: ["EXPIRE", "k", "10"]) == .update)
        #expect(AuditRecord.classify(redis: ["DEL", "k"]) == .delete)
        #expect(AuditRecord.classify(redis: ["FLUSHDB"]) == .delete)
        #expect(AuditRecord.classify(redis: ["CONFIG", "GET", "*"]) == .read)
        #expect(AuditRecord.classify(redis: ["CONFIG", "SET", "x", "y"]) == .settings)
        #expect(AuditRecord.classify(redis: ["PUBLISH", "c", "m"]) == .execute)
    }

    @Test func cellIsOneLine() {
        #expect(AuditRecord.cell("SELECT *\n  FROM\tt\r\n WHERE a = 1  ") == "SELECT * FROM t WHERE a = 1")
        #expect(AuditRecord.cell(String(repeating: "a", count: 30), limit: 10).hasPrefix("aaaaaaaaaa …(30자"))
    }
}
