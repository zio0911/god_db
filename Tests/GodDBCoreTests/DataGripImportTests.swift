import Foundation
import Testing
@testable import GodDBCore

@Suite("DataGrip import")
struct DataGripImportTests {
    // DataGrip ⌘C 형식 (값은 예시)
    let mssql = """
    #DataSourceSettings#
    #LocalDataSource: SALES[PRD]
    #BEGIN#
    <data-source source="LOCAL" name="SALES[PRD]" uuid="b7dca191-568c-407d-a9ca-7bcd3a995ea2"><database-info product="Microsoft SQL Server" version="15.00.4430" dbms="MSSQL"><extra-name-characters>$#@</extra-name-characters><identifier-quote-string>&quot;</identifier-quote-string></database-info><driver-ref>sqlserver.ms</driver-ref><jdbc-driver>com.microsoft.sqlserver.jdbc.SQLServerDriver</jdbc-driver><jdbc-url>jdbc:sqlserver://10.0.0.5:50585;database=SALES</jdbc-url><secret-storage>master_key</secret-storage><user-name>app_user</user-name><schema-mapping><introspection-scope><node kind="database" qname="SALES"/></introspection-scope></schema-mapping><working-dir>$ProjectFileDir$</working-dir></data-source>
    #END#
    """

    let mysqlSSH = """
    #DataSourceSettings#
    #LocalDataSource: shop[DEV]
    #BEGIN#
    <data-source source="LOCAL" name="shop[DEV]" uuid="558f2f4d-ff6d-41c9-8528-e11865a982b6"><database-info product="MySQL" version="8.0.43" dbms="MYSQL_AURORA"><identifier-quote-string>`</identifier-quote-string></database-info><driver-ref>mysql.8</driver-ref><jdbc-url>jdbc:mysql://shop-dev.cluster-xyz.ap-northeast-2.rds.amazonaws.com:3306/shop_db</jdbc-url><user-name>shop_user</user-name><ssh-properties><enabled>true</enabled><ssh-config-id>ba02a190-966f-493f-98b6-fc94843a231a</ssh-config-id></ssh-properties></data-source>
    #END#
    """

    @Test func parsesSQLServer() throws {
        let s = try DataGripImport.parse(mssql)
        #expect(s.count == 1)
        let p = s[0].profile
        #expect(p.kind == .mssql)
        #expect(p.name == "SALES[PRD]")
        #expect(p.host == "10.0.0.5" && p.port == 50585)
        #expect(p.database == "SALES")
        #expect(p.username == "app_user")
        #expect(p.id == UUID(uuidString: "b7dca191-568c-407d-a9ca-7bcd3a995ea2"))
        #expect(p.ssh == nil)
    }

    @Test func parsesMySQLWithSSHNote() throws {
        let s = try DataGripImport.parse(mysqlSSH)
        let p = s[0].profile
        #expect(p.kind == .mysql)
        #expect(p.host == "shop-dev.cluster-xyz.ap-northeast-2.rds.amazonaws.com" && p.port == 3306)
        #expect(p.database == "shop_db" && p.username == "shop_user")
        #expect(p.ssh != nil && p.ssh?.host == "")
        #expect(s[0].notes.contains { $0.contains("SSH") })
    }

    @Test func parsesSeveralAtOnce() throws {
        #expect(try DataGripImport.parse(mssql + "\n" + mysqlSSH).map(\.profile.kind) == [.mssql, .mysql])
    }

    @Test func jdbcURLs() {
        let pg = DataGripImport.profile(fromJDBC: "jdbc:postgresql://pg.local:5433/app?sslmode=disable")
        #expect(pg?.kind == .postgres && pg?.port == 5433 && pg?.database == "app" && pg?.useTLS == false)
        let my = DataGripImport.profile(fromJDBC: "jdbc:mysql://db:3307/shop?useSSL=false&serverTimezone=UTC")
        #expect(my?.port == 3307 && my?.useTLS == false)
        let ms = DataGripImport.profile(fromJDBC: "jdbc:sqlserver://host\\SQLEXPRESS;databaseName=HR;encrypt=false")
        #expect(ms?.host == "host" && ms?.port == 1433 && ms?.database == "HR" && ms?.useTLS == false)
        let rd = DataGripImport.profile(fromJDBC: "jdbc:redis://cache.local:6380/2")
        #expect(rd?.kind == .redis && rd?.port == 6380 && rd?.database == "2")
        #expect(DataGripImport.profile(fromJDBC: "jdbc:oracle:thin:@x:1521:ORCL") == nil)
        // 드라이버 래퍼 / 하위 프로토콜 / 여러 호스트
        let aws = DataGripImport.profile(fromJDBC: "jdbc:aws-wrapper:mysql://shop-prd.cluster-xyz.ap-northeast-2.rds.amazonaws.com:3306/shop_db")
        #expect(aws?.kind == .mysql && aws?.host == "shop-prd.cluster-xyz.ap-northeast-2.rds.amazonaws.com" && aws?.port == 3306 && aws?.database == "shop_db")
        let awsPG = DataGripImport.profile(fromJDBC: "jdbc:aws-wrapper:postgresql://pg.local:5432/app")
        #expect(awsPG?.kind == .postgres && awsPG?.database == "app")
        let spy = DataGripImport.profile(fromJDBC: "jdbc:p6spy:mysql://db:3306/a")
        #expect(spy?.kind == .mysql && spy?.host == "db")
        let repl = DataGripImport.profile(fromJDBC: "jdbc:mysql:replication://primary:3306,replica:3307/shop?useSSL=false")
        #expect(repl?.host == "primary" && repl?.port == 3306 && repl?.database == "shop" && repl?.useTLS == false)
        let jtds = DataGripImport.profile(fromJDBC: "jdbc:jtds:sqlserver://ms:1433;databaseName=HR")
        #expect(jtds?.kind == .mssql && jtds?.database == "HR")
    }

    @Test func rejectsOtherText() {
        #expect(throws: DataGripImport.ParseError.notDataGrip) { try DataGripImport.parse("hello") }
        let oracle = mssql.replacingOccurrences(of: "jdbc:sqlserver://10.0.0.5:50585;database=SALES", with: "jdbc:oracle:thin:@x:1521:ORCL")
        #expect(throws: DataGripImport.ParseError.nothingSupported(["SALES[PRD]"])) { try DataGripImport.parse(oracle) }
    }
}
