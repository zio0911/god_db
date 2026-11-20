import Foundation
import Testing
@testable import GodDBCore

/// AI 데이터 찾기 실제 확인 (#151): 약 150개 테이블의 약어 스키마를 임시 DB 에 만들고 로컬 Ollama 로 찾는다.
/// - `GODDB_DATAFINDER_LIVE=1` 일 때만. SQL Server(GODDB_MSSQL_PORT) · MySQL(GODDB_IT_PORT) 중 있는 것으로.
/// - 모델: `GODDB_DATAFINDER_MODEL` (기본 qwen3:30b), 고장 난 모델: `GODDB_DATAFINDER_BROKEN_MODEL` (기본 laguna-xs-2.1:q8_0).
/// - 임시 DB `goddb_finder_seed` 는 끝나면 지운다. 사용자의 AI 설정은 건드리지 않는다.
enum FinderSeed {
    static let env = ProcessInfo.processInfo.environment
    static let database = "goddb_finder_seed"
    static var live: Bool { env["GODDB_DATAFINDER_LIVE"] == "1" }
    static var model: String { env["GODDB_DATAFINDER_MODEL"] ?? "qwen3:30b" }
    static var brokenModel: String { env["GODDB_DATAFINDER_BROKEN_MODEL"] ?? "laguna-xs-2.1:q8_0" }

    static func profile(_ kind: DatabaseKind, database: String) -> (ConnectionProfile, String)? {
        switch kind {
        case .mssql:
            guard let port = env["GODDB_MSSQL_PORT"].flatMap(Int.init) else { return nil }
            return (ConnectionProfile(kind: .mssql, name: "ms", host: "localhost", port: port, username: "sa",
                                      database: database, useTLS: false), env["GODDB_MSSQL_PASSWORD"] ?? "GodDb_test1!")
        case .mysql:
            guard let port = env["GODDB_IT_PORT"].flatMap(Int.init) else { return nil }
            return (ConnectionProfile(name: "my", host: "127.0.0.1", port: port, username: "root", database: database,
                                      useTLS: true, tlsVerify: false), env["GODDB_IT_PASSWORD"] ?? "goddbtest")
        default:
            return nil
        }
    }

    struct Table {
        var name: String
        var comment: String = ""
        var columns: [(name: String, type: String, comment: String)]
        var rows: [[String]] = []
    }

