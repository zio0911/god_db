import Foundation
import Testing
@testable import GodDBCore

/// PostgreSQL 문자열 상수: 백슬래시가 있으면 E'…' (standard_conforming_strings 설정과 무관하게 같은 값, #197)
@Suite("PostgreSQL quoting")
struct PostgresQuoteTests {
    @Test func backslashUsesEscapeString() {
        let pg = PostgresDialect()
        #expect(pg.quoteString("it's") == "'it''s'")
        #expect(pg.quoteString(#"C:\temp\a'b"#) == #"E'C:\\temp\\a''b'"#)
        // Redshift 는 E'' 를 쓰지 않는다
        #expect(PostgresDialect(redshift: true).quoteString(#"a\b"#) == #"'a\b'"#)
    }

    /// 실제 서버: standard_conforming_strings 를 꺼도 켜도 같은 값으로 읽힌다
    @Test(.enabled(if: MultiDB.env["GODDB_PG_PORT"] != nil))
    func sameValueEitherSetting() async throws {
        let (p, pw) = try #require(MultiDB.profile(.postgres, database: "shop"))
        let s = try await DBSession.connect(profile: p, password: pw)
        defer { Task { await s.close() } }
        let value = #"C:\temp\a'b"#
        for setting in ["on", "off"] {
            _ = try await s.raw("SET standard_conforming_strings = \(setting)")
            let got = try await s.raw("SELECT " + s.dialect.quoteString(value)).rows.first?.first ?? nil
            #expect(got == value, "standard_conforming_strings = \(setting)")
        }
    }
}
