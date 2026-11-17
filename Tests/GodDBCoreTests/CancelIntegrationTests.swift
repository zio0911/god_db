import Foundation
import Testing
@testable import GodDBCore

/// 실행 중인 쿼리 취소 (실제 DB). test-dbs.sh test 로 실행. 환경변수가 없으면 건너뛴다.
@Suite("Cancel integration", .serialized)
struct CancelIntegrationTests {
    func sleepSQL(_ kind: DatabaseKind) -> String {
        switch kind {
        case .mysql: "SELECT SLEEP(20)"
        case .postgres: "SELECT pg_sleep(20)"
        default: "WAITFOR DELAY '00:00:20'"
        }
    }

    @Test(arguments: [DatabaseKind.mysql, .postgres, .mssql])
    func cancelLongQuery(_ kind: DatabaseKind) async throws {
        guard let s = try await ExportIntegrationTests().session(kind) else { return }
        defer { Task { await s.close() } }
        let started = Date()
        let running = Task { try await s.execute(sleepSQL(kind), limit: 0) }
        try await Task.sleep(for: .milliseconds(800))
        #expect(await s.isRunning)
        #expect(try await s.cancelRunning())
        var cancelled = false
        do { _ = try await running.value } catch DBError.cancelled { cancelled = true } catch {}
        #expect(cancelled)   // MySQL SLEEP 처럼 오류 없이 끝나도 취소로 본다
        #expect(Date().timeIntervalSince(started) < 10)
        // 취소 뒤에도 같은 세션으로 계속 쓸 수 있다 (SQL Server 는 다시 연결됨)
        let r = try await s.raw("SELECT 1")
        #expect(r.rows.first?.first == "1")
        #expect(await s.isRunning == false)
        #expect(try await s.cancelRunning() == false)
    }
}
