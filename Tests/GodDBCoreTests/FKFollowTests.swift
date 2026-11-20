import Foundation
import Testing
@testable import GodDBCore

@Suite("FKFollow")
struct FKFollowTests {
    static func col(_ name: String, _ type: String, pk: Bool = false) -> ColumnMeta {
        ColumnMeta(name: name, columnType: type, nullable: !pk, columnKey: pk ? "PRI" : "")
    }

    static func table(_ name: String, _ cols: [ColumnMeta], pk: [String], fks: [ForeignKeyMeta] = []) -> TableMeta {
        TableMeta(name: name, columns: cols, indexes: [IndexMeta(name: "PRIMARY", unique: true, columns: pk)], foreignKeys: fks)
    }

    /// ui_customers(id) ← ui_orders.customer_id (진짜 FK), tb_member(member_no) ← tb_point.member_no (추정),
    /// 복합 키 tb_line(order_no, line_no) ← tb_ship(order_no, line_no)
    static let customers = table("ui_customers", [col("id", "int", pk: true), col("name", "varchar(50)")], pk: ["id"])
    static let orders = table("ui_orders", [col("id", "int", pk: true), col("customer_id", "int"), col("code", "varchar(20)")],
                              pk: ["id"],
                              fks: [ForeignKeyMeta(name: "fk_ui_orders_customer", table: "ui_orders", columns: ["customer_id"],
                                                   referencedTable: "ui_customers", referencedColumns: ["id"])])
    static let member = table("tb_member", [col("member_no", "bigint", pk: true), col("name", "varchar(50)")], pk: ["member_no"])
    static let point = table("tb_point", [col("id", "int", pk: true), col("MEMBER_NO", "bigint"), col("note", "varchar(10)")], pk: ["id"])
    static let line = table("tb_line", [col("order_no", "varchar(20)", pk: true), col("line_no", "int", pk: true)],
                            pk: ["order_no", "line_no"])
    static let ship = table("tb_ship", [col("id", "int", pk: true), col("order_no", "varchar(20)"), col("line_no", "int")], pk: ["id"],
                            fks: [ForeignKeyMeta(name: "fk_ship_line", table: "tb_ship", columns: ["order_no", "line_no"],
                                                 referencedTable: "tb_line", referencedColumns: ["order_no", "line_no"])])
    static let all = [customers, orders, member, point, line, ship]
    static let inferred = FKFollow.inferredRelations(all)

    // MARK: - 원본 테이블

