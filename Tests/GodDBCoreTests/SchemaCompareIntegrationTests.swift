import Foundation
import Testing
@testable import GodDBCore

/// 스키마 비교를 실제 DB 로 확인한다. 한 서버에 같은 테이블을 가진 DB(PostgreSQL 은 스키마) 두 개를 만들고,
/// 비교 창과 같은 경로(`SchemaDiff.compare(source:sourceContainer:target:targetContainer:)`)로 읽는다.
/// 1) 똑같으면 차이가 없어야 한다.
/// 2) 대상(B)을 ALTER 로 바꾸면 차이마다 맞는 항목과 보정 SQL 이 나와야 한다.
/// 3) 그 보정 SQL 을 대상에 실행하고 다시 비교하면 "대상에만 있음" 외에는 차이가 없어야 한다.
/// GODDB_IT_PORT(MySQL) · GODDB_PG_PORT · GODDB_MSSQL_PORT 가 있을 때만 각각 실행된다. (scripts/test-dbs.sh test)
@Suite("SchemaCompare live", .serialized)
struct SchemaCompareIntegrationTests {
    static let env = ProcessInfo.processInfo.environment

    @Test(.enabled(if: env["GODDB_IT_PORT"] != nil)) func mysql() async throws {
        try await CompareFixture.run(.mysql)
    }

    @Test(.enabled(if: env["GODDB_PG_PORT"] != nil)) func postgres() async throws {
        try await CompareFixture.run(.postgres)
    }

    @Test(.enabled(if: env["GODDB_MSSQL_PORT"] != nil)) func sqlServer() async throws {
        try await CompareFixture.run(.mssql)
    }
}

/// 테스트마다 새 이름으로 만들고 끝나면 지우는 비교용 DB 두 개
struct CompareFixture {
    let kind: DatabaseKind
    let a: String
    let b: String
    let admin: DBSession
    let source: DBSession
    let target: DBSession

    static func connect(_ kind: DatabaseKind) async throws -> DBSession {
        let env = ProcessInfo.processInfo.environment
        switch kind {
        case .mysql:
            let p = ConnectionProfile(name: "cmp", host: "127.0.0.1", port: Int(env["GODDB_IT_PORT"]!)!,
                                      username: "root", database: "shop", useTLS: false)   // 비교만 본다 (TLS 는 따로 테스트)
            return try await DBSession.connect(profile: p, password: env["GODDB_IT_PASSWORD"] ?? "")
        case .postgres, .mssql:
            let (p, pw) = MultiDB.profile(kind, database: kind == .mssql ? "master" : "shop")!
            return try await DBSession.connect(profile: p, password: pw)
        case .redis:
            throw DBError.notConnected
        }
    }

    static func make(_ kind: DatabaseKind) async throws -> CompareFixture {
        let suffix = UUID().uuidString.prefix(6).lowercased()
        let a = "cmp_a_\(suffix)", b = "cmp_b_\(suffix)"
        let admin = try await connect(kind)
        let d = admin.dialect
        for name in [a, b] {
            _ = try await admin.raw(kind == .postgres ? "CREATE SCHEMA \(d.quoteIdent(name))" : "CREATE DATABASE \(d.quoteIdent(name))")
        }
        return CompareFixture(kind: kind, a: a, b: b, admin: admin,
                              source: try await connect(kind), target: try await connect(kind))
    }

    func drop() async {
        await source.close()
        await target.close()
        let d = admin.dialect
        for name in [a, b] {
            switch kind {
            case .postgres: _ = try? await admin.raw("DROP SCHEMA IF EXISTS \(d.quoteIdent(name)) CASCADE")
            case .mssql:
                _ = try? await admin.raw("USE master")
                _ = try? await admin.raw("ALTER DATABASE \(d.quoteIdent(name)) SET SINGLE_USER WITH ROLLBACK IMMEDIATE")
                _ = try? await admin.raw("DROP DATABASE IF EXISTS \(d.quoteIdent(name))")
            default: _ = try? await admin.raw("DROP DATABASE IF EXISTS \(d.quoteIdent(name))")
            }
        }
        await admin.close()
    }

    /// 한 DB(스키마)에서 문장을 차례로 실행한다
    func exec(_ container: String, _ statements: [String]) async throws {
        try await admin.use(container)
        for sql in statements {
            do { _ = try await admin.raw(sql) } catch {
                throw FixtureError(message: "\(container): \(sql)\n\(ErrorText.describe(error).message)")
            }
        }
    }