    /// 핵심 테이블 + 헷갈리게 하는 테이블 + 잡음 테이블 (약 150개). 이름은 모두 지어낸 일반적인 약어.
    static func tables() -> [Table] {
        var t: [Table] = []
        t.append(Table(name: "tb_stdnt_info", columns: [
            ("stdnt_no", "int", ""), ("stdnt_nm", "nvarchar(50)", ""), ("schyr", "int", ""), ("ban_cd", "varchar(10)", ""),
            ("schl_cd", "varchar(10)", ""), ("brth_ymd", "char(8)", ""),
        ], rows: (1...30).map { i in ["\(i)", "'학생\(i)'", "\((i % 6) + 1)", "'B\((i % 4) + 1)'", "'S\((i % 5) + 1)'", "'20\(10 + i % 8)0301'"] }))
        t.append(Table(name: "tb_schl_info", columns: [
            ("schl_cd", "varchar(10)", ""), ("schl_nm", "nvarchar(100)", ""), ("schl_addr", "nvarchar(200)", ""), ("rgn_cd", "varchar(10)", ""),
        ], rows: (1...5).map { i in ["'S\(i)'", "'한빛\(["초", "중", "고", "초", "중"][i - 1])등학교'", "'서울시 어느구 \(i)길'", "'R\(i)'"] }))
        t.append(Table(name: "tb_mbr_info", columns: [
            ("mbr_no", "int", ""), ("mbr_id", "varchar(30)", ""), ("mbr_nm", "nvarchar(50)", ""), ("mbr_tel_no", "varchar(20)", ""),
            ("mbr_grd_cd", "varchar(10)", ""), ("email_addr", "varchar(100)", ""), ("reg_dt", "date", ""),
        ], rows: (1...20).map { i in
            ["\(i)", "'user\(i)'", "'회원\(i)'", "'010-\(1000 + i)-\(2000 + i)'", "'\(["VIP", "GOLD", "SILVER"][i % 3])'",
             "'u\(i)@example.com'", "'2024-01-\(10 + i)'"]
        }))
        // 헷갈리게: 연도(yr), 회원 등급 이력(grd), 지점 전화, 교사 이름 · 전화, 학급
        t.append(Table(name: "tb_sales_yr_sum", columns: [("base_yr", "int", ""), ("sale_amt", "decimal(15,2)", "")],
                       rows: (2019...2024).map { ["\($0)", "\($0 * 10)"] }))
        t.append(Table(name: "tb_mbr_grd_hist", comment: "회원 등급 변경 이력", columns: [
            ("hist_seq", "int", ""), ("mbr_no", "int", ""), ("bf_grd_cd", "varchar(10)", ""), ("af_grd_cd", "varchar(10)", ""),
            ("chg_dt", "date", ""),
        ], rows: [["1", "1", "'SILVER'", "'GOLD'", "'2024-02-01'"]]))
        t.append(Table(name: "tb_brnc_info", columns: [
            ("brnc_cd", "varchar(10)", ""), ("brnc_nm", "nvarchar(50)", ""), ("brnc_tel_no", "varchar(20)", ""), ("brnc_addr", "nvarchar(200)", ""),
        ], rows: [["'B1'", "'강남센터'", "'02-555-0101'", "'서울'"]]))
        t.append(Table(name: "tb_tchr_info", columns: [
            ("tchr_no", "int", ""), ("tchr_nm", "nvarchar(50)", ""), ("schl_cd", "varchar(10)", ""), ("sbj_cd", "varchar(10)", ""),
        ], rows: [["1", "'교사1'", "'S1'", "'MATH'"]]))
        t.append(Table(name: "tb_cls_info", columns: [
            ("cls_cd", "varchar(10)", ""), ("cls_nm", "nvarchar(50)", ""), ("tchr_no", "int", ""),
        ], rows: [["'C1'", "'1반'", "1"]]))
        // 잡음: 업무 영역 × 종류. 일부만 한국어 코멘트.
        let areas = ["ord", "prod", "pay", "dlv", "cpn", "bbs", "ntc", "inq", "alrm", "auth", "cfg", "stat", "rpt", "cart",
                     "stk", "rfnd", "ctrt", "acct", "file", "menu"]
        let areaKo = ["주문", "상품", "결제", "배송", "쿠폰", "게시판", "공지", "문의", "알림", "권한", "설정", "통계", "보고서", "장바구니",
                      "재고", "환불", "계약", "계좌", "첨부파일", "메뉴"]
        let kinds = ["mst", "dtl", "hist", "map", "tmp", "bak", "sum"]
        for (ai, a) in areas.enumerated() {
            for (ki, k) in kinds.enumerated() {
                let comment = (ai + ki) % 4 == 0 ? "\(areaKo[ai]) \(["마스터", "상세", "이력", "매핑", "임시", "백업", "집계"][ki])" : ""
                t.append(Table(name: "tb_\(a)_\(k)", comment: comment, columns: [
                    ("\(a)_seq", "bigint", ""), ("\(a)_cd", "varchar(20)", ""), ("\(a)_nm", "nvarchar(100)", ""),
                    ("\(a)_stts_cd", "varchar(10)", ""), ("use_yn", "char(1)", ""), ("rgst_id", "varchar(30)", ""),
                    ("rgst_dtm", "datetime", ""), ("updt_id", "varchar(30)", ""), ("updt_dtm", "datetime", ""),
                ]))
            }
        }
        return t
    }

    static func setup(_ kind: DatabaseKind) async throws -> DBSession? {
        guard let (admin, pw) = profile(kind, database: kind == .mssql ? "master" : "mysql") else { return nil }
        let a = try await DBSession.connect(profile: admin, password: pw)
        try await drop(kind, a)
        _ = try await a.raw(kind == .mssql ? "CREATE DATABASE \(database)" : "CREATE DATABASE \(database) DEFAULT CHARACTER SET utf8mb4")
        await a.close()
        let (p, _) = profile(kind, database: database)!
        let s = try await DBSession.connect(profile: p, password: pw)
        for t in tables() {
            let cols = t.columns.map { c in
                let type = kind == .mysql ? c.type.replacingOccurrences(of: "nvarchar", with: "varchar") : c.type
                return "\(c.name) \(type) NULL" + (kind == .mysql && !c.comment.isEmpty ? " COMMENT '\(c.comment)'" : "")
            }.joined(separator: ", ")
            if kind == .mysql {
                _ = try await s.raw("CREATE TABLE \(t.name) (\(cols))" + (t.comment.isEmpty ? "" : " COMMENT='\(t.comment)'"))
            } else {
                _ = try await s.raw("CREATE TABLE dbo.\(t.name) (\(cols))")
                if !t.comment.isEmpty {
                    _ = try await s.raw("EXEC sp_addextendedproperty 'MS_Description', N'\(t.comment)', 'SCHEMA', 'dbo', 'TABLE', '\(t.name)'")
                }
            }
            if !t.rows.isEmpty {
                let values = t.rows.map { r in "(" + r.map { kind == .mssql && $0.hasPrefix("'") ? "N" + $0 : $0 }.joined(separator: ", ") + ")" }
                _ = try await s.raw("INSERT INTO \(t.name) VALUES " + values.joined(separator: ", "))
            }
        }
        return s
    }

