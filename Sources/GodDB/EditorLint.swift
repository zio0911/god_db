import AppKit
import GodDBCore

/// 쿼리 편집기 빨간 밑줄 (없는 컬럼 · 문법 오류)
enum EditorLint {
    static let enabledKey = "GodDB.editor.lint"
    static let serverKey = "GodDB.editor.serverCheck"
    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
    static var serverEnabled: Bool { UserDefaults.standard.object(forKey: serverKey) as? Bool ?? true }
}

extension AppState {
    /// 탭의 접속 종류 · DB 와, 그 DB 의 스키마를 알고 있으면 테이블 목록
    func lintContext(tabID: UUID) -> (tables: [TableMeta], kind: DatabaseKind?, schema: String?) {
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return ([], nil, nil) }
        let kind = profile(tab.profileID)?.kind
        guard let info = connections[tab.profileID] else { return ([], kind, nil) }
        let schema = tab.database.isEmpty ? info.currentDatabase : tab.database
        // 사이드바가 다른 DB 를 보고 있으면 컬럼 검사는 하지 않는다 (틀린 경고 방지)
        let tables = info.currentDatabase == schema ? info.tables : []
        return (tables, kind, schema)
    }

    /// 실행하지 않고 DB 에 검사만 맡긴다. 연결이 없거나 탭의 DB 가 세션의 DB 와 다르면 묻지 않는다.
    func serverCheck(_ sql: String, tabID: UUID) async -> SQLServerCheck.Failure?? {
        guard EditorLint.serverEnabled, let tab = tabs.first(where: { $0.id == tabID }),
              let s = connections[tab.profileID]?.session else { return nil }
        if !tab.database.isEmpty, await s.current != tab.database { return nil }
        return await s.serverCheck(sql)
    }
}
