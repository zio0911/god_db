import AppKit
import Foundation
import GodDBCore
import Observation

/// DDL·정의를 연 탭이 어디서 왔는지 (생성문 새로고침용)
enum TabSource: Equatable {
    case table(String)
    case routine(RoutineMeta)
}

/// 테이블 이름 변경 / 삭제 요청 (확인 창)
struct TableActionRequest: Identifiable {
    enum Kind { case rename, drop }
    let id = UUID()
    let kind: Kind
    let profileID: UUID
    let table: String
}

/// 쿼리 탭. 탭마다 어느 접속 / 어느 DB(스키마)에서 실행할지 정해져 있다.
struct QueryTab: Identifiable {
    let id = UUID()
    /// 이 탭이 쓰는 접속
    let profileID: UUID
    /// 이 탭이 쓰는 DB (PostgreSQL 은 스키마)
    var database: String
    /// 접속별 쿼리 번호 (쿼리 1, 쿼리 2 …)
    var number: Int
    /// DDL·정의 보기처럼 특별한 탭의 이름 (없으면 "쿼리 N")
    var customTitle: String?
    /// DDL·정의 탭이면 원본 (생성문 새로고침)
    var source: TabSource?
    var text: String = ""
    /// 화면에 보이는 결과 (results 중 하나)
    var result: QueryResult?
    /// 여러 문장을 실행했을 때 문장별 결과
    var results: [QueryResult] = []
    var resultIndex = 0
    var error: String?
    var running = false
    /// 페이지 이동 / 전체 행 수 세기 중 (결과 표는 그대로 보여준다)
    var pageLoading = false
    /// 결과 편집 대기 중인 변경 (보고 있는 결과 기준)
    var edits = PendingEdits()
    var lastSQL: String?
    /// 실행 계획(EXPLAIN) 결과인지
    var isPlan = false
    var planTree: String?

    var title: String { customTitle ?? tr("쿼리 %@", "\(number)") }
}

enum MainMode: String, CaseIterable, Identifiable {
    case query = "쿼리"
    case compare = "스키마 비교"
    var id: String { rawValue }
}

enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case failed(String)
}

/// 접속 하나의 연결 상태와 스키마 정보. 여러 접속을 동시에 열어 둘 수 있다.
struct ConnectionInfo {
    var state: ConnectionState = .disconnected
    var session: DBSession?
    var databases: [String] = []
    var currentDatabase = ""
    var tables: [TableMeta] = []
    var routines: [RoutineMeta] = []
    var schemaLoading = false
}

/// 비밀번호 입력 요청 (저장 안 함 설정이거나, 저장된 비밀번호가 틀렸을 때)
struct PasswordPrompt: Identifiable {
    let id = UUID()
    let profile: ConnectionProfile
    let message: String?
}

@MainActor
@Observable
final class AppState {
    private let store = ProfileStore()

    var profiles: [ConnectionProfile] = []
    /// 사이드바에서 보고 있는 접속
    var selectedProfileID: UUID?
    /// 열려 있는 모든 접속
    var connections: [UUID: ConnectionInfo] = [:]
    var mode: MainMode = .query
    var tableFilter = ""

    /// 처음에는 탭이 없다. 접속하면 그 접속의 쿼리 탭이 생긴다.
    var tabs: [QueryTab] = []
    var selectedTabID: UUID?
    var rowLimit = 500

    var editingProfile: ConnectionProfile?
    var editingIsNew = false
    var passwordPrompt: PasswordPrompt?
    var alteringTable: TableMeta?
    /// 진행 중이거나 결과를 보고 있는 쿼리 튜닝
    var tuningJob: TuningJob?
    var tableAction: TableActionRequest?
    var editApply: EditApplyRequest?
    var showExportConnections = false
    var importRequest: ImportRequest?
    /// 사이드바에서 고른 테이블 (⌘/⇧ 클릭으로 여러 개)
    var selectedTables: Set<String> = []
    /// 열린 ER 다이어그램 창들
    var diagrams: [UUID: DiagramDoc] = [:]
    /// 마지막으로 저장한 CSV (Finder 에서 보기)
    var lastExportURL: URL?

    // 상태창 (로그 패널)
    var logs: [LogEntry] = []
    var showLog = false
    var selectedLogID: LogEntry.ID?

    /// 저장하지 않기로 한 비밀번호를 앱 실행 중에만 기억
    var sessionPasswords: [UUID: String] = [:]

    init() {
        profiles = store.load()
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        log(.info, .app, tr("GodDB %@ 시작 · 사용자 %@", version, NSUserName()))
    }