    /// 비교 창과 같은 경로로 비교
    func compare(from s: String, to t: String) async throws -> SchemaDiffReport {
        try await SchemaDiff.compare(source: source, sourceContainer: s, target: target, targetContainer: t)
    }

    static func run(_ kind: DatabaseKind) async throws {
        let f = try await make(kind)
        do {
            try await f.scenario()
        } catch {
            await f.drop()
            throw error
        }
        await f.drop()
    }

    func scenario() async throws {
        // 1) 같은 테이블 → 차이 없음 (양방향)
        try await exec(a, CompareSQL.base(kind))
        try await exec(b, CompareSQL.base(kind))
        for (s, t) in [(a, b), (b, a)] {
            let same = try await compare(from: s, to: t)
            #expect(same.items.isEmpty, "\(kind) \(s)→\(t) 같은데 차이: \(Self.describe(same.items))")
            #expect(same.matchedTables == 2)
            #expect(same.fixScript.isEmpty)
        }

        // 2) 대상(B)만 바꾸고, A 에만 / B 에만 있는 테이블을 만든다
        try await exec(a, CompareSQL.onlyA(kind))
        try await exec(b, CompareSQL.alterB(kind))
        let report = try await compare(from: a, to: b)
        let all = Self.describe(report.items)

        func find(_ k: SchemaDiffItem.Kind, _ table: String, _ object: String? = nil) -> SchemaDiffItem? {
            report.items.first { $0.kind == k && $0.table == table && $0.object?.lowercased() == object?.lowercased() }
        }
        // 컬럼
        let memo = find(.missingColumn, "cmp_member", "memo")
        #expect(memo?.fixSQL?.contains("memo") == true, "B 에서 지운 컬럼 → 누락: \(all)")
        #expect(find(.extraColumn, "cmp_member", "extra_b")?.fixSQL == nil, "B 에만 추가한 컬럼 → 대상에만 있음: \(all)")
        let nick = find(.differentColumn, "cmp_member", "nick")
        #expect(nick?.detail.contains("타입") == true, "길이 변경: \(all)")
        #expect(nick?.fixSQL?.contains("50") == true)
        #expect(find(.differentColumn, "cmp_member", "phone")?.detail.contains("NOT NULL → NULL") == true, "NULL 허용 변경: \(all)")
        #expect(find(.differentColumn, "cmp_member", "status")?.detail.contains("기본값") == true, "기본값 변경: \(all)")
        let email = find(.differentColumn, "cmp_member", "email")
        #expect(email?.detail == "코멘트 변경", "컬럼 코멘트 변경: \(all)")
        #expect(email?.fixSQL?.contains("메일") == true)
        // 테이블 코멘트
        let tableComment = find(.differentTable, "cmp_member")
        #expect(tableComment?.fixSQL?.contains("회원") == true, "테이블 코멘트 변경: \(all)")
        // 인덱스
        #expect(find(.missingIndex, "cmp_member", "idx_member_email")?.fixSQL != nil, "B 에서 지운 인덱스: \(all)")
        #expect(find(.extraIndex, "cmp_member", "idx_member_phone")?.fixSQL == nil, "B 에만 있는 인덱스: \(all)")
        #expect(find(.differentIndex, "cmp_order", "uq_order_code")?.fixSQL != nil, "UNIQUE → 일반 인덱스: \(all)")
        // 테이블
        #expect(find(.missingTable, "cmp_only_a")?.fixSQL?.contains("cmp_only_a") == true, "A 에만 있는 테이블: \(all)")
        #expect(find(.extraTable, "cmp_only_b")?.fixSQL == nil, "B 에만 있는 테이블: \(all)")
        // 바꾸지 않은 컬럼은 나오지 않는다
        #expect(find(.differentColumn, "cmp_member", "name") == nil)
        #expect(find(.differentColumn, "cmp_order", "amount") == nil)
        #expect(find(.differentColumn, "cmp_order", "id") == nil, "\(all)")

        // 여러 개 골라 복사: 고른 순서와 관계없이 목록 순서, 참고용 항목은 건너뜀
        if let n = nick, let m = memo, let extra = find(.extraColumn, "cmp_member", "extra_b") {
            let joined = SchemaDiffReport.fixSQL(of: report.items, selected: [n.id, m.id, extra.id])
            #expect(joined == SchemaDiffReport.grouped(report.items.filter { [n.id, m.id].contains($0.id) }))
            #expect(joined.contains(n.fixSQL!) && joined.contains(m.fixSQL!))
        }

        // 3) 보정 SQL 을 대상에 실행 (쿼리 탭에서 전체 실행하듯 문장별로) → 다시 비교하면 대상에만 있는 것만 남는다
        try await target.use(b)
        for stmt in SQLText.statements(in: report.fixScript).map(\.sql) {
            do { _ = try await target.raw(stmt) } catch {
                Issue.record("\(kind) 보정 SQL 실패: \(stmt)\n\(ErrorText.describe(error).message)")
            }
        }
        let after = try await compare(from: a, to: b)
        let left = after.items.filter { $0.severity != .extra }
        #expect(left.isEmpty, "\(kind) 보정 후에도 남은 차이: \(Self.describe(left))")
        let extras = Set(after.items.filter { $0.severity == .extra }.map { "\($0.table).\($0.object ?? "")".lowercased() })
        #expect(extras == ["cmp_member.extra_b", "cmp_member.idx_member_phone", "cmp_only_b."], "\(extras)")
        #expect(after.matchedTables == 2 || after.matchedTables == 3)
    }

