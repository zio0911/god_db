import Foundation
import Testing
@testable import GodDBCore

/// 읽기전용 접속의 문장 검사 (#155). 우회 방법은 막고, 흔한 조회는 통과해야 한다.
@Suite("ReadOnlyGuard")
struct ReadOnlyGuardTests {
    static let all: [DatabaseKind] = [.mysql, .postgres, .mssql]

    func blocked(_ sql: String, _ kinds: [DatabaseKind] = all, sourceLocation: SourceLocation = #_sourceLocation) {
        for k in kinds {
            #expect(!SQLText.isReadOnly(sql, kind: k), "\(k) 에서 통과하면 안 됨: \(sql)", sourceLocation: sourceLocation)
        }
    }

    func allowed(_ sql: String, _ kinds: [DatabaseKind] = all, sourceLocation: SourceLocation = #_sourceLocation) {
        for k in kinds {
            let v = SQLText.readOnlyViolation(sql, kind: k)
            #expect(v == nil, "\(k) 에서 막히면 안 됨: \(sql) → \(String(describing: v))", sourceLocation: sourceLocation)
        }
    }

    // MARK: - 우회 방법

    @Test func mssqlBackToBackStatements() {
        // T-SQL 은 ; 없이 문장을 이어 쓸 수 있다
        blocked("SELECT 1 DELETE FROM t", [.mssql])
        blocked("SELECT * FROM t\nDELETE FROM t", [.mssql])
        blocked("SELECT 1 UPDATE t SET a = 1", [.mssql])
        blocked("SELECT 1 DROP TABLE t", [.mssql])
        blocked("SELECT 1 EXEC sp_who", [.mssql])
        blocked("SELECT 1DELETE FROM t", [.mssql])
        blocked("SELECT 1.DELETE FROM t", [.mssql])
        blocked("USE shop DELETE FROM t", [.mssql])
        blocked("SELECT 1 TRUNCATE TABLE t", [.mssql])
        blocked("SELECT 1 SHUTDOWN", [.mssql])
        #expect(SQLText.readOnlyViolation("SELECT 1 DELETE FROM t", kind: .mssql) == .keyword("DELETE"))
    }

    @Test func selectIntoCreatesTable() {
        blocked("SELECT * INTO new_tbl FROM t")
        blocked("SELECT * INTO #copy FROM t", [.mssql])
        blocked("SELECT * FROM t INTO OUTFILE '/tmp/x'", [.mysql])
        blocked("SELECT * FROM t INTO DUMPFILE '/tmp/x'", [.mysql])
        #expect(SQLText.readOnlyViolation("SELECT * INTO new_tbl FROM t", kind: .mssql) == .keyword("INTO"))
    }

    @Test func writesInsideCTE() {
        blocked("WITH x AS (SELECT 1 AS id) MERGE INTO t USING x ON t.id = x.id WHEN MATCHED THEN DELETE")
        blocked("WITH x AS (DELETE FROM t RETURNING *) SELECT * FROM x", [.postgres])
        blocked("WITH x AS (SELECT 1) DELETE FROM t")
        blocked("WITH x AS (SELECT 1) INSERT INTO t SELECT * FROM x")
        blocked("WITH x AS (SELECT 1) UPDATE t SET a = 1")
    }

    @Test func mssqlTempTableIsNotAComment() {
        // # 은 SQL Server 에서 임시 테이블 이름. 예전에는 줄 끝까지 주석으로 지워져 뒤의 DELETE 를 못 봤다
        blocked("WITH a AS (SELECT * FROM #tmp) DELETE FROM t", [.mssql])
        blocked("SELECT * FROM #tmp DELETE FROM t", [.mssql])
        blocked("SELECT * FROM ##global DELETE FROM t", [.mssql])
        // PostgreSQL 의 # 은 연산자
        blocked("SELECT 1 # 2, set_config('a', 'b', false)", [.postgres])
    }

    @Test func mysqlHashIsAComment() {
        allowed("SELECT 1 # DELETE FROM t", [.mysql])
    }

