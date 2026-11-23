import Foundation
import Testing
@testable import GodDBCore

/// Redshift (PostgreSQL 8.0 기반 카탈로그): 메타데이터 조회가 없는 항목을 쓰지 않는지, DDL 에 DISTKEY · SORTKEY
@Suite("Redshift dialect")
struct RedshiftDialectTests {
    let rs = PostgresDialect(redshift: true)
    let pg = PostgresDialect()

    @Test func detectsRedshiftFromVersion() {
        let v = "PostgreSQL 8.0.2 on i686-pc-linux-gnu, compiled by GCC gcc (GCC) 3.4.2 20041017 (Red Hat 3.4.2-6.fc3), Redshift 1.0.123456"
        #expect(PostgresDialect.redshiftVersion(v) == "Redshift 1.0.123456")
        #expect(PostgresDialect.redshiftVersion("PostgreSQL 16.4 on aarch64-unknown-linux-gnu") == nil)
        #expect(rs.isRedshift)
        #expect(!pg.isRedshift)
        #expect(!MySQLDialect().isRedshift)
    }

    @Test func metadataAvoidsNewerCatalog() {
        let all = [rs.columnsSQL("public"), rs.indexesSQL("public"), rs.foreignKeysSQL("public"),
                   rs.routinesSQL("public"), rs.allTablesSQL ?? ""]
        for sql in all {
            for word in ["attidentity", "prokind IN", "unnest", "LATERAL", "tgisinternal", "information_schema.tables"] {
                #expect(!sql.contains(word), "\(word) in \(sql.prefix(60))")
            }
        }
        #expect(rs.sessionSetupSQL == nil)
        #expect(pg.sessionSetupSQL != nil)
        // PostgreSQL 은 그대로
        #expect(pg.columnsSQL("public").contains("attidentity"))
        #expect(pg.foreignKeysSQL("public").contains("unnest"))
    }

    @Test func distAndSortKeysFromExtra() {
        #expect(PostgresDialect.redshiftKeys(ColumnMeta(name: "a", columnType: "int", nullable: false, extra: "distkey sortkey 1")) == (true, 1))
        #expect(PostgresDialect.redshiftKeys(ColumnMeta(name: "b", columnType: "int", nullable: false, extra: "sortkey 2")) == (false, 2))
        #expect(PostgresDialect.redshiftKeys(ColumnMeta(name: "c", columnType: "int", nullable: false, extra: "")) == (false, nil))
    }

    @Test func createTableHasDistAndSortKeys() {
        let t = TableMeta(name: "sales", comment: "판매", columns: [
            ColumnMeta(name: "id", columnType: "bigint", nullable: false, extra: "distkey", columnKey: "PRI", position: 1),
            ColumnMeta(name: "sold_at", columnType: "timestamp without time zone", nullable: true, extra: "sortkey 2", position: 2),
            ColumnMeta(name: "shop_id", columnType: "integer", nullable: true, extra: "sortkey 1", comment: "매장", position: 3),
        ], indexes: [IndexMeta(name: "sales_pkey", unique: true, columns: ["id"], primary: true)])
        let ddl = rs.createTableSQL(t)
        #expect(ddl.contains("DISTKEY (\"id\")"))
        #expect(ddl.contains("SORTKEY (\"shop_id\", \"sold_at\")"))
        #expect(ddl.contains("CONSTRAINT \"sales_pkey\" PRIMARY KEY"))
        #expect(!ddl.contains("CREATE INDEX"))
        #expect(!ddl.contains("SEQUENCE"))
        #expect(ddl.contains("COMMENT ON COLUMN \"sales\".\"shop_id\" IS '매장';"))
    }

    @Test func connectionTypeRedshift() throws {
        var p = ConnectionProfile(kind: .postgres, port: 5432, useTLS: false)
        #expect(p.type == .postgres)
        p.type = .redshift
        #expect(p.kind == .postgres && p.redshift && p.port == 5439 && p.useTLS)
        #expect(p.typeTitle == "Redshift")
        p.type = .mysql
        #expect(p.kind == .mysql && !p.redshift && p.port == 3306)
        // 포트를 바꿔 둔 접속은 그대로
        p.type = .redshift
        p.port = 15439
        p.type = .postgres
        #expect(p.port == 15439 && !p.redshift)
        #expect(ConnectionType.allCases.map(\.title) == ["MySQL", "PostgreSQL", "Redshift", "SQL Server", "Redis"])

        // 저장 · 읽기, 예전 파일(redshift 없음)은 false
        var r = ConnectionProfile(kind: .postgres)
        r.redshift = true
        let back = try JSONDecoder().decode(ConnectionProfile.self, from: JSONEncoder().encode(r))
        #expect(back.redshift && back.type == .redshift)
        let old = #"{"id":"6F1C2A6E-1B8B-4B6E-9C55-0C1F0E6A9A10","kind":"postgres","name":"a","host":"h","port":5432,"username":"u"}"#
        #expect(try !JSONDecoder().decode(ConnectionProfile.self, from: Data(old.utf8)).redshift)
    }

    @Test func editingIsBlockedMessageIsTranslated() {
        let ko = ResultEditingError.keysNotEnforced.errorDescription ?? ""
        #expect(ko.contains("Redshift"))
        #expect(L10nEnglish.table[ko] != nil)
    }
}