    // MARK: - 사이드바에서 보고 있는 접속 (기존 화면 코드 호환)

    private var focused: ConnectionInfo {
        selectedProfileID.flatMap { connections[$0] } ?? ConnectionInfo()
    }

    var state: ConnectionState { focused.state }
    var session: DBSession? { focused.session }
    var databases: [String] { focused.databases }
    var currentDatabase: String { focused.currentDatabase }
    var tables: [TableMeta] { focused.tables }
    var routines: [RoutineMeta] { focused.routines }
    var schemaLoading: Bool { focused.schemaLoading }

    /// 사이드바에서 보고 있는 접속의 SQL 문법 (연결 전에는 MySQL)
    var dialect: any SQLDialect { session?.dialect ?? MySQLDialect() }

    var selectedProfile: ConnectionProfile? {
        profiles.first { $0.id == selectedProfileID }
    }

    func profile(_ id: UUID) -> ConnectionProfile? {
        profiles.first { $0.id == id }
    }

    func connectionState(_ id: UUID) -> ConnectionState {
        connections[id]?.state ?? .disconnected
    }

    var connectedCount: Int { connections.values.filter { $0.state == .connected }.count }

    var filteredTables: [TableMeta] {
        let f = tableFilter.trimmingCharacters(in: .whitespaces).lowercased()
        return f.isEmpty ? tables : tables.filter { $0.name.lowercased().contains(f) }
    }

    func filteredRoutines(_ kind: RoutineMeta.Kind) -> [RoutineMeta] {
        let f = tableFilter.trimmingCharacters(in: .whitespaces).lowercased()
        return routines.filter { $0.kind == kind && (f.isEmpty || $0.name.lowercased().contains(f)) }
    }

    private func updateConnection(_ id: UUID, _ change: (inout ConnectionInfo) -> Void) {
        var info = connections[id] ?? ConnectionInfo()
        change(&info)
        connections[id] = info
    }

    // MARK: - 상태창

    var lastLog: LogEntry? { logs.last }

    func log(_ level: LogEntry.Level, _ source: LogEntry.Source, _ message: String,
             detail: String? = nil, hint: String? = nil) {
        let entry = LogEntry(level: level, source: source, message: message, detail: detail, hint: hint)
        logs.append(entry)
        LogFile.shared.append(entry)
        if logs.count > 1000 { logs.removeFirst(logs.count - 1000) }
        if level == .error {
            // 오류가 나면 상태창을 자동으로 열고 해당 항목을 선택한다.
            showLog = true
            selectedLogID = entry.id
        }
    }

    var errorCount: Int { logs.filter { $0.level == .error }.count }

    /// 오류를 상태창에 남기고, 화면에 보여줄 메시지를 돌려준다.
    @discardableResult
    func logError(_ error: any Error, _ source: LogEntry.Source, context: String, sql: String? = nil) -> String {
        let d = ErrorText.describe(error)
        var detail = tr("원본 오류: %@", "\(d.raw)")
        if let sql { detail = tr("실행한 SQL:\n%@\n\n", "\(sql)") + detail }
        log(.error, source, "\(context): \(d.message)", detail: detail, hint: d.hint)
        return d.hint.map { tr("%@\n\n해결 방법: %@", "\(d.message)", "\($0)") } ?? d.message
    }

    func toggleLog() { showLog.toggle() }

    func clearLogs() {
        logs.removeAll()
        selectedLogID = nil
    }

    // MARK: - 접속 관리

    func newProfile() {
        editingProfile = ConnectionProfile()
        editingIsNew = true
    }

    func edit(_ profile: ConnectionProfile) {
        editingProfile = profile
        editingIsNew = false
    }

