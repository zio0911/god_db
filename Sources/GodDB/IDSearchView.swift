import GodDBCore
import SwiftUI

/// ID 로 찾기 창을 여는 요청 (사이드바 우클릭이면 그 테이블이 미리 선택됨)
struct IDSearchRequest: Identifiable {
    let id = UUID()
    let profileID: UUID
    let database: String
    let table: String?
}

/// ID 로 찾기로 연 탭의 요청 내용 (결과 아래 "없는 ID" 비교용)
struct IDSearchRun: Equatable {
    let column: String
    let values: [String]
    let sql: String
}

extension AppState {
    /// ID 로 찾기가 가능한지 (연결된 SQL 접속)
    var canSearchIDs: Bool {
        state == .connected && selectedProfile.map { $0.kind != .redis } == true
    }

    /// ID 로 찾기 창 열기 (메뉴 ⌥⌘F · 사이드바 테이블 우클릭)
    func openIDSearch(table: String? = nil) {
        guard canSearchIDs, let id = selectedProfileID else { return }
        idSearchRequest = IDSearchRequest(profileID: id, database: currentDatabase, table: table)
    }

    /// 새 쿼리 탭에 `SELECT * … WHERE col IN (…)` 을 넣고 실행한다. 행 수 제한은 값 개수 이상으로 (최대 5,000).
    func runIDSearch(profileID: UUID, table: String, column: String, values: [String], numeric: Bool) {
        guard let d = connections[profileID]?.session?.dialect, !values.isEmpty else { return }
        let sql = IDSearch.sql(table: table, column: column, values: values, numeric: numeric, dialect: d)
        guard let tabID = addTab(text: sql, title: IDSearch.tabTitle(table: table, column: column, count: values.count),
                                 for: profileID) else { return }
        update(tabID) { $0.idSearch = IDSearchRun(column: column, values: values, sql: sql) }
        let limit = IDSearch.rowLimit(current: rowLimit, valueCount: values.count)
        Task { await run(sql: sql, rowLimitOverride: limit) }
    }
}