    @Test func postgresSessionReadOnlyOff() {
        blocked("SELECT set_config('default_transaction_read_only', 'off', false)", [.postgres])
        blocked("SELECT pg_catalog.set_config('default_transaction_read_only', 'off', false)", [.postgres])
        blocked("SELECT \"set_config\"('transaction_read_only', 'off', false)", [.postgres])
        blocked("SELECT pg_catalog . set_config /* x */ ('a', 'b', false)", [.postgres])
        blocked("SET SESSION CHARACTERISTICS AS TRANSACTION READ WRITE", [.postgres])
        blocked("SET default_transaction_read_only = off", [.postgres])
        blocked("SET transaction_read_only = off", [.postgres])
        blocked("RESET default_transaction_read_only", [.postgres])
        #expect(SQLText.readOnlyViolation("SELECT set_config('a','b',false)", kind: .postgres) == .function("set_config"))
    }

    @Test func stateChangingFunctions() {
        for f in ["pg_terminate_backend(123)", "pg_cancel_backend(123)", "pg_advisory_lock(1)", "pg_advisory_xact_lock(1)",
                  "pg_try_advisory_lock(1)", "pg_advisory_unlock_all()", "dblink_exec('c', 'DELETE FROM t')",
                  "dblink('c', 'select 1')", "lo_import('/etc/passwd')", "lo_export(1, '/tmp/x')", "lo_unlink(1)",
                  "nextval('seq')", "setval('seq', 1)", "pg_reload_conf()", "pg_read_file('x')", "query_to_xml('x', true, true, '')"] {
            blocked("SELECT \(f)", [.postgres])
        }
        for f in ["GET_LOCK('a', 1)", "RELEASE_LOCK('a')", "LOAD_FILE('/etc/passwd')", "release_all_locks()"] {
            blocked("SELECT \(f)", [.mysql])
        }
        blocked("SELECT * FROM OPENQUERY(srv, 'DELETE FROM t')", [.mssql])
        blocked("SELECT * FROM OPENROWSET('SQLNCLI', 'x', 'select 1')", [.mssql])
        blocked("SELECT * FROM OPENDATASOURCE('SQLNCLI', 'x').db.dbo.t", [.mssql])
        blocked("EXEC sp_who", [.mssql])
        blocked("EXECUTE ('DELETE FROM t')", [.mssql])
        blocked("sp_configure 'show advanced options', 1", [.mssql])
        blocked("SELECT * FROM t; EXEC master.dbo.xp_cmdshell 'dir'", [.mssql])
        blocked("SELECT 1 xp_cmdshell 'dir'", [.mssql])
        // SLEEP 는 상태를 바꾸지 않는다
        allowed("SELECT SLEEP(1)", [.mysql])
        allowed("SELECT pg_sleep(1), currval('s')", [.postgres])
    }

    @Test func rowLocks() {
        blocked("SELECT * FROM t FOR UPDATE")
        blocked("SELECT * FROM t FOR SHARE", [.mysql, .postgres])
        blocked("SELECT * FROM t FOR NO KEY UPDATE", [.postgres])
        blocked("SELECT * FROM t FOR KEY SHARE", [.postgres])
        blocked("SELECT * FROM t LOCK IN SHARE MODE", [.mysql])
        #expect(SQLText.readOnlyViolation("SELECT * FROM t FOR NO KEY UPDATE", kind: .postgres) == .lock("FOR NO KEY UPDATE"))
        #expect(SQLText.readOnlyViolation("select * from t lock in share mode", kind: .mysql) == .lock("LOCK IN SHARE MODE"))
    }

    @Test func explainAnalyzeOfWrite() {
        // PostgreSQL EXPLAIN ANALYZE 는 실제로 실행한다
        blocked("EXPLAIN ANALYZE DELETE FROM t", [.postgres, .mysql])
        blocked("EXPLAIN (ANALYZE, BUFFERS) UPDATE t SET a = 1", [.postgres])
        blocked("EXPLAIN DELETE FROM t")
        blocked("EXPLAIN ANALYZE SELECT nextval('s')", [.postgres])
        blocked("ANALYZE t", [.postgres])
        blocked("SELECT 1 ANALYZE", [.mssql])
        allowed("EXPLAIN SELECT * FROM t")
        allowed("EXPLAIN ANALYZE SELECT * FROM t", [.mysql, .postgres])
        allowed("EXPLAIN (ANALYZE, FORMAT JSON) SELECT * FROM t", [.postgres])
    }

