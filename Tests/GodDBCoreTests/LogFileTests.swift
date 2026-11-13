import Foundation
import Testing
@testable import GodDBCore

@Suite("LogFile")
struct LogFileTests {
    @Test func appendsDailyFileWithIndentedDetail() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("goddb-log-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = LogFile(directory: dir)
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        file.append(LogEntry(date: date, level: .success, source: .query, message: "실행 1행",
                             detail: "UPDATE t\nSET a = 1"))
        file.append(LogEntry(date: date, level: .error, source: .connection, message: "연결 실패"))
        file.flush()
        let text = try String(contentsOf: file.url(for: date), encoding: .utf8)
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines.count == 4)
        #expect(lines[0].contains("SUCCESS") && lines[0].hasSuffix("실행 1행"))
        #expect(lines[1] == "    UPDATE t")
        #expect(lines[2] == "    SET a = 1")
        #expect(lines[3].contains("ERROR") && lines[3].hasSuffix("연결 실패"))
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
        file.append(LogEntry(level: .info, source: .app, message: "시작"))
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
        file.append(LogEntry(level: .info, source: .app, message: "시작"))
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
        #expect(LogFile.format(LogEntry(level: .info, source: .app, message: "m"), identity: "kim@pc").contains("INFO    [kim@pc] ["))
    }

    @Test func sourceIPToLocalhostAndAddresses() {
        #expect(ClientInfo.sourceIP(toward: "127.0.0.1", port: 3306) == "127.0.0.1")
        #expect(ClientInfo.addresses().allSatisfy { !$0.ip.hasPrefix("127.") && !$0.ip.lowercased().hasPrefix("fe80") })
        #expect(ClientInfo.connectionNote(host: "127.0.0.1", port: 1, ssh: nil) == "client 127.0.0.1 → 127.0.0.1:1")
        #expect(ClientInfo.connectionNote(host: "db", port: 3306, ssh: SSHConfig(host: "127.0.0.1", port: 22)).hasPrefix("client 127.0.0.1 → ssh 127.0.0.1:22 → db:3306"))
    }
}