    @Test func sourceTableOnlyForSingleTableSelect() {
        #expect(FKFollow.sourceTable(sql: "SELECT * FROM ui_orders WHERE id > 1", tables: Self.all)?.name == "ui_orders")
        #expect(FKFollow.sourceTable(sql: "select id, customer_id from `UI_ORDERS`", tables: Self.all)?.name == "ui_orders")
        #expect(FKFollow.sourceTable(sql: "SELECT * FROM ui_orders o JOIN ui_customers c ON c.id = o.customer_id",
                                     tables: Self.all) == nil)
        #expect(FKFollow.sourceTable(sql: "SELECT customer_id, COUNT(*) FROM ui_orders GROUP BY customer_id", tables: Self.all) == nil)
        #expect(FKFollow.sourceTable(sql: "SELECT * FROM nope", tables: Self.all) == nil)
    }

    // MARK: - 관계

    @Test func realForeignKeyLookup() {
        let out = FKFollow.outgoing(from: Self.orders, inferred: Self.inferred)
        #expect(out == [FKRelation(table: "ui_orders", columns: ["customer_id"], referencedTable: "ui_customers",
                                   referencedColumns: ["id"], inferred: false)])
        #expect(FKFollow.relations(forColumn: "CUSTOMER_ID", in: out).count == 1)
        // 관계가 없는 컬럼
        #expect(FKFollow.relations(forColumn: "code", in: out).isEmpty)
        #expect(FKFollow.relations(forColumn: "id", in: out).isEmpty)
        #expect(FKFollow.outgoing(from: Self.customers, inferred: Self.inferred).isEmpty)
    }

    @Test func compositeForeignKey() {
        let out = FKFollow.outgoing(from: Self.ship, inferred: Self.inferred)
        #expect(out.count == 1)
        #expect(FKFollow.relations(forColumn: "order_no", in: out) == out)
        #expect(FKFollow.relations(forColumn: "line_no", in: out) == out)
        // 복합 기본 키 테이블은 "참조하는 행" 이 없다
        #expect(FKFollow.incoming(to: Self.line, tables: Self.all, inferred: Self.inferred).isEmpty)
    }

    @Test func inferredRelationByUniquePrimaryKeyName() {
        let out = FKFollow.outgoing(from: Self.point, inferred: Self.inferred)
        #expect(out == [FKRelation(table: "tb_point", columns: ["MEMBER_NO"], referencedTable: "tb_member",
                                   referencedColumns: ["member_no"], inferred: true)])
        let inc = FKFollow.incoming(to: Self.member, tables: Self.all, inferred: Self.inferred)
        #expect(inc.map(\.table) == ["tb_point"])
        #expect(inc.first?.inferred == true)
    }

    @Test func inferredSkippedWhenAmbiguous() {
        // 기본 키 이름이 user_key 인 테이블이 하나면 추정, 둘이고 이름으로도 고를 수 없으면 추정하지 않는다
        let a = Self.table("tb_alpha", [Self.col("user_key", "varchar(20)", pk: true)], pk: ["user_key"])
        let b = Self.table("tb_beta", [Self.col("user_key", "varchar(20)", pk: true)], pk: ["user_key"])
        let child = Self.table("tb_log", [Self.col("id", "int", pk: true), Self.col("user_key", "varchar(20)")], pk: ["id"])
        let one = [a, child]
        #expect(FKFollow.outgoing(from: child, inferred: FKFollow.inferredRelations(one)).map(\.referencedTable) == ["tb_alpha"])
        let two = [a, b, child]
        let inferred = FKFollow.inferredRelations(two)
        #expect(FKFollow.outgoing(from: child, inferred: inferred).isEmpty)
        #expect(FKFollow.incoming(to: a, tables: two, inferred: inferred).isEmpty)
    }

    @Test func realForeignKeyIsNotAlsoInferred() {
        // 진짜 FK 컬럼은 추정에서 빠지고, 진짜 FK 는 표시가 "추정" 이 아니다
        let inc = FKFollow.incoming(to: Self.customers, tables: Self.all, inferred: Self.inferred)
        #expect(inc == [FKRelation(table: "ui_orders", columns: ["customer_id"], referencedTable: "ui_customers",
                                   referencedColumns: ["id"], inferred: false)])
    }

    // MARK: - SQL

    @Test func followSQLPerDialect() {
        let r = FKFollow.outgoing(from: Self.orders, inferred: Self.inferred)[0]
        #expect(FKFollow.followSQL(r, values: ["10"], tables: Self.all, dialect: MySQLDialect())
            == "SELECT * FROM `ui_customers` WHERE `id` = 10")
        #expect(FKFollow.followSQL(r, values: ["10"], tables: Self.all, dialect: PostgresDialect())
            == #"SELECT * FROM "ui_customers" WHERE "id" = 10"#)
        #expect(FKFollow.followSQL(r, values: ["10"], tables: Self.all, dialect: MSSQLDialect())
            == "SELECT * FROM [ui_customers] WHERE [id] = 10")
        // 숫자 컬럼이어도 숫자가 아닌 값은 인용
        #expect(FKFollow.followSQL(r, values: ["x'1"], tables: Self.all, dialect: MySQLDialect())
            == "SELECT * FROM `ui_customers` WHERE `id` = 'x''1'")
    }

    @Test func followSQLQuotesStringColumnsAndCompositeUsesAnd() {
        let r = FKFollow.outgoing(from: Self.ship, inferred: Self.inferred)[0]
        #expect(FKFollow.followSQL(r, values: ["0042", "3"], tables: Self.all, dialect: MySQLDialect())
            == "SELECT * FROM `tb_line` WHERE `order_no` = '0042' AND `line_no` = 3")
        #expect(FKFollow.followSQL(r, values: ["A-1", "3"], tables: Self.all, dialect: PostgresDialect())
            == #"SELECT * FROM "tb_line" WHERE "order_no" = 'A-1' AND "line_no" = 3"#)
        #expect(FKFollow.followSQL(r, values: ["가-1", "3"], tables: Self.all, dialect: MSSQLDialect())
            == "SELECT * FROM [tb_line] WHERE [order_no] = N'가-1' AND [line_no] = 3")
        // MSSQL 스키마 이름이 붙은 테이블
        let s = FKRelation(table: "sales.orders", columns: ["code"], referencedTable: "sales.codes", referencedColumns: ["code"], inferred: false)
        #expect(FKFollow.followSQL(s, values: ["A"], tables: [], dialect: MSSQLDialect())
            == "SELECT * FROM [sales].[codes] WHERE [code] = N'A'")
    }

    @Test func nullValueDisablesFollow() {
        let r = FKFollow.outgoing(from: Self.orders, inferred: Self.inferred)[0]
        #expect(FKFollow.followSQL(r, values: [nil], tables: Self.all, dialect: MySQLDialect()) == nil)
        let c = FKFollow.outgoing(from: Self.ship, inferred: Self.inferred)[0]
        #expect(FKFollow.followSQL(c, values: ["A-1", nil], tables: Self.all, dialect: MySQLDialect()) == nil)
        // 결과에 FK 컬럼 일부가 없으면 비활성
        let values = FKFollow.values(for: c, resultColumns: ["id", "order_no"], row: ["1", "A-1"])
        #expect(values == ["A-1", nil])
        #expect(FKFollow.followSQL(c, values: values, tables: Self.all, dialect: MySQLDialect()) == nil)
        // 참조하는 행도 기본 키 값이 NULL 이면 비활성
        let inc = FKFollow.incoming(to: Self.customers, tables: Self.all, inferred: Self.inferred)[0]
        #expect(FKFollow.referencingSQL(inc, primaryKeyValue: nil, tables: Self.all, dialect: MySQLDialect()) == nil)
    }

    @Test func valuesFromResultRowIgnoreCase() {
        let r = FKFollow.outgoing(from: Self.point, inferred: Self.inferred)[0]
        #expect(FKFollow.values(for: r, resultColumns: ["id", "member_no", "note"], row: ["1", "1002", "x"]) == ["1002"])
        #expect(FKFollow.value(of: "ID", resultColumns: ["id", "member_no"], row: ["7", nil]) == "7")
        #expect(FKFollow.value(of: "member_no", resultColumns: ["id", "member_no"], row: ["7", nil]) == nil)
    }

    @Test func referencingSQLPerDialect() {
        let inc = FKFollow.incoming(to: Self.customers, tables: Self.all, inferred: Self.inferred)[0]
        #expect(FKFollow.referencingSQL(inc, primaryKeyValue: "20", tables: Self.all, dialect: MySQLDialect())
            == "SELECT * FROM `ui_orders` WHERE `customer_id` = 20")
        #expect(FKFollow.referencingSQL(inc, primaryKeyValue: "20", tables: Self.all, dialect: PostgresDialect())
            == #"SELECT * FROM "ui_orders" WHERE "customer_id" = 20"#)
        #expect(FKFollow.referencingSQL(inc, primaryKeyValue: "20", tables: Self.all, dialect: MSSQLDialect())
            == "SELECT * FROM [ui_orders] WHERE [customer_id] = 20")
        // 문자 키
        let codes = Self.table("tb_code", [Self.col("code_cd", "varchar(10)", pk: true)], pk: ["code_cd"])
        let usage = Self.table("tb_usage", [Self.col("id", "int", pk: true), Self.col("code_cd", "varchar(10)")], pk: ["id"])
        let tables = [codes, usage]
        let rel = FKFollow.incoming(to: codes, tables: tables, inferred: FKFollow.inferredRelations(tables))
        #expect(rel.count == 1 && rel[0].inferred)
        #expect(FKFollow.referencingSQL(rel[0], primaryKeyValue: "A'1", tables: tables, dialect: MSSQLDialect())
            == "SELECT * FROM [tb_usage] WHERE [code_cd] = N'A''1'")
        #expect(FKFollow.referencingSQL(rel[0], primaryKeyValue: "007", tables: tables, dialect: PostgresDialect())
            == #"SELECT * FROM "tb_usage" WHERE "code_cd" = '007'"#)
    }

    @Test func titles() {
        let r = FKFollow.outgoing(from: Self.orders, inferred: Self.inferred)[0]
        #expect(FKFollow.followTitle(r) == "↗ ui_customers")
        #expect(FKFollow.referencingTitle(r) == "↙ ui_orders")
    }

    @Test func singlePrimaryKey() {
        #expect(FKFollow.singlePrimaryKey(Self.customers) == "id")
        #expect(FKFollow.singlePrimaryKey(Self.line) == nil)
        #expect(FKFollow.singlePrimaryKey(TableMeta(name: "t", columns: [Self.col("a", "int")])) == nil)
    }
}