    @Test func writeKeywordsAnywhere() {
        for w in ["CREATE TABLE x (a int)", "ALTER TABLE t ADD c int", "GRANT SELECT ON t TO u", "CALL p()",
                  "DO $$ BEGIN END $$", "COPY t TO '/tmp/x'", "VACUUM t", "REINDEX TABLE t", "REFRESH MATERIALIZED VIEW v",
                  "COMMENT ON TABLE t IS 'x'", "LOCK TABLE t", "KILL 55", "FLUSH TABLES", "DECLARE @x int",
                  "BEGIN", "COMMIT", "ROLLBACK", "TRUNCATE t", "REPLACE INTO t VALUES (1)", "UPSERT INTO t VALUES (1)"] {
            blocked(w)
            blocked("SELECT 1 " + w, [.mssql])
        }
    }

    @Test func mysqlExecutableComments() {
        // /*! … */ 는 MySQL 이 실행한다
        blocked("SELECT * FROM t /*!50000 INTO OUTFILE '/tmp/x' */", [.mysql])
        blocked("SELECT 1 /*! , GET_LOCK('a', 1) */", [.mysql])
        // -- 뒤에 공백이 없으면 MySQL 에선 주석이 아니다 (1--1 = 1 - -1)
        blocked("SELECT 1--1 INTO OUTFILE '/tmp/x'", [.mysql])
        allowed("SELECT 1 -- INTO OUTFILE\n FROM t", [.mysql])
    }