    static func describe(_ items: [SchemaDiffItem]) -> String {
        items.map { "[\($0.kind.rawValue)] \($0.table).\($0.object ?? "") \($0.detail) :: \($0.fixSQL ?? "-")" }
            .joined(separator: "\n")
    }
}

struct FixtureError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

/// DB 별 비교용 DDL
enum CompareSQL {
    /// A · B 에 똑같이 만드는 테이블 두 개
    static func base(_ kind: DatabaseKind) -> [String] {
        switch kind {
        case .mysql, .redis:
            return [
                """
                CREATE TABLE cmp_member (id int NOT NULL AUTO_INCREMENT PRIMARY KEY, name varchar(50) NOT NULL,
                  nick varchar(50) NULL, email varchar(100) NULL COMMENT '메일', phone varchar(20) NULL,
                  status char(1) NOT NULL DEFAULT 'A', memo varchar(200) NULL,
                  UNIQUE KEY uq_member_name (name), KEY idx_member_email (email)) COMMENT='회원'
                """,
                """
                CREATE TABLE cmp_order (id int NOT NULL AUTO_INCREMENT PRIMARY KEY, member_id int NOT NULL,
                  code varchar(20) NOT NULL, amount decimal(10,2) NOT NULL DEFAULT 0,
                  UNIQUE KEY uq_order_code (code), KEY idx_order_member (member_id))
                """,
            ]
        case .postgres:
            return [
                """
                CREATE TABLE cmp_member (id int PRIMARY KEY, name varchar(50) NOT NULL, nick varchar(50),
                  email varchar(100), phone varchar(20), status char(1) NOT NULL DEFAULT 'A', memo varchar(200))
                """,
                "CREATE UNIQUE INDEX uq_member_name ON cmp_member (name)",
                "CREATE INDEX idx_member_email ON cmp_member (email)",
                "COMMENT ON TABLE cmp_member IS '회원'",
                "COMMENT ON COLUMN cmp_member.email IS '메일'",
                """
                CREATE TABLE cmp_order (id serial PRIMARY KEY, member_id int NOT NULL, code varchar(20) NOT NULL,
                  amount numeric(10,2) NOT NULL DEFAULT 0)
                """,
                "CREATE UNIQUE INDEX uq_order_code ON cmp_order (code)",
                "CREATE INDEX idx_order_member ON cmp_order (member_id)",
            ]
        case .mssql:
            return [
                """
                CREATE TABLE cmp_member (id int IDENTITY(1,1) CONSTRAINT pk_cmp_member PRIMARY KEY, name varchar(50) NOT NULL,
                  nick varchar(50) NULL, email nvarchar(100) NULL, phone varchar(20) NULL,
                  status char(1) NOT NULL CONSTRAINT df_member_status DEFAULT ('A'), memo nvarchar(200) NULL)
                """,
                "CREATE UNIQUE INDEX uq_member_name ON cmp_member (name)",
                "CREATE INDEX idx_member_email ON cmp_member (email)",
                msComment("회원", column: nil),
                msComment("메일", column: "email"),
                """
                CREATE TABLE cmp_order (id int IDENTITY(1,1) CONSTRAINT pk_cmp_order PRIMARY KEY, member_id int NOT NULL,
                  code varchar(20) NOT NULL CONSTRAINT uq_order_code UNIQUE, amount decimal(10,2) NOT NULL DEFAULT (0))
                """,
                "CREATE INDEX idx_order_member ON cmp_order (member_id)",
            ]
        }
    }