/// ID 로 찾기 (⌥⌘F): 로그에서 복사한 글을 붙여넣으면 ID 를 뽑아 IN (…) 으로 조회
struct IDSearchView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    let request: IDSearchRequest

    @State private var memory = IDSearchMemory()
    @State private var tableName = ""
    @State private var columnName = ""
    @State private var text = ""
    @State private var includeText = false

    private var tables: [TableMeta] {
        app.connections[request.profileID]?.tables ?? []
    }

    private var table: TableMeta? { tables.first { $0.name == tableName } }
    private var column: ColumnMeta? { table?.columns.first { $0.name == columnName } }
    private var columnIsNumeric: Bool { column.map { IDSearch.isNumericType($0.columnType) } ?? false }
    /// 숫자만 뽑을지: 숫자 컬럼이고 "문자 ID 포함" 을 켜지 않았을 때
    private var numericOnly: Bool { columnIsNumeric && !includeText }

    var body: some View {
        let found = IDSearch.extract(text, numeric: numericOnly)
        VStack(alignment: .leading, spacing: 12) {
            Label(tr("ID 로 찾기"), systemImage: "number").font(.headline)
            HStack(spacing: 12) {
                Picker(tr("테이블"), selection: $tableName) {
                    if table == nil { Text(tr("테이블을 고르세요")).tag("") }
                    ForEach(tables) { t in Text(t.name).tag(t.name) }
                }
                Picker(tr("컬럼"), selection: $columnName) {
                    if column == nil { Text("—").tag("") }
                    ForEach(table?.columns ?? []) { c in Text("\(c.name) (\(c.columnType))").tag(c.name) }
                }
                .disabled(table == nil)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(tr("붙여넣기")).font(.callout).foregroundStyle(.secondary)
                TextEditor(text: $text)
                    .font(.system(.callout, design: .monospaced))
                    .frame(minHeight: 140)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(.separator))
                    .accessibilityLabel(tr("붙여넣기"))
            }
            Text(summary(found))
                .font(.callout)
                .foregroundStyle(found.values.isEmpty ? .secondary : .primary)
                .lineLimit(3)
                .textSelection(.enabled)
            if found.overflow > 0 {
                Text(tr("1,000개까지만 조회해요 (나머지 %@개는 다시 붙여넣으세요)", found.overflow.formatted()))
                    .font(.callout).foregroundStyle(.orange)
            }
            Toggle(tr("문자 ID 포함 (영문 · 하이픈)"),
                   isOn: Binding(get: { includeText || !columnIsNumeric }, set: { includeText = $0 }))
                .disabled(column != nil && !columnIsNumeric)
                .help(tr("숫자 컬럼에서도 A-77 · UUID 같은 문자 ID 를 뽑아요"))
            HStack {
                Spacer()
                Button(tr("취소")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(tr("조회")) { submit(found) }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(found.values.isEmpty || column == nil)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear(perform: setDefaults)
        .onChange(of: tableName) { columnName = defaultColumn(for: tableName) }
    }

    private func summary(_ found: IDSearch.Extraction) -> String {
        var s = tr("찾은 값 %@개", "\(found.uniqueCount)")
        if found.duplicates > 0 { s += tr(" (중복 %@개 제외)", "\(found.duplicates)") }
        if !found.values.isEmpty { s += " : " + IDSearch.preview(found.values) }
        return s
    }

    /// 테이블: 사이드바에서 고른 테이블 → 이 기능에서 마지막으로 쓴 테이블 → 빈칸
    private func setDefaults() {
        memory = IDSearchStore.shared.load()
        let names = Set(tables.map(\.name))
        let sidebar = request.table ?? tables.first { app.selectedTables.contains($0.name) }?.name
        let last = memory.lastTable(profileID: request.profileID, database: request.database)
        tableName = [sidebar, last].compactMap { $0 }.first { names.contains($0) } ?? ""
        columnName = defaultColumn(for: tableName)
    }

    /// 컬럼: 이 테이블에서 마지막으로 쓴 컬럼 → 기본 키(단일 컬럼) → 첫 컬럼
    private func defaultColumn(for name: String) -> String {
        guard let t = tables.first(where: { $0.name == name }) else { return "" }
        let cols = t.columns.map(\.name)
        if let last = memory.lastColumn(profileID: request.profileID, database: request.database, table: name),
           cols.contains(last) { return last }
        if let pk = t.indexes.first(where: \.isPrimary), pk.columns.count == 1, cols.contains(pk.columns[0]) {
            return pk.columns[0]
        }
        let pkCols = t.columns.filter(\.isPrimaryKey)
        if pkCols.count == 1 { return pkCols[0].name }
        return cols.first ?? ""
    }

    private func submit(_ found: IDSearch.Extraction) {
        guard let column, !found.values.isEmpty else { return }
        memory.remember(.init(profileID: request.profileID, database: request.database, table: tableName, column: column.name))
        IDSearchStore.shared.save(memory)
        dismiss()
        app.runIDSearch(profileID: request.profileID, table: tableName, column: column.name,
                        values: found.values, numeric: numericOnly)
    }
}

/// 결과 아래 줄: `요청 N · 찾음 N · 없음 N [없는 ID 복사]` (결과가 끝까지 들어온 경우에만)
struct IDSearchMissingBar: View {
    let run: IDSearchRun
    let result: QueryResult

    /// 결과가 이 ID 조회의 것이고 잘리지 않았는지
    static func applies(_ run: IDSearchRun, to result: QueryResult) -> Bool {
        result.sql == run.sql && !result.hasMore && (result.appendMode || result.page == 0)
            && result.columns.contains { $0.name.caseInsensitiveCompare(run.column) == .orderedSame }
    }

    var body: some View {
        if let col = result.columns.first(where: { $0.name.caseInsensitiveCompare(run.column) == .orderedSame }) {
            let cmp = IDSearch.compare(requested: run.values,
                                       found: result.rows.map { $0.values.indices.contains(col.id) ? $0.values[col.id] : nil })
            HStack(spacing: 8) {
                Image(systemName: cmp.missing.isEmpty ? "checkmark.circle" : "exclamationmark.circle")
                    .foregroundStyle(cmp.missing.isEmpty ? .green : .orange)
                Text(tr("요청 %@ · 찾음 %@ · 없음 %@", "\(cmp.requested)", "\(cmp.found)", "\(cmp.missing.count)"))
                if !cmp.missing.isEmpty {
                    Text(IDSearch.preview(cmp.missing))
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                        .textSelection(.enabled)
                    Button(tr("없는 ID 복사")) { Pasteboard.copy(cmp.missing.joined(separator: "\n")) }
                        .controlSize(.small)
                }
                Spacer(minLength: 0)
            }
            .font(.callout)
            .padding(.horizontal, 8).padding(.vertical, 4)
        }
    }
}
