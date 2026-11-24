import Foundation
import Testing
@testable import GodDBCore

/// SQL Server: 행을 읽는 도중 연결이 끊기면 받은 데까지를 정상 결과처럼 돌려주지 않는다 (#192)
@Suite("SQL Server partial results", .serialized, .enabled(if: MultiDB.env["GODDB_MSSQL_PORT"] != nil))
struct MSSQLPartialResultTests {
    @Test func killedWhileReadingIsAnErrorNotFewerRows() async throws {
        let (p, pw) = try #require(MultiDB.profile(.mssql, database: "master"))
        let reader = try await DBSession.connect(profile: p, password: pw)
        let killer = try await DBSession.connect(profile: p, password: pw)
        defer { Task { await reader.close(); await killer.close() } }
        let spid = try #require(try await reader.raw("SELECT @@SPID").rows.first?.first ?? nil)

        let total = 2_000_000
        let big = "SELECT TOP \(total) a.object_id FROM sys.all_objects a CROSS JOIN sys.all_objects b CROSS JOIN sys.all_objects c"
        let reading = Task { () -> Result<Int, Error> in
            do { return .success(try await reader.raw(big).rows.count) } catch { return .failure(error) }
        }
        try await Task.sleep(for: .milliseconds(700))
        _ = try? await killer.raw("KILL \(spid)")

        switch await reading.value {
        case .success(let n):
            // 끊기기 전에 다 읽었을 수는 있다 — 그렇다면 전부여야 한다 (일부만은 안 됨)
            #expect(n == total, "읽는 도중 끊겼는데 \(n)행을 정상 결과로 돌려줌")
        case .failure:
            break
        }
    }

    /// 읽는 도중 서버 오류(0 으로 나누기)도 일부 행이 아니라 오류
    @Test func serverErrorMidStreamIsAnError() async throws {
        let (p, pw) = try #require(MultiDB.profile(.mssql, database: "master"))
        let s = try await DBSession.connect(profile: p, password: pw)
        defer { Task { await s.close() } }
        await #expect(throws: (any Error).self) {
            _ = try await s.raw("SELECT 10 / (v - 3) FROM (VALUES (1), (2), (3), (4)) t(v)")
        }
    }
}