    @Test func stringEscapesCannotHideCode() {
        // MySQL NO_BACKSLASH_ESCAPES 에선 '\' 가 끝난 문자열이다
        blocked(#"SELECT '\' , GET_LOCK('a', 1) -- '"#, [.mysql])
        // standard_conforming_strings=off 이거나 E'…' 에서 \' 는 따옴표 글자
        blocked(#"SELECT E'\'', set_config('a', 'b', false) -- '"#, [.postgres])
        // 겹친 블록 주석 (PostgreSQL · SQL Server)
        blocked("SELECT 1 /* /* */ ' */ , set_config('a','b',false) -- '", [.postgres])
        blocked("SELECT 1 /* /* */ ' */ DELETE FROM t -- '", [.mssql])
        // 유니코드 공백으로 붙여 쓰기
        blocked("SELECT 1\u{3000}DELETE FROM t", [.mssql])
    }

    @Test func leadingKeyword() {
        blocked("DELETE FROM t")
        blocked("INSERT INTO t VALUES (1)")
        blocked("(SELECT 1)")
        blocked("")
        blocked("-- only comment")
        #expect(SQLText.readOnlyViolation("delete from t", kind: .mysql) == .leading("DELETE"))
    }

    @Test func messageNamesTheTrigger() {
        let m = DBError.readOnlyRejected(.keyword("DELETE")).errorDescription ?? ""
        #expect(m.contains("DELETE"), "\(m)")
        #expect(m.contains("문장 안에 있음"), "\(m)")
        #expect(DBError.readOnlyRejected(.function("set_config")).errorDescription?.contains("set_config()") == true)
        #expect(DBError.readOnlyRejected(.lock("FOR UPDATE")).errorDescription?.contains("FOR UPDATE") == true)
        #expect(DBError.readOnlyRejected(.leading("DELETE")).errorDescription?.contains("DELETE") == true)
    }

    // MARK: - 통과해야 하는 조회

    @Test func legitQueriesPass() {
        allowed("SELECT * FROM t WHERE memo = 'please delete me' AND note = 'insert; update; drop table x'")
        allowed("SELECT a -- update later\nFROM t /* delete? no */")
        allowed("SELECT updated_at, deleted_yn, insert_dt, created_by, update_cnt FROM tb_member")
        allowed("SELECT * FROM t WHERE x IN (1, 2, 3) AND y IN (SELECT id FROM u)")
        allowed("WITH x AS (SELECT 1 AS id), y AS (SELECT * FROM x) SELECT * FROM y")
        allowed("SELECT t.comment, t.lock, t.handler FROM t")
        allowed("SELECT a AS lock, b AS comment FROM t")
        allowed("SELECT comment FROM t")
        allowed("SELECT \"delete\", \"update\" FROM t", [.postgres, .mssql])
        allowed("SELECT `delete`, `update` FROM t", [.mysql])
        allowed("SELECT [delete], [update] FROM t", [.mssql])
        allowed("SELECT * FROM information_schema.columns WHERE table_name = 'tb_member'")
        allowed("SELECT update_rule, delete_rule FROM information_schema.referential_constraints")
        allowed("SELECT event_manipulation FROM information_schema.triggers WHERE event_manipulation = 'DELETE'")
        allowed("SELECT CASE WHEN a > 1 THEN 'x' ELSE 'y' END FROM t")
        allowed("SELECT COUNT(*) FROM t GROUP BY a HAVING COUNT(*) > 1 ORDER BY a DESC")
    }

    @Test func mysqlLegit() {
        allowed("SELECT REPLACE(col, 'a', 'b') FROM t", [.mysql])
        allowed("SELECT replace (col, 'a', 'b') FROM t", [.mysql])
        allowed("SELECT 'it''s', 'back\\'slash' FROM t", [.mysql])
        allowed("SHOW TABLES", [.mysql])
        allowed("SHOW CREATE TABLE tb_member", [.mysql])
        allowed("SHOW CHARACTER SET", [.mysql])
        allowed("SHOW FULL PROCESSLIST", [.mysql])
        allowed("SHOW VARIABLES LIKE 'max%'", [.mysql])
        allowed("DESC tb_member", [.mysql])
        allowed("DESCRIBE tb_member", [.mysql])
        allowed("USE shop", [.mysql])
        allowed("SELECT CAST(x AS CHAR CHARACTER SET utf8mb4) FROM t", [.mysql])
        allowed("SELECT /*+ MAX_EXECUTION_TIME(1000) */ * FROM t", [.mysql])
        allowed("SELECT @a := 1, @@version", [.mysql])
    }

    @Test func postgresLegit() {
        allowed("SELECT '#' || name, '# not a comment' FROM t WHERE a # b = 0", [.postgres])
        allowed("SELECT $$delete from t$$, $tag$ update $tag$", [.postgres])
        allowed("SELECT E'it\\'s', 'plain' FROM t", [.postgres])
        allowed("SHOW transaction_read_only", [.postgres])
        allowed("SELECT * FROM pg_stat_activity WHERE state <> 'idle'", [.postgres])
        allowed("SELECT currval('s'), current_setting('search_path')", [.postgres])
        allowed("SELECT x::text, ARRAY[1, 2][1] FROM t", [.postgres])
        allowed("SELECT * FROM t WHERE id = $1", [.postgres])
    }

    @Test func mssqlLegit() {
        allowed("SELECT * FROM #tmp", [.mssql])
        allowed("SELECT * FROM ##global_tmp WHERE a = '#'", [.mssql])
        allowed("SELECT TOP 10 * FROM dbo.tb_member WITH (NOLOCK) WHERE name LIKE N'%#%'", [.mssql])
        allowed("WITH a AS (SELECT * FROM #tmp) SELECT * FROM a", [.mssql])
        allowed("SELECT @@ROWCOUNT, @@VERSION", [.mssql])
        allowed("USE shop", [.mssql])
        allowed("SELECT * FROM t FOR JSON PATH", [.mssql])
        allowed("SELECT 'back\\' FROM t", [.mssql])
    }

    @Test func otherCallSitesUseTheSameRules() {
        // 수동 커밋 · 운영 확인에서도 T-SQL 이어 쓰기를 쓰기로 본다
        #expect(!SQLText.isReadOnly("SELECT 1 DELETE FROM t", kind: .mssql))
        #expect(!DataFinder.isSelectOnly("SELECT * FROM #tmp DELETE FROM t", kind: .mssql))
        #expect(DataFinder.isSelectOnly("SELECT * FROM #tmp", kind: .mssql))
    }
}

/// 실제 서버에서 읽기전용 우회가 막히는지 (GODDB_PG_PORT / GODDB_MSSQL_PORT 가 있을 때만)
@Suite("ReadOnlyGuard integration", .serialized)
struct ReadOnlyGuardIntegrationTests {
    static let table = "tb_ro_guard_it"

    /// 쓰기 가능한 접속으로 한 행짜리 테이블을 만들고, 같은 주소의 읽기전용 접속을 연다
    func sessions(_ kind: DatabaseKind, database: String) async throws -> (admin: DBSession, ro: DBSession)? {
        guard let (p, pw) = MultiDB.profile(kind, database: database) else { return nil }
        let admin = try await DBSession.connect(profile: p, password: pw)
        _ = try await admin.raw("DROP TABLE IF EXISTS \(Self.table)")
        _ = try await admin.raw("CREATE TABLE \(Self.table) (id int PRIMARY KEY)")
        _ = try await admin.raw("INSERT INTO \(Self.table) (id) VALUES (1)")
        var ro = p
        ro.readOnly = true
        return (admin, try await DBSession.connect(profile: ro, password: pw))
    }

    func rowCount(_ s: DBSession) async throws -> String? {
        try await s.raw("SELECT COUNT(*) FROM \(Self.table)").rows.first?.first ?? nil
    }

    @Test(.enabled(if: MultiDB.env["GODDB_MSSQL_PORT"] != nil))
    func mssqlRefusesBackToBackDelete() async throws {
        guard let (admin, ro) = try await sessions(.mssql, database: "master") else { return }
        do {
            _ = try await ro.execute("SELECT 1 DELETE FROM \(Self.table)", limit: 0)
            Issue.record("읽기전용 접속에서 실행되면 안 됨")
        } catch DBError.readOnlyRejected(let v) {
            #expect(v == .keyword("DELETE"))
        }
        await #expect(throws: DBError.self) { _ = try await ro.execute("SELECT * INTO tb_ro_guard_copy FROM \(Self.table)", limit: 0) }
        // 멀쩡한 조회는 된다
        let r = try await ro.execute("SELECT id FROM \(Self.table)", limit: 0)
        #expect(r.rows.count == 1)
        #expect(try await rowCount(admin) == "1")
        await ro.close()
        _ = try? await admin.raw("DROP TABLE IF EXISTS \(Self.table)")
        await admin.close()
    }

    @Test(.enabled(if: MultiDB.env["GODDB_PG_PORT"] != nil))
    func postgresRefusesSessionReadOnlyOff() async throws {
        guard let (admin, ro) = try await sessions(.postgres, database: "shop") else { return }
        let off = "SELECT set_config('default_transaction_read_only', 'off', false)"
        do {
            _ = try await ro.execute(off, limit: 0)
            Issue.record("읽기전용 접속에서 실행되면 안 됨")
        } catch DBError.readOnlyRejected(let v) {
            #expect(v == .function("set_config"))
        }
        // 앱 검사를 건너뛰어도: 문장마다 BEGIN READ ONLY … ROLLBACK 이라 세션 설정이 남지 않는다
        _ = try await ro.readOnlyGuardedRaw(off)
        #expect(try await ro.raw("SHOW default_transaction_read_only").rows.first?.first == "on")
        // 세션의 READ ONLY 를 (가드 밖에서) 직접 꺼도 감싼 트랜잭션은 읽기전용이라 쓰기가 거부된다
        _ = try await ro.raw("SET SESSION CHARACTERISTICS AS TRANSACTION READ WRITE")
        await #expect(throws: (any Error).self) { _ = try await ro.readOnlyGuardedRaw("DELETE FROM \(Self.table)") }
        // 트랜잭션 안에서 읽기전용을 끄려 해도 거부된다
        await #expect(throws: (any Error).self) {
            _ = try await ro.readOnlyGuardedRaw("SELECT set_config('transaction_read_only', 'off', true)")
        }
        // 조회는 그대로 된다
        let r = try await ro.execute("SELECT id FROM \(Self.table)", limit: 0)
        #expect(r.rows.count == 1)
        #expect(try await rowCount(admin) == "1")
        await ro.close()
        _ = try? await admin.raw("DROP TABLE IF EXISTS \(Self.table)")
        await admin.close()
    }

    /// SQL Server: Service Broker RECEIVE · SEND, 시퀀스 NEXT VALUE FOR 도 막는다 (#193). 같은 이름의 열은 그대로
    @Test func mssqlBrokerAndSequence() {
        let blocked: [(String, SQLText.ReadOnlyViolation)] = [
            ("RECEIVE TOP (1) * FROM dbo.q", .leading("RECEIVE")),
            ("SELECT 1; RECEIVE TOP (1) * FROM dbo.q", .keyword("RECEIVE")),
            ("SELECT 1; SEND ON CONVERSATION @h MESSAGE TYPE m (N'x')", .keyword("SEND")),
            ("SELECT NEXT VALUE FOR dbo.order_seq", .keyword("NEXT VALUE FOR")),
            ("select next value for order_seq as n", .keyword("NEXT VALUE FOR")),
        ]
        for (sql, want) in blocked {
            #expect(SQLText.readOnlyViolation(sql, kind: .mssql) == want, "\(sql)")
        }
        for sql in ["SELECT send, receive, next, value FROM t", "SELECT t.send FROM t WHERE receive = 1",
                    "SELECT [next] FROM t ORDER BY value"] {
            #expect(SQLText.readOnlyViolation(sql, kind: .mssql) == nil, "\(sql)")
        }
    }
}