    /// A 에만 있는 테이블
    static func onlyA(_ kind: DatabaseKind) -> [String] {
        switch kind {
        case .mysql, .redis:
            return ["CREATE TABLE cmp_only_a (id int NOT NULL AUTO_INCREMENT PRIMARY KEY, title varchar(30) NOT NULL DEFAULT 'x', KEY idx_only_title (title)) COMMENT='A 전용'"]
        case .postgres:
            return [
                "CREATE TABLE cmp_only_a (id serial PRIMARY KEY, title varchar(30) NOT NULL DEFAULT 'x')",
                "CREATE INDEX idx_only_title ON cmp_only_a (title)",
                "COMMENT ON TABLE cmp_only_a IS 'A 전용'",
            ]
        case .mssql:
            return [
                "CREATE TABLE cmp_only_a (id int IDENTITY(1,1) CONSTRAINT pk_only_a PRIMARY KEY, title nvarchar(30) NOT NULL DEFAULT (N'x'))",
                "CREATE INDEX idx_only_title ON cmp_only_a (title)",
                msComment("A 전용", column: nil, table: "cmp_only_a"),
            ]
        }
    }

    /// 대상(B)을 기준과 다르게 바꾼다
    static func alterB(_ kind: DatabaseKind) -> [String] {
        switch kind {
        case .mysql, .redis:
            return [
                "ALTER TABLE cmp_member ADD COLUMN extra_b int NULL",
                "ALTER TABLE cmp_member DROP COLUMN memo",
                "ALTER TABLE cmp_member MODIFY nick varchar(80) NULL",
                "ALTER TABLE cmp_member MODIFY phone varchar(20) NOT NULL",
                "ALTER TABLE cmp_member ALTER COLUMN status SET DEFAULT 'B'",
                "ALTER TABLE cmp_member MODIFY email varchar(100) NULL COMMENT '이메일 주소'",
                "ALTER TABLE cmp_member COMMENT = '회원 테이블'",
                "ALTER TABLE cmp_member DROP INDEX idx_member_email, ADD INDEX idx_member_phone (phone)",
                "ALTER TABLE cmp_order DROP INDEX uq_order_code, ADD INDEX uq_order_code (code)",
                "CREATE TABLE cmp_only_b (id int PRIMARY KEY)",
            ]
        case .postgres:
            return [
                "ALTER TABLE cmp_member ADD COLUMN extra_b int",
                "ALTER TABLE cmp_member DROP COLUMN memo",
                "ALTER TABLE cmp_member ALTER COLUMN nick TYPE varchar(80)",
                "ALTER TABLE cmp_member ALTER COLUMN phone SET NOT NULL",
                "ALTER TABLE cmp_member ALTER COLUMN status SET DEFAULT 'B'",
                "COMMENT ON COLUMN cmp_member.email IS '이메일 주소'",
                "COMMENT ON TABLE cmp_member IS '회원 테이블'",
                "DROP INDEX idx_member_email",
                "CREATE INDEX idx_member_phone ON cmp_member (phone)",
                "DROP INDEX uq_order_code",
                "CREATE INDEX uq_order_code ON cmp_order (code)",
                "CREATE TABLE cmp_only_b (id int PRIMARY KEY)",
            ]
        case .mssql:
            return [
                "ALTER TABLE cmp_member ADD extra_b int NULL",
                "ALTER TABLE cmp_member DROP COLUMN memo",
                "ALTER TABLE cmp_member ALTER COLUMN nick varchar(80) NULL",
                "ALTER TABLE cmp_member ALTER COLUMN phone varchar(20) NOT NULL",
                "ALTER TABLE cmp_member DROP CONSTRAINT df_member_status",
                "ALTER TABLE cmp_member ADD CONSTRAINT df_member_status DEFAULT ('B') FOR status",
                msComment("이메일 주소", column: "email", update: true),
                msComment("회원 테이블", column: nil, update: true),
                "DROP INDEX idx_member_email ON cmp_member",
                "CREATE INDEX idx_member_phone ON cmp_member (phone)",
                "ALTER TABLE cmp_order DROP CONSTRAINT uq_order_code",
                "CREATE INDEX uq_order_code ON cmp_order (code)",
                "CREATE TABLE cmp_only_b (id int CONSTRAINT pk_only_b PRIMARY KEY)",
            ]
        }
    }

