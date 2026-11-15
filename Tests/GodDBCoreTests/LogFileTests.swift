import Foundation
import Testing
@testable import GodDBCore
import CryptoKit

@Suite("LogFile")
struct LogFileTests {
    @Test func writesOneTabSeparatedLinePerAuditedAction() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("goddb-log-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let signer = AuditChain.Signer.software()
        let file = LogFile(directory: dir, retention: { 0 }, signer: { signer })
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
        #expect(lines.count == 4)   // 머리글 + 체인 + 2행
        #expect(lines[0] == "시각\t사용자@PC\t구분\t대상\t결과\t내용\t무결성\t서명")
        #expect(lines[1].components(separatedBy: "\t")[2] == "체인")
        let cols = lines[2].components(separatedBy: "\t")
        #expect(cols.count == 8)
        #expect(cols[2] == "수정" && cols[3] == "dev/shop" && cols[4] == "1행 · 3ms" && cols[5] == "UPDATE t SET a = 1")
        #expect(cols[6].count == 64)
        #expect(lines[3].components(separatedBy: "\t")[2] == "접속")
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
        let file = LogFile(directory: dir, keepDays: 30, signer: { nil })
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
        let file = LogFile(directory: dir, retention: { 0 }, signer: { nil })
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

@Suite("Log retention", .serialized)
struct LogRetentionTests {
    @Test func retentionSettingDeletesOldFilesAndHasMinimum() throws {
        let saved = UserDefaults.standard.object(forKey: "GodDB.logFile.keepDays")
        defer { UserDefaults.standard.set(saved, forKey: "GodDB.logFile.keepDays") }
        LogFile.retentionDays = 30
        #expect(LogFile.retentionDays == 90)          // 최소 90일
        LogFile.retentionDays = 0
        #expect(LogFile.retentionDays == 0)           // 영구

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("goddb-ret-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
        let old = dir.appendingPathComponent("goddb-audit-\(f.string(from: Date().addingTimeInterval(-200 * 86400))).tsv")
        let recent = dir.appendingPathComponent("goddb-audit-\(f.string(from: Date().addingTimeInterval(-100 * 86400))).tsv")
        for u in [old, recent] { try Data("x".utf8).write(to: u) }
        let file = LogFile(directory: dir, retention: { 180 })
        file.cleanNow(); file.flush()
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: recent.path))
    }
}


@Suite("Audit integrity")
struct AuditIntegrityTests {
    func write(_ dir: URL, key: AuditChain.Signer, days: [Date], perDay: Int = 3) {
        let file = LogFile(directory: dir, retention: { 0 }, signer: { key })
        for d in days {
            for i in 0..<perDay {
                file.append(LogEntry(date: d.addingTimeInterval(Double(i)), level: .success, source: .query, message: "",
                                     audit: AuditRecord(.read, target: "dev/shop", result: "\(i)행", statement: "SELECT \(i)")))
            }
        }
        file.flush()
    }

    let day1 = Date(timeIntervalSince1970: 1_800_000_000)
    var day2: Date { day1.addingTimeInterval(86_400) }
    var day3: Date { day1.addingTimeInterval(2 * 86_400) }

    func tmp() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("goddb-int-\(UUID())") }

    @Test func intactLogsVerify() throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let key = AuditChain.Signer.software()
        write(dir, key: key, days: [day1, day2, day3])
        let r = AuditChain.verify(directory: dir)
        #expect(r.count == 3)
        #expect(r.allSatisfy { $0.status == .ok })
        // 다시 열어서 이어 쓰기 (앱 재시작)
        write(dir, key: key, days: [day3], perDay: 1)
        #expect(AuditChain.verify(directory: dir).allSatisfy { $0.status == .ok })
    }

    @Test func editedLineIsDetected() throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let key = AuditChain.Signer.software()
        write(dir, key: key, days: [day1])
        let f = try #require(try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).first)
        var text = try String(contentsOf: f, encoding: .utf8)
        text = text.replacingOccurrences(of: "SELECT 1", with: "SELECT 9")       // 3번째 기록 줄(파일 4번째 줄) 수정
        try text.write(to: f, atomically: true, encoding: .utf8)
        let r = AuditChain.verify(directory: dir)
        #expect(r.first?.status == .broken(line: 4, reason: "이 줄이 바뀌었거나, 앞 줄이 지워졌거나 끼워 넣어졌어요"))
    }

    @Test func deletedLineIsDetected() throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let key = AuditChain.Signer.software()
        write(dir, key: key, days: [day1])
        let f = try #require(try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).first)
        var rows = try String(contentsOf: f, encoding: .utf8).components(separatedBy: "\n")
        rows.remove(at: 3)                                                           // 기록 한 줄 삭제
        try rows.joined(separator: "\n").write(to: f, atomically: true, encoding: .utf8)
        if case .broken(let line, _) = AuditChain.verify(directory: dir).first?.status {
            #expect(line == 4)
        } else {
            Issue.record("삭제를 찾지 못함")
        }
    }

    @Test func keyChangeIsReported() throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        write(dir, key: AuditChain.Signer.software(), days: [day1])
        write(dir, key: AuditChain.Signer.software(), days: [day2])   // 다른 키로 쓴 다음 날 파일
        let r = AuditChain.verify(directory: dir)
        if case .unlinked(let reason) = r.last?.status { #expect(reason.contains("기기 키")) } else { Issue.record("키 변경을 못 찾음") }
    }

    @Test func deletedOrReplacedFileIsDetected() throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let key = AuditChain.Signer.software()
        write(dir, key: key, days: [day1, day2, day3])
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        try FileManager.default.removeItem(at: files[1])                            // 가운데 날짜 파일 삭제
        let r = AuditChain.verify(directory: dir)
        #expect(r.count == 2)
        if case .unlinked = r[1].status {} else { Issue.record("파일 삭제를 찾지 못함: \(r[1].status)") }
    }

    @Test func otherKeyCannotForge() throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        write(dir, key: AuditChain.Signer.software(), days: [day1])
        // 내용을 고치고 무결성 값(SHA-256)까지 다시 계산해도, 기기 키 서명이 없으면 통과하지 못한다
        let f = try #require(try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).first)
        var rows = try String(contentsOf: f, encoding: .utf8).components(separatedBy: "\n")
        var cols = rows[3].components(separatedBy: "\t")
        cols[5] = "SELECT 999"
        let prevHash = rows[2].components(separatedBy: "\t")[6]
        cols[6] = AuditChain.hash(prev: prevHash, line: cols[0..<6].joined(separator: "\t"))
        rows[3] = cols.joined(separator: "\t")
        try rows.joined(separator: "\n").write(to: f, atomically: true, encoding: .utf8)
        let r = AuditChain.verify(directory: dir)
        if case .broken(let line, let reason) = r.first?.status {
            #expect(line == 4 && reason.contains("서명"))
        } else { Issue.record("다시 계산한 위조가 통과함") }
    }

    @Test func legacyFilesAreReported() throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "시각\t사용자@PC\t구분\t대상\t결과\t내용\nx\ty\t조회\td\tr\ts\n".write(
            to: dir.appendingPathComponent("goddb-audit-2026-01-01.tsv"), atomically: true, encoding: .utf8)
        #expect(AuditChain.verify(directory: dir).first?.status == .legacy)
    }
}