    static func drop(_ kind: DatabaseKind, _ admin: DBSession) async throws {
        if kind == .mssql {
            _ = try await admin.raw("""
                IF DB_ID('\(database)') IS NOT NULL BEGIN
                  ALTER DATABASE \(database) SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE \(database); END
                """)
        } else {
            _ = try await admin.raw("DROP DATABASE IF EXISTS \(database)")
        }
    }

    static func teardown(_ kind: DatabaseKind) async {
        guard let (admin, pw) = profile(kind, database: kind == .mssql ? "master" : "mysql"),
              let a = try? await DBSession.connect(profile: admin, password: pw) else { return }
        try? await drop(kind, a)
        await a.close()
    }

    /// 앱과 같은 길: 따로 연 연결에서 NOLOCK 샘플 조회
    static func sampler(_ session: DBSession) async -> @Sendable (String, String) async -> DataFinder.SampleOutcome {
        let side = await session.sideConnection()
        let dialect = session.dialect
        return { table, column in
            let sql = DataFinder.sampleSQL(table: table, column: column, dialect: dialect)
            do {
                guard let side else { return .failed("no side connection") }
                let r = try await side.query(sql, timeout: DataFinder.sampleTimeout)
                return .values(DataFinder.cleanSamples(r.rows.map { $0.first ?? nil }))
            } catch is SideConnection.TimedOut {
                return .timedOut
            } catch {
                return .failed(error.localizedDescription)
            }
        }
    }

    static let questions: [(q: String, table: String, column: String)] = [
        ("학년 정보는 어디 있어?", "tb_stdnt_info", "schyr"),
        ("학교 이름은 어디야?", "tb_schl_info", "schl_nm"),
        ("회원 전화번호 어디 있어?", "tb_mbr_info", "mbr_tel_no"),
    ]
}

@Suite("DataFinder live", .serialized, .enabled(if: FinderSeed.live))
struct DataFinderLiveTests {
    @Test(arguments: [DatabaseKind.mssql, .mysql])
    func findsOnSeededSchema(_ kind: DatabaseKind) async throws {
        guard let s = try await FinderSeed.setup(kind) else { return }
        do {
            let tables = try await s.loadSchema(FinderSeed.database)
            #expect(tables.count >= 140)
            #expect(DataFinder.needsTwoStages(tables: tables))
            let client = OllamaClient()
            #expect(await ModelProbe.check(model: FinderSeed.model, client: client, useCache: false) == .ok)
            let ai = DataFinderAI.ollama(client, model: FinderSeed.model, kind: kind, english: false)
            for item in FinderSeed.questions {
                let terms = DataFinder.keyTerms(item.q)
                let started = Date()
                let found = try await ai.find(question: item.q, terms: terms, tables: tables, notes: [],
                                              sample: await FinderSeed.sampler(s))
                let v = found.verdict
                let secs = Int(Date().timeIntervalSince(started))
                print("LIVE[\(kind.title)] \(item.q) → \(v.map { "\($0.table).\($0.columns.joined(separator: ","))" } ?? "nil")"
                      + " · \(v?.confidence.rawValue ?? "-") · fallback=\(found.usedFallback) · twoStage=\(found.picked.twoStage)"
                      + " · candidates=\(found.picked.candidates.map(\.location)) · samples="
                      + "\(found.sampled.map { $0.sampleStatus ?? "-" }) · \(secs)s")
                #expect(!found.usedFallback, "\(item.q)")
                #expect(v?.table == item.table, "\(item.q)")
                #expect(v?.columns.contains(item.column) == true, "\(item.q)")
            }
        } catch {
            await s.close()
            await FinderSeed.teardown(kind)
            throw error
        }
        await s.close()
        await FinderSeed.teardown(kind)
    }

