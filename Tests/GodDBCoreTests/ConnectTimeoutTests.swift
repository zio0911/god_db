import Foundation
import Testing
@testable import GodDBCore

/// 스키마 비교 · 일반 접속에서 서버가 응답하지 않으면 끝없이 기다리던 문제
@Suite("DB connect timeout", .serialized)
struct ConnectTimeoutTests {
    /// nc 로 연결만 받고 응답하지 않는 포트를 연다 (SSH 터널 너머가 안 붙는 경우와 같다)
    func silentServer() throws -> (Process, Int) {
        let port = Int.random(in: 38_000..<38_900)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        p.arguments = ["-l", "127.0.0.1", "\(port)"]
        p.standardInput = Pipe()  // 입력이 열려 있어야 연결을 받은 뒤 닫지 않는다
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        Thread.sleep(forTimeInterval: 0.5)
        return (p, port)
    }

    @Test(arguments: [DatabaseKind.mysql, .postgres])
    func silentServerFailsWithinTimeout(_ kind: DatabaseKind) async throws {
        let (nc, port) = try silentServer()
        defer { nc.terminate() }
        let profile = ConnectionProfile(kind: kind, name: "silent", host: "127.0.0.1", port: port,
                                        username: "u", database: "", useTLS: false)
        let started = Date()
        await #expect(throws: DBConnectTimeoutError.self) {
            _ = try await DBSession.connect(profile: profile, password: "p", timeout: 2)
        }
        #expect(Date().timeIntervalSince(started) < 5)
    }

    /// 닿지 않는 주소 (패킷이 버려짐)
    @Test func unroutableAddressFailsWithinTimeout() async throws {
        let profile = ConnectionProfile(kind: .mysql, name: "unroutable", host: "10.255.255.1", port: 3306,
                                        username: "u", database: "", useTLS: false)
        let started = Date()
        await #expect(throws: (any Error).self) {
            _ = try await DBSession.connect(profile: profile, password: "p", timeout: 3)
        }
        #expect(Date().timeIntervalSince(started) < 6)
    }

    @Test func deadlineReturnsFastResult() async throws {
        let v = try await ConnectDeadline.run(seconds: 5) { 42 }
        #expect(v == 42)
    }

    @Test func deadlinePassesErrorThrough() async {
        struct Boom: Error {}
        await #expect(throws: Boom.self) {
            _ = try await ConnectDeadline.run(seconds: 5) { () async throws -> Int in throw Boom() }
        }
    }

    /// 시간이 지난 뒤 끝난 결과는 late 로 넘겨 정리한다
    @Test func lateResultIsHandedOver() async throws {
        let got = LateBox()
        await #expect(throws: DBConnectTimeoutError.self) {
            _ = try await ConnectDeadline.run(seconds: 0.2, late: { got.set($0) }) { () async -> Int in
                // 취소를 모르는 작업처럼 끝까지 돈다
                let start = Date()
                while Date().timeIntervalSince(start) < 0.6 { usleep(20_000) }
                return 7
            }
        }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        #expect(got.value == 7)
    }

    /// 호출한 쪽이 취소하면 (비교 화면의 취소 버튼) 기다리지 않고 끝난다
    @Test func cancellingCallerStopsWaiting() async {
        let started = Date()
        let task = Task {
            try await ConnectDeadline.run(seconds: 30) { () async -> Int in
                let start = Date()
                while Date().timeIntervalSince(start) < 3 { usleep(20_000) }
                return 1
            }
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()
        let result = await task.result
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(Date().timeIntervalSince(started) < 2)
    }

    @Test func timeoutErrorIsDescribed() {
        let d = ErrorText.describe(DBConnectTimeoutError(seconds: 15))
        #expect(d.message.contains("15초"))
        #expect(d.hint != nil)
    }
}

private final class LateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var v: Int?
    func set(_ x: Int) { lock.lock(); v = x; lock.unlock() }
    var value: Int? { lock.lock(); defer { lock.unlock() }; return v }
}

@Suite("SchemaDiff copy")
struct SchemaDiffCopyTests {
    let items = [
        SchemaDiffItem(kind: .missingTable, table: "a", object: nil, detail: "", fixSQL: "CREATE TABLE a (id int);"),
        SchemaDiffItem(kind: .extraTable, table: "b", object: nil, detail: "", fixSQL: nil),
        SchemaDiffItem(kind: .missingColumn, table: "c", object: "x", detail: "", fixSQL: "ALTER TABLE c ADD COLUMN x int;"),
        SchemaDiffItem(kind: .differentIndex, table: "d", object: "ix", detail: "", fixSQL: "ALTER TABLE d DROP INDEX ix, ADD INDEX ix (y);"),
    ]

    @Test func joinsSelectedInListOrderWithBlankLines() {
        // 고른 순서가 아니라 목록 순서
        let selected: Set = [items[3].id, items[0].id]
        #expect(SchemaDiffReport.fixSQL(of: items, selected: selected)
                == "CREATE TABLE a (id int);\n\nALTER TABLE d DROP INDEX ix, ADD INDEX ix (y);")
    }

    @Test func singleSelectionMatchesItsSQL() {
        #expect(SchemaDiffReport.fixSQL(of: items, selected: [items[2].id]) == items[2].fixSQL)
    }

    @Test func skipsReferenceOnlyItems() {
        #expect(SchemaDiffReport.fixSQL(of: items, selected: [items[1].id]) == "")
        #expect(SchemaDiffReport.fixSQL(of: items, selected: Set(items.map(\.id)))
                == items.compactMap(\.fixSQL).joined(separator: "\n\n"))
        #expect(SchemaDiffReport.fixSQL(of: items, selected: []) == "")
    }
}