    static func msComment(_ text: String, column: String?, table: String = "cmp_member", update: Bool = false) -> String {
        var sql = "EXEC sys.\(update ? "sp_updateextendedproperty" : "sp_addextendedproperty") @name = N'MS_Description', @value = N'\(text)', "
            + "@level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'\(table)'"
        if let column { sql += ", @level2type = N'COLUMN', @level2name = N'\(column)'" }
        return sql
    }
}

/// DB 없이 보는 보정 SQL 모양
@Suite("SchemaCompare SQL")
struct SchemaCompareSQLTests {
    @Test func tableCommentDifference() {
        let s = TableMeta(name: "t", comment: "회원", columns: [ColumnMeta(name: "id", columnType: "int", nullable: false)])
        var t = s
        t.comment = "회원 테이블"
        let item = SchemaDiff.compare(source: [s], target: [t]).items.first
        #expect(item?.kind == .differentTable && item?.severity == .different)
        #expect(item?.fixSQL == "ALTER TABLE `t` COMMENT = '회원';")
        #expect(SchemaDiff.compare(source: [s], target: [t], dialect: PostgresDialect()).items.first?.fixSQL
                == "COMMENT ON TABLE \"t\" IS '회원';")
        #expect(SchemaDiff.compare(source: [s], target: [t], dialect: MSSQLDialect()).items.first?.fixSQL?
            .hasPrefix("EXEC sys.sp_updateextendedproperty") == true)
        #expect(SchemaDiff.compare(source: [s], target: [s]).items.isEmpty)
    }

    @Test func postgresSerialCreatesSequence() {
        let id = ColumnMeta(name: "id", columnType: "integer", nullable: false, defaultValue: "nextval('t_id_seq'::regclass)")
        #expect(PostgresDialect.sequenceName(id) == "t_id_seq")
        #expect(PostgresDialect.sequenceName(ColumnMeta(name: "x", columnType: "integer", nullable: true,
                                                        defaultValue: "nextval('\"My''Seq\"'::regclass)")) == "\"My'Seq\"")
        #expect(PostgresDialect.sequenceName(ColumnMeta(name: "x", columnType: "integer", nullable: true, defaultValue: "0")) == nil)
        let ddl = PostgresDialect().createTableSQL(TableMeta(name: "t", columns: [id]))
        #expect(ddl.hasPrefix("CREATE SEQUENCE IF NOT EXISTS t_id_seq AS integer;\nCREATE TABLE \"t\""))
        #expect(ddl.contains("ALTER SEQUENCE t_id_seq OWNED BY \"t\".\"id\";"))
        let add = PostgresDialect().render([.addColumn(id, after: nil)], table: "t")
        #expect(add.components(separatedBy: "\n").count == 3 && add.hasPrefix("CREATE SEQUENCE IF NOT EXISTS t_id_seq"))
    }

    /// 기존 기본값 제약조건은 이름을 찾아 지운다. 쿼리 탭이 세미콜론으로 나눠도 한 문장이어야 한다.
    @Test func mssqlDefaultChangeDropsExistingConstraint() {
        let old = ColumnMeta(name: "status", columnType: "char(1)", nullable: false, defaultValue: "('B')")
        var new = old
        new.defaultValue = "('A')"
        let sql = MSSQLDialect().render([.modifyColumn(old: old, new: new)], table: "member")
        let statements = SQLText.statements(in: sql).map(\.sql)
        #expect(statements.count == 2)
        #expect(statements[0].hasPrefix("DECLARE @df_status nvarchar(300) = (SELECT QUOTENAME(dc.name)"))
        #expect(statements[0].contains("OBJECT_ID(N'[member]') AND c.name = N'status'"))
        #expect(statements[0].hasSuffix("EXEC (N'ALTER TABLE [member] DROP CONSTRAINT ' + @df_status)"))
        #expect(statements[1] == "ALTER TABLE [member] ADD DEFAULT ('A') FOR [status]")
        // 기본값이 없던 컬럼은 지우지 않고 더하기만
        var none = old
        none.defaultValue = nil
        #expect(MSSQLDialect().render([.modifyColumn(old: none, new: new)], table: "member")
                == "ALTER TABLE [member] ADD DEFAULT ('A') FOR [status];")
    }
}