    @Test func noAIFallbackOnSeededSchema() async throws {
        guard let s = try await FinderSeed.setup(.mssql) else { return }
        let tables: [TableMeta]
        do { tables = try await s.loadSchema(FinderSeed.database) } catch {
            await s.close(); await FinderSeed.teardown(.mssql); throw error
        }
        let ai = DataFinderAI(kind: .mssql, english: false) { _ in throw OllamaError.http(500, "{\"error\":\"broken\"}") }
        for item in FinderSeed.questions {
            let found = try await ai.find(question: item.q, terms: DataFinder.keyTerms(item.q), tables: tables, notes: [],
                                          sample: await FinderSeed.sampler(s))
            print("LIVE[no AI] \(item.q) → \(found.verdict.map { "\($0.table).\($0.columns.joined(separator: ","))" } ?? "nil")")
            #expect(found.usedFallback)
            #expect(found.verdict?.table == item.table, "\(item.q)")
            #expect(found.verdict?.columns.first == item.column, "\(item.q)")
        }
        await s.close()
        await FinderSeed.teardown(.mssql)
    }

    @Test func brokenModelProbeFailsClearly() async {
        let before = AISettings.model
        let h = await ModelProbe.check(model: FinderSeed.brokenModel, client: OllamaClient(), cache: ModelHealthCache())
        print("LIVE probe \(FinderSeed.brokenModel) → \(h)")
        #expect(!h.isOK)
        if case .failed(let r) = h { #expect(!r.isEmpty && !r.contains("{")) }
        #expect(AISettings.model == before)   // 사용자 설정은 그대로
        let good = await ModelProbe.check(model: FinderSeed.model, client: OllamaClient(), cache: ModelHealthCache())
        #expect(good == .ok)
    }
}

/// 따로 연 연결의 샘플 조회: 잠금에 막혀도 NOLOCK 은 바로, 시간이 넘은 조회는 그 연결만 끊고 사용자 세션은 그대로 (SQL Server)
@Suite("SideConnection", .serialized, .enabled(if: ProcessInfo.processInfo.environment["GODDB_MSSQL_PORT"] != nil))
struct SideConnectionTests {
    static let db = "goddb_side_test"

    @Test func timeoutDoesNotBreakMainSession() async throws {
        let (admin, pw) = FinderSeed.profile(.mssql, database: "master")!
        let a = try await DBSession.connect(profile: admin, password: pw)
        _ = try await a.raw("IF DB_ID('\(Self.db)') IS NOT NULL BEGIN ALTER DATABASE \(Self.db) SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE \(Self.db); END")
        _ = try await a.raw("CREATE DATABASE \(Self.db)")
        let (p, _) = FinderSeed.profile(.mssql, database: Self.db)!
        let user = try await DBSession.connect(profile: p, password: pw)
        let locker = try await DBSession.connect(profile: p, password: pw)
        do {
            _ = try await user.raw("CREATE TABLE tb_lock_t (id int, v int)")
            _ = try await user.raw("INSERT INTO tb_lock_t VALUES (1, 1), (2, 2)")
            // 다른 세션이 커밋하지 않은 변경으로 잠금을 쥐고 있다
            try await locker.setAutoCommit(false)
            _ = try await locker.execute("UPDATE tb_lock_t SET v = 9", limit: 0)
            #expect(await locker.transactionState.open)

            let side = try #require(await user.sideConnection())
            // NOLOCK 은 잠금에 막히지 않는다
            let r = try await side.query(DataFinder.sampleSQL(table: "tb_lock_t", column: "v", dialect: MSSQLDialect()), timeout: 5)
            #expect(r.rows.count == 2)
            // NOLOCK 없는 조회는 막혀 시간 초과 → 그 연결만 버린다
            await #expect(throws: SideConnection.TimedOut.self) {
                _ = try await side.query("SELECT v FROM tb_lock_t", timeout: 2)
            }
            // 사용자 세션은 그대로 쓸 수 있고, 따로 연 연결도 새로 붙어 다시 쓸 수 있다
            #expect(try await user.raw("SELECT DB_NAME()").rows.first?.first == .some(Self.db))
            let again = try await side.query(DataFinder.sampleSQL(table: "tb_lock_t", column: "id", dialect: MSSQLDialect()), timeout: 5)
            #expect(again.rows.count == 2)
            await side.close()
            _ = try await locker.rollback()
        } catch {
            _ = try? await locker.rollback()
            await locker.close(); await user.close()
            _ = try? await a.raw("ALTER DATABASE \(Self.db) SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE \(Self.db)")
            await a.close()
            throw error
        }
        await locker.close()
        await user.close()
        _ = try await a.raw("ALTER DATABASE \(Self.db) SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE \(Self.db)")
        await a.close()
    }
}