    /// - Parameter password: nil 이면 기존 저장값 유지
    func saveProfile(_ profile: ConnectionProfile, password: String?) {
        if let i = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[i] = profile
        } else {
            profiles.append(profile)
        }
        if profile.savePassword {
            if let password { Keychain.setPassword(password, for: profile.id) }
        } else {
            Keychain.deletePassword(for: profile.id)
            if let password, !password.isEmpty { sessionPasswords[profile.id] = password }
        }
        persist()
        editingProfile = nil
        log(.info, .app, tr("%@ 접속 정보 저장", "\(profile.name)") + (profile.savePassword ? tr(" (비밀번호 키체인 저장)") : tr(" (비밀번호 저장 안 함)")))
        // 열려 있던 접속이면 바뀐 설정으로 다시 연결
        if connectionState(profile.id) == .connected {
            Task {
                await disconnect(profile.id)
                await connect(profile.id)
            }
        }
    }

    func deleteProfile(_ profile: ConnectionProfile) {
        Task { await disconnect(profile.id) }
        profiles.removeAll { $0.id == profile.id }
        Keychain.deletePassword(for: profile.id)
        sessionPasswords[profile.id] = nil
        tabs.removeAll { $0.profileID == profile.id }
        if !tabs.contains(where: { $0.id == selectedTabID }) { selectedTabID = tabs.last?.id }
        persist()
        if selectedProfileID == profile.id { selectedProfileID = nil }
    }

    func duplicate(_ profile: ConnectionProfile) {
        var copy = profile
        copy.id = UUID()
        copy.name += tr(" 복사본")
        if let pw = Keychain.password(for: profile.id) { Keychain.setPassword(pw, for: copy.id) }
        profiles.append(copy)
        persist()
    }

    func persist() {
        do { try store.save(profiles) } catch { logError(error, .app, context: tr("접속 목록 저장 실패")) }
    }

    /// 키체인 또는 이번 실행 중 입력한 비밀번호
    func password(for profile: ConnectionProfile) -> String? {
        if let pw = sessionPasswords[profile.id] { return pw }
        return profile.savePassword ? Keychain.password(for: profile.id) : nil
    }

    /// 비밀번호 입력창에서 확인을 눌렀을 때
    func submitPassword(_ password: String, save: Bool, for profile: ConnectionProfile) {
        passwordPrompt = nil
        var p = profile
        p.savePassword = save
        if let i = profiles.firstIndex(where: { $0.id == p.id }) { profiles[i] = p }
        if save {
            Keychain.setPassword(password, for: p.id)
            sessionPasswords[p.id] = nil
        } else {
            Keychain.deletePassword(for: p.id)
            sessionPasswords[p.id] = password
        }
        persist()
        Task { await connect(p.id) }
    }

    // MARK: - 연결 (여러 접속 동시)

    /// 사이드바에서 접속을 눌렀을 때: 이미 연결돼 있으면 보기만 바꾸고, 아니면 연결한다. 다른 접속은 끊지 않는다.
    func open(_ id: UUID) async {
        selectedProfileID = id
        switch connectionState(id) {
        case .connected:
            // 이 접속의 탭이 선택돼 있지 않으면 마지막 탭으로 이동
            if tabs.first(where: { $0.id == selectedTabID })?.profileID != id,
               let tab = tabs.last(where: { $0.profileID == id }) {
                selectTab(tab.id)
            }
        case .connecting:
            break
        case .disconnected, .failed:
            await connect(id)
        }
    }

    func connect(_ id: UUID) async {
        guard let profile = profile(id) else { return }
        selectedProfileID = id
        if connectionState(id) == .connected { return }
        let password = password(for: profile)
        if password == nil && !profile.savePassword {
            passwordPrompt = PasswordPrompt(profile: profile, message: nil)
            return
        }
        updateConnection(id) { $0.state = .connecting }
        let target = profile.ssh.map { tr("%@:%@ (SSH %@ 경유)", "\(profile.host)", "\(profile.port)", "\($0.host)") } ?? "\(profile.host):\(profile.port)"
        log(.info, .connection, tr("%@ 연결 중… %@", "\(profile.name)", "\(target)"))
        do {
            let s = try await DBSession.connect(profile: profile, password: password)
            updateConnection(id) {
                $0.session = s
                $0.state = .connected
            }
            log(.success, .connection, tr("%@ 연결됨", "\(profile.name)") + (profile.readOnly ? tr(" (읽기전용)") : "")
                + (connectedCount > 1 ? tr(" · 열린 접속 %@개", "\(connectedCount)") : ""))
            do {
                let dbs = try await s.databases()
                updateConnection(id) { $0.databases = dbs }
            } catch {
                logError(error, .schema, context: tr("%@ DB 목록 조회 실패", "\(profile.name)"))
            }
            await selectDatabase(s.dialect.initialContainer(profile: profile, available: connections[id]?.databases ?? []),
                                 for: id)
            // 이 접속의 탭이 없으면 하나 열어 준다.
            if !tabs.contains(where: { $0.profileID == id }) {
                addTab(for: id)
            } else if let tab = tabs.last(where: { $0.profileID == id }), selectedProfileID == id {
                selectTab(tab.id)
            }
        } catch {
            let message = logError(error, .connection, context: tr("%@ 연결 실패", "\(profile.name)"))
            updateConnection(id) { $0.state = .failed(message); $0.session = nil }
            // 비밀번호가 틀렸으면 다시 입력받는다.
            if ErrorText.isAuthFailure(error) {
                sessionPasswords[id] = nil
                passwordPrompt = PasswordPrompt(profile: profile, message: tr("비밀번호가 틀렸어요. 다시 입력해 주세요."))
            }
        }
    }

    /// 접속 하나를 끊는다. 그 접속의 탭은 남겨 두고, 다시 연결하면 이어서 쓸 수 있다.
    func disconnect(_ id: UUID) async {
        if let session = connections[id]?.session {
            await session.close()
            log(.info, .connection, tr("%@ 연결 끊음", "\(session.profile.name)"))
        }
        connections[id] = ConnectionInfo()
    }

    func disconnectAll() async {
        for id in connections.keys { await disconnect(id) }
    }

    /// 사이드바 DB(스키마) 선택. 보고 있는 탭이 같은 접속이면 그 탭의 DB 도 바꾼다.
    func selectDatabase(_ db: String, for id: UUID? = nil) async {
        guard let id = id ?? selectedProfileID, let session = connections[id]?.session, !db.isEmpty else { return }
        updateConnection(id) {
            $0.currentDatabase = db
            $0.schemaLoading = true
        }
        if id == selectedProfileID { selectedTables = [] }
        if let i = selectedTabIndex, tabs[i].profileID == id { tabs[i].database = db }
        do {
            try await session.use(db)
            let tables = try await session.loadSchema(db)
            updateConnection(id) { $0.tables = tables }
            log(.info, .schema, tr("%@ / %@ 스키마 불러옴 · 테이블 %@개", "\(session.profile.name)", "\(db)", "\(tables.count)"))
        } catch {
            updateConnection(id) { $0.tables = [] }
            logError(error, .schema, context: tr("%@ 스키마 조회 실패", "\(db)"))
        }
        do {
            let routines = try await session.loadRoutines(db)
            updateConnection(id) { $0.routines = routines }
        } catch {
            updateConnection(id) { $0.routines = [] }
            logError(error, .schema, context: tr("%@ 뷰/프로시저 조회 실패", "\(db)"))
        }
        updateConnection(id) { $0.schemaLoading = false }
    }

    func refreshSchema(for id: UUID? = nil) async {
        guard let id = id ?? selectedProfileID, let db = connections[id]?.currentDatabase else { return }
        await selectDatabase(db, for: id)
    }

    // MARK: - 쿼리 탭

    var selectedTabIndex: Int? {
        tabs.firstIndex { $0.id == selectedTabID }
    }

    var selectedTab: QueryTab? { selectedTabIndex.map { tabs[$0] } }

    /// 새 쿼리 탭. 기본은 사이드바에서 보고 있는 접속 / DB.
    @discardableResult
    func addTab(text: String = "", title: String? = nil, for profileID: UUID? = nil) -> UUID? {
        guard let id = profileID ?? selectedProfileID, connectionState(id) == .connected else {
            log(.warning, .app, tr("먼저 왼쪽에서 접속을 연결해 주세요. 쿼리 탭은 연결된 접속 기준으로 만들어져요."))
            return nil
        }
        let number = (tabs.filter { $0.profileID == id }.map(\.number).max() ?? 0) + 1
        let tab = QueryTab(profileID: id, database: connections[id]?.currentDatabase ?? "",
                           number: number, customTitle: title, text: text)
        tabs.append(tab)
        selectedTabID = tab.id
        selectedProfileID = id
        mode = .query
        return tab.id
    }

    /// 탭을 고르면 사이드바도 그 탭의 접속 / DB 로 맞춘다.
    func selectTab(_ id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        selectedTabID = id
        selectedProfileID = tab.profileID
        mode = .query
        if let info = connections[tab.profileID], info.state == .connected,
           !tab.database.isEmpty, info.currentDatabase != tab.database {
            Task { await selectDatabase(tab.database, for: tab.profileID) }
        }
    }

    func closeTab(_ id: UUID) {
        guard let i = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: i)
        if selectedTabID == id {
            if let next = tabs.indices.contains(i) ? tabs[i] : tabs.last {
                selectTab(next.id)
            } else {
                selectedTabID = nil
            }
        }
    }

    func openTableQuery(_ table: String) {
        let sql = dialect.selectAllSQL(table)
        if let i = selectedTabIndex, tabs[i].profileID == selectedProfileID,
           tabs[i].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            tabs[i].text = sql
        } else if addTab(text: sql) == nil {
            return
        }
        mode = .query
        Task { await run(sql: sql) }
    }

    func openTableDDL(_ table: TableMeta) async {
        guard let session else { return }
        do {
            let ddl = try await session.tableDDL(table)
            if let id = addTab(text: ddl + "\n", title: "DDL · \(table.name)") {
                update(id) { $0.source = .table(table.name) }
            }
            log(.info, .schema, tr("%@ CREATE 문 열기", "\(table.name)"))
        } catch {
            logError(error, .schema, context: tr("%@ CREATE 문 조회 실패", "\(table.name)"))
        }
    }

    /// 뷰/프로시저/함수/트리거 정의를 새 탭에 연다.
    func openRoutine(_ routine: RoutineMeta) async {
        guard let session else { return }
        do {
            let body = try await session.definition(of: routine) ?? ""
            if let id = addTab(text: body + "\n", title: "\(routine.kind.title) · \(routine.name)") {
                update(id) { $0.source = .routine(routine) }
            }
            log(.info, .schema, tr("%@ %@ 정의 열기", "\(routine.kind.title)", "\(routine.name)"))
        } catch {
            logError(error, .schema, context: tr("%@ %@ 정의 조회 실패", "\(routine.kind.title)", "\(routine.name)"))
        }
    }

    /// 인덱스 상세 (카디널리티 등)
    func openIndexes(_ table: String) {
        let sql = dialect.indexDetailSQL(table, schema: currentDatabase)
        guard addTab(text: sql, title: tr("인덱스 · %@", "\(table)")) != nil else { return }
        Task { await run(sql: sql) }
    }

    /// 탭이 쓰는 연결. 연결이 끊겼으면 nil. 탭의 DB 가 세션의 현재 DB 와 다르면 바꾼다.
    private func session(for tab: QueryTab) async throws -> DBSession? {
        guard let s = connections[tab.profileID]?.session else { return nil }
        if !tab.database.isEmpty, await s.current != tab.database {
            try await s.use(tab.database)
        }
        return s
    }

    private func notConnectedMessage(_ tab: QueryTab) -> String {
        tr("%@ 이(가) 연결돼 있지 않아요. 왼쪽에서 접속을 눌러 다시 연결해 주세요.", "\(profile(tab.profileID)?.name ?? tr("이 탭의 접속"))")
    }

    /// 선택된 탭에서 sql 실행. explain 이면 실행 계획을 보여준다.
    func run(sql: String, explain: Bool = false) async {
        guard let i = selectedTabIndex else { return }
        let tab = tabs[i]
        let tabID = tab.id
        var trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix(";") { trimmed.removeLast() }
        guard !trimmed.isEmpty else { return }
        if explain && SQLText.firstKeyword(trimmed) == "EXPLAIN" {
            trimmed = String(trimmed.dropFirst("EXPLAIN".count)).trimmingCharacters(in: .whitespaces)
        }
        tabs[i].running = true
        tabs[i].error = nil
        let limit = rowLimit
        do {
            guard let session = try await session(for: tab) else {
                update(tabID) { $0.error = notConnectedMessage(tab); $0.running = false }
                log(.warning, .query, notConnectedMessage(tab))
                return
            }
            let finalSQL = explain ? session.dialect.explain(trimmed).main : trimmed
            update(tabID) { $0.lastSQL = finalSQL }
            let result: QueryResult
            var tree: String? = nil
            if explain {
                (result, tree) = try await session.explain(trimmed)
            } else {
                result = try await session.execute(finalSQL, limit: limit)
            }
            var shown = result
            shown.sql = trimmed
            update(tabID) {
                $0.edits = PendingEdits()
                $0.result = shown
                $0.results = [shown]
                $0.resultIndex = 0
                $0.running = false
                $0.isPlan = explain
                $0.planTree = tree
            }
            let ms = Int(result.elapsed * 1000)
            let label = "[\(session.profile.name)] "
            if explain {
                let warnings = PlanAnalyzer.warnings(result)
                log(warnings.isEmpty ? .success : .warning, .query,
                    label + tr("실행 계획 · 주의 %@건 · %@", "\(warnings.count)", "\(Self.oneLine(trimmed))"),
                    detail: ([finalSQL] + warnings.map { "[\($0.table)] \($0.message)" }).joined(separator: "\n"))
            } else {
                let summary = result.columns.isEmpty ? (result.message ?? tr("실행 완료"))
                    : tr("%@행", "\(result.rows.count)") + (result.hasMore ? "+" : "")
                log(.success, .query, label + "\(summary) · \(ms)ms · \(Self.oneLine(trimmed))", detail: trimmed)
            }
            let kw = SQLText.firstKeyword(trimmed)
            await afterStatements(session: session, tabID: tabID,
                                  schemaChanged: !explain && ["CREATE", "ALTER", "DROP", "RENAME", "TRUNCATE"].contains(kw),
                                  usedUse: kw == "USE")
        } catch {
            let message = logError(error, .query, context: explain ? tr("실행 계획 실패") : tr("쿼리 실패"), sql: trimmed)
            update(tabID) { $0.error = message; $0.running = false }
        }
    }

    /// 여러 문장을 위에서부터 차례로 실행한다. 실패하면 그 문장에서 멈춘다.
    func runScript(_ statements: [String]) async {
        let list = statements.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !list.isEmpty else { return }
        if list.count == 1 { await run(sql: list[0]); return }
        guard let i = selectedTabIndex else { return }
        let tab = tabs[i]
        let tabID = tab.id
        tabs[i].running = true
        tabs[i].error = nil
        tabs[i].isPlan = false
        tabs[i].planTree = nil
        tabs[i].lastSQL = list.joined(separator: ";\n")
        let limit = rowLimit
        let started = Date()
        var results: [QueryResult] = []
        var schemaChanged = false
        var usedUse = false

        func finish(error: String?) {
            // 결과 집합이 있는 마지막 결과를 먼저 보여준다.
            let index = results.lastIndex { !$0.columns.isEmpty } ?? max(0, results.count - 1)
            update(tabID) {
                $0.edits = PendingEdits()
                $0.results = results
                $0.resultIndex = index
                $0.result = results.isEmpty ? nil : results[index]
                $0.error = error
                $0.running = false
            }
        }

        let session: DBSession
        do {
            guard let s = try await self.session(for: tab) else {
                finish(error: notConnectedMessage(tab))
                return
            }
            session = s
        } catch {
            finish(error: logError(error, .query, context: tr("DB 전환 실패")))
            return
        }

        for (n, statement) in list.enumerated() {
            do {
                var r = try await session.execute(statement, limit: limit)
                r.sql = statement
                results.append(r)
                let kw = SQLText.firstKeyword(statement)
                if ["CREATE", "ALTER", "DROP", "RENAME", "TRUNCATE"].contains(kw) { schemaChanged = true }
                if kw == "USE" { usedUse = true }
            } catch {
                let message = logError(error, .query, context: tr("%@/%@번째 문장 실패", "\(n + 1)", "\(list.count)"), sql: statement)
                finish(error: tr("%@번째 문장에서 멈췄어요. (앞의 %@개는 실행됨)\n\n%@", "\(n + 1)", "\(n)", "\(message)"))
                await afterStatements(session: session, tabID: tabID, schemaChanged: schemaChanged, usedUse: usedUse)
                return
            }
        }
        finish(error: nil)
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        let withRows = results.filter { !$0.columns.isEmpty }.count
        log(.success, .query, tr("[%@] %@개 문장 실행 · 결과 %@개 · %@ms", "\(session.profile.name)", "\(list.count)", "\(withRows)", "\(ms)"),
            detail: list.joined(separator: ";\n\n"))
        await afterStatements(session: session, tabID: tabID, schemaChanged: schemaChanged, usedUse: usedUse)
    }

    /// USE 로 DB 를 바꿨으면 탭의 DB 도 바꾸고, 구조가 바뀌었으면 사이드바 스키마를 새로 읽는다.
    private func afterStatements(session: DBSession, tabID: UUID, schemaChanged: Bool, usedUse: Bool) async {
        let id = session.profile.id
        if usedUse {
            let db = await session.current
            if !db.isEmpty {
                update(tabID) { $0.database = db }
                if selectedTabID == tabID { await selectDatabase(db, for: id) }
                return
            }
        }
        if schemaChanged { await refreshSchema(for: id) }
    }

    /// 보고 있는 결과의 다른 페이지를 가져온다. (같은 쿼리를 OFFSET 만 바꿔 다시 실행)
    func loadPage(_ page: Int, in tabID: UUID) async {
        guard let t = tabs.first(where: { $0.id == tabID }),
              let current = t.result, current.isPaged, let sql = current.sql, page >= 0 else { return }
        let index = t.resultIndex
        update(tabID) { $0.pageLoading = true; $0.error = nil }
        do {
            guard let session = try await session(for: t) else {
                update(tabID) { $0.error = notConnectedMessage(t); $0.pageLoading = false }
                return
            }
            var r = try await session.execute(sql, limit: current.pageSize, page: page, sort: current.serverSort)
            r.sql = sql
            r.totalCount = current.totalCount
            // 마지막 페이지를 넘어가면 (데이터가 줄어든 경우) 빈 페이지 대신 그대로 둔다.
            if r.rows.isEmpty && page > 0 {
                update(tabID) { $0.pageLoading = false }
                log(.info, .query, tr("더 이상 행이 없어요."))
                return
            }
            update(tabID) {
                $0.edits = PendingEdits()
                $0.result = r
                if $0.results.indices.contains(index) { $0.results[index] = r }
                $0.pageLoading = false
            }
            log(.info, .query, tr("%@–%@행 (%@페이지) · %@ms", "\(r.rowOffset + 1)", "\(r.rowOffset + r.rows.count)", "\(page + 1)", "\(Int(r.elapsed * 1000))"))
        } catch {
            let message = logError(error, .query, context: tr("페이지 불러오기 실패"), sql: sql)
            update(tabID) { $0.error = message; $0.pageLoading = false }
        }
    }

    /// 헤더 클릭 정렬: 원래 쿼리를 감싸 ORDER BY 로 다시 실행하고 첫 페이지부터 보여준다.
    /// (SHOW 처럼 감쌀 수 없는 결과만 받아 온 행을 앱에서 정렬)
    func sortResult(_ tabID: UUID, column: String, ascending: Bool) async {
        guard let t = tabs.first(where: { $0.id == tabID }), let current = t.result, let sql = current.sql,
              let columnIndex = current.columns.firstIndex(where: { $0.name == column }) else { return }
        if !t.edits.isEmpty {
            log(.warning, .query, tr("편집 중인 변경을 적용하거나 되돌린 뒤 정렬하세요."))
            return
        }
        let index = t.resultIndex
        let sort = ResultSort(column: column, ascending: ascending)
        guard let session = connections[t.profileID]?.session, session.dialect.sortedSQL(sql, sort: sort) != nil else {
            var r = current
            r.rows = ResultSorting.sorted(current.rows, column: columnIndex, ascending: ascending)
            r.clientSort = sort
            update(tabID) {
                $0.result = r
                if $0.results.indices.contains(index) { $0.results[index] = r }
            }
            return
        }
        update(tabID) { $0.pageLoading = true; $0.error = nil }
        do {
            guard let session = try await self.session(for: t) else {
                update(tabID) { $0.error = notConnectedMessage(t); $0.pageLoading = false }
                return
            }
            let size = current.pageSize > 0 ? current.pageSize : rowLimit
            var r = try await session.execute(sql, limit: size, page: 0, sort: sort)
            r.sql = sql
            r.totalCount = current.totalCount
            update(tabID) {
                $0.result = r
                if $0.results.indices.contains(index) { $0.results[index] = r }
                $0.pageLoading = false
            }
            log(.info, .query, tr("정렬: %@ %@ · %@ms", column, ascending ? "↑" : "↓", "\(Int(r.elapsed * 1000))"),
                detail: session.dialect.sortedSQL(sql, sort: sort))
        } catch {
            let message = logError(error, .query, context: tr("정렬 실패"), sql: sql)
            update(tabID) { $0.error = message; $0.pageLoading = false }
        }
    }

    /// 보고 있는 결과의 전체 행 수를 센다.
    func countRows(in tabID: UUID) async {
        guard let t = tabs.first(where: { $0.id == tabID }), let sql = t.result?.sql else { return }
        let index = t.resultIndex
        update(tabID) { $0.pageLoading = true }
        defer { update(tabID) { $0.pageLoading = false } }
        do {
            guard let session = try await session(for: t), let total = try await session.count(sql) else { return }
            update(tabID) {
                $0.result?.totalCount = total
                if $0.results.indices.contains(index) { $0.results[index].totalCount = total }
            }
            log(.info, .query, tr("전체 %@행", "\(total.formatted())"))
        } catch {
            logError(error, .query, context: tr("전체 행 수 세기 실패"), sql: sql)
        }
    }

    // MARK: - 생성문 새로고침 / 테이블 이름 변경 / 삭제

    /// DDL·정의 탭의 내용을 DB 에서 다시 읽어 바꾼다.
    func refreshSource(_ tabID: UUID) async {
        guard let tab = tabs.first(where: { $0.id == tabID }), let source = tab.source else { return }
        do {
            guard let session = try await session(for: tab) else {
                update(tabID) { $0.error = notConnectedMessage(tab) }
                return
            }
            let text: String
            switch source {
            case .table(let name):
                // 구조가 바뀌었을 수 있으니 스키마를 새로 읽고 DDL 을 만든다
                let tables = try await session.loadSchema(tab.database)
                updateConnection(tab.profileID) { $0.tables = tables }
                guard let meta = tables.first(where: { $0.name == name }) else {
                    update(tabID) { $0.error = tr("테이블 %@ 이(가) 더 이상 없어요. (이름이 바뀌었거나 삭제됨)", name) }
                    return
                }
                text = try await session.tableDDL(meta)
            case .routine(let routine):
                text = try await session.definition(of: routine) ?? ""
            }
            update(tabID) { $0.text = text + "\n"; $0.error = nil }
            log(.info, .schema, tr("%@ 생성문 새로고침", tab.title))
        } catch {
            let message = logError(error, .schema, context: tr("생성문 새로고침 실패"))
            update(tabID) { $0.error = message }
        }
    }

    func requestRename(_ table: String) {
        guard let id = selectedProfileID else { return }
        tableAction = TableActionRequest(kind: .rename, profileID: id, table: table)
    }

    func requestDrop(_ table: String) {
        guard let id = selectedProfileID else { return }
        tableAction = TableActionRequest(kind: .drop, profileID: id, table: table)
    }

    /// 테이블 이름 변경 / 삭제 실행. 성공하면 사이드바를 새로 읽고, 열린 DDL 탭의 이름도 맞춘다.
    func performTableAction(_ request: TableActionRequest, newName: String = "") async throws {
        guard let session = connections[request.profileID]?.session else { throw DBError.notConnected }
        let db = connections[request.profileID]?.currentDatabase ?? ""
        if !db.isEmpty, await session.current != db { try await session.use(db) }
        let sql: String
        switch request.kind {
        case .rename: sql = session.dialect.renameTableSQL(request.table, to: newName)
        case .drop: sql = session.dialect.dropTableSQL(request.table)
        }
        do {
            _ = try await session.execute(sql, limit: 0)
        } catch {
            logError(error, .schema, context: request.kind == .rename ? tr("테이블 이름 변경 실패") : tr("테이블 삭제 실패"), sql: sql)
            throw error
        }
        switch request.kind {
        case .rename:
            log(.success, .schema, tr("테이블 이름 변경: %@ → %@", request.table, newName), detail: sql)
            for i in tabs.indices where tabs[i].profileID == request.profileID && tabs[i].source == .table(request.table) {
                tabs[i].source = .table(newName)
                tabs[i].customTitle = "DDL · \(newName)"
            }
        case .drop:
            log(.success, .schema, tr("테이블 삭제: %@", request.table), detail: sql)
        }
        await refreshSchema(for: request.profileID)
    }

    /// 튜닝 결과 등을 탭 편집기 끝에 덧붙인다.
    func insertIntoTab(_ tabID: UUID, sql: String, label: String) {
        update(tabID) {
            var text = $0.text
            if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
            text += "\n-- \(label)\n\(sql)" + (sql.hasSuffix(";") ? "" : ";") + "\n"
            $0.text = text
        }
        selectTab(tabID)
        tuningJob = nil
    }

    func selectResult(_ index: Int, in tabID: UUID) {
        update(tabID) {
            guard $0.results.indices.contains(index) else { return }
            $0.edits = PendingEdits()
            $0.resultIndex = index
            $0.result = $0.results[index]
        }
    }

    // MARK: - 테이블 수정 (ALTER) — 사이드바에서 보고 있는 접속 / DB

    func executeAlter(_ sql: String, table: String) async throws {
        guard let session else { throw DBError.notConnected }
        do {
            if !currentDatabase.isEmpty, await session.current != currentDatabase {
                try await session.use(currentDatabase)
            }
            _ = try await session.execute(sql, limit: 0)
            log(.success, .schema, tr("%@ 테이블 수정 완료", "\(table)"), detail: sql)
            await refreshSchema()
        } catch {
            logError(error, .schema, context: tr("%@ 테이블 수정 실패", "\(table)"), sql: sql)
            throw error
        }
    }

    static func oneLine(_ sql: String, max: Int = 80) -> String {
        let s = sql.split(whereSeparator: \.isNewline).joined(separator: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return s.count > max ? String(s.prefix(max)) + "…" : s
    }

    func update(_ id: UUID, _ change: (inout QueryTab) -> Void) {
        guard let i = tabs.firstIndex(where: { $0.id == id }) else { return }
        change(&tabs[i])
    }
}
