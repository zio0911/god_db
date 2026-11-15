import Foundation
import Testing
@testable import GodDBCore

/// 수동 커밋 모드 (실제 DB). test-dbs.sh test 로 실행. 환경변수가 없으면 건너뛴다.
@Suite("Transaction integration", .serialized)
struct TransactionIntegrationTests {
    func session(_ kind: DatabaseKind) async throws -> DBSession? {
        try await ExportIntegrationTests().session(kind)
    }

    func count(_ s: DBSession) async throws -> Int {
        Int(try await s.raw("SELECT COUNT(*) FROM tb_tx_it").rows.first?.first??.description ?? "-1") ?? -1
    }

    @Test(arguments: [DatabaseKind.mysql, .postgres, .mssql])
    func manualCommitAndRollback(_ kind: DatabaseKind) async throws {
        guard let a = try await session(kind), let b = try await session(kind) else { return }
        defer { Task { await a.close(); await b.close() } }
        if kind == .mssql {
            _ = try await a.raw("IF OBJECT_ID('tb_tx_it') IS NOT NULL DROP TABLE tb_tx_it")
        } else {
            _ = try await a.raw("DROP TABLE IF EXISTS tb_tx_it")
        }
        _ = try await a.raw("CREATE TABLE tb_tx_it (id int PRIMARY KEY)")

        try await a.setAutoCommit(false)
        _ = try await a.execute("SELECT * FROM tb_tx_it", limit: 10)
        #expect(await a.inTransaction == false)               // 읽기는 트랜잭션을 열지 않음
        _ = try await a.execute("INSERT INTO tb_tx_it VALUES (1)", limit: 0)
        _ = try await a.execute("INSERT INTO tb_tx_it VALUES (2)", limit: 0)
        #expect(await a.transactionState == .init(autoCommit: false, open: true, changes: 2))
        #expect(try await count(a) == 2)                       // 같은 세션에선 보임
        if kind != .mssql { #expect(try await count(b) == 0) } // 다른 세션은 아직 못 봄 (MSSQL 은 잠금으로 대기하므로 생략)
        var blocked = false
        do { try await a.setAutoCommit(true) } catch { blocked = true }
        #expect(blocked)                                       // 열린 트랜잭션이 있으면 못 켬

        #expect(try await a.rollback() == 2)
        #expect(try await count(b) == 0)

        _ = try await a.execute("INSERT INTO tb_tx_it VALUES (3)", limit: 0)
        try await a.executeInTransaction(["INSERT INTO tb_tx_it VALUES (4)"])   // 결과 편집도 합류
        #expect(await a.pendingChanges == 2)
        #expect(try await a.commit() == 2)
        #expect(try await count(b) == 2)

        // 사용자가 직접 COMMIT 을 쓴 경우도 상태가 맞아야 한다
        _ = try await a.execute("DELETE FROM tb_tx_it WHERE id = 3", limit: 0)
        #expect(await a.inTransaction)
        _ = try await a.execute(kind == .mssql ? "COMMIT TRANSACTION" : "COMMIT", limit: 0)
        #expect(await a.inTransaction == false)
        #expect(try await count(b) == 1)

        try await a.setAutoCommit(true)
        _ = try await a.execute("INSERT INTO tb_tx_it VALUES (5)", limit: 0)
        #expect(await a.inTransaction == false)
        #expect(try await count(b) == 2)
    }
}
