import GodDBCore
import SwiftUI

/// 셀 표시 상태
enum CellState {
    case normal, modified, inserted, insertedDefault, deleted
}

/// 결과 편집 적용 확인 창 요청
struct EditApplyRequest: Identifiable {
    let id = UUID()
    let tabID: UUID
    let statements: [String]
}

/// 새 행 id 는 기존 행과 겹치지 않게 큰 수부터
let newRowBase = 1_000_000

extension PendingEdits {
    /// 화면에 보일 행: 기존 행(수정 반영) + 새 행
    func displayRows(_ r: QueryResult) -> [QueryResult.Row] {
        let existing = r.rows.map { row -> QueryResult.Row in
            guard let changes = updates[row.id] else { return row }
            var values = row.values
            for (i, v) in changes where values.indices.contains(i) { values[i] = v }
            return QueryResult.Row(id: row.id, values: values)
        }
        let added = inserts.enumerated().map { i, values in
            QueryResult.Row(id: newRowBase + i, values: r.columns.indices.map { values[$0] ?? nil })
        }
        return existing + added
    }

    func state(row: Int, column: Int) -> CellState {
        if row >= newRowBase {
            let i = row - newRowBase
            guard inserts.indices.contains(i) else { return .normal }
            return inserts[i].keys.contains(column) ? .inserted : .insertedDefault
        }
        if deletes.contains(row) { return .deleted }
        if updates[row]?.keys.contains(column) == true { return .modified }
        return .normal
    }
}

extension AppState {
    /// 결과를 고칠 수 있으면 대상, 못 고치면 이유. 편집과 상관없는 결과(빈 결과, 실행 계획)는 nil.
    func editTarget(for tab: QueryTab) -> Result<EditTarget, Error>? {
        guard let result = tab.result, !result.columns.isEmpty, !tab.isPlan, let sql = result.sql else { return nil }
        if profile(tab.profileID)?.readOnly == true { return .failure(DBError.readOnlyBlocked) }
        let tables = connections[tab.profileID]?.tables ?? []
        return Result { try ResultEditing.target(sql: sql, columns: result.columns.map(\.name), tables: tables) }
    }

    private func editTab(_ tabID: UUID, _ change: (inout QueryTab) -> Void) {
        guard let i = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        change(&tabs[i])
    }

    /// 셀 값 바꾸기 (nil = NULL). 원래 값과 같아지면 변경에서 뺀다.
    func setCell(_ tabID: UUID, row: Int, column: Int, value: String?) {
        editTab(tabID) { tab in
            if row >= newRowBase {
                let i = row - newRowBase
                guard tab.edits.inserts.indices.contains(i) else { return }
                tab.edits.inserts[i][column] = .some(value)
                return
            }
            let original = tab.result?.rows.first { $0.id == row }?.values[column] ?? nil
            var changes = tab.edits.updates[row] ?? [:]
            if value == original {
                changes.removeValue(forKey: column)
            } else {
                changes[column] = .some(value)
            }
            tab.edits.updates[row] = changes.isEmpty ? nil : changes
        }
    }

    /// 입력하지 않은 새 행 셀을 DB 기본값으로 되돌린다.
    func resetInsertedCell(_ tabID: UUID, row: Int, column: Int) {
        editTab(tabID) { tab in
            let i = row - newRowBase
            guard tab.edits.inserts.indices.contains(i) else { return }
            tab.edits.inserts[i].removeValue(forKey: column)
        }
    }

    @discardableResult
    func addRow(_ tabID: UUID) -> Int? {
        var id: Int?
        editTab(tabID) { tab in
            tab.edits.inserts.append([:])
            id = newRowBase + tab.edits.inserts.count - 1
        }
        return id
    }

    /// 선택한 행을 삭제 표시 (이미 표시돼 있으면 해제). 새 행은 바로 뺀다.
    func toggleDelete(_ tabID: UUID, rows: Set<Int>) {
        editTab(tabID) { tab in
            for id in rows.sorted(by: >) {
                if id >= newRowBase {
                    let i = id - newRowBase
                    if tab.edits.inserts.indices.contains(i) { tab.edits.inserts.remove(at: i) }
                } else if tab.edits.deletes.contains(id) {
                    tab.edits.deletes.remove(id)
                } else {
                    tab.edits.deletes.insert(id)
                }
            }
        }
    }

    func revertEdits(_ tabID: UUID) {
        editTab(tabID) { $0.edits = PendingEdits() }
    }

    func requestApplyEdits(_ tabID: UUID) {
        guard let tab = tabs.first(where: { $0.id == tabID }), let result = tab.result,
              case .success(let target) = editTarget(for: tab), let session = connections[tab.profileID]?.session else { return }
        let statements = ResultEditing.statements(tab.edits, target: target, rows: result.rows, dialect: session.dialect)
        guard !statements.isEmpty else { return }
        editApply = EditApplyRequest(tabID: tabID, statements: statements)
    }

    /// 트랜잭션으로 적용하고, 성공하면 같은 페이지를 다시 읽는다.
    func applyEdits(_ request: EditApplyRequest) async throws {
        guard let tab = tabs.first(where: { $0.id == request.tabID }),
              let session = connections[tab.profileID]?.session else { throw DBError.notConnected }
        if !tab.database.isEmpty, await session.current != tab.database { try await session.use(tab.database) }
        do {
            try await session.executeInTransaction(request.statements)
        } catch {
            logError(error, .query, context: tr("데이터 변경 실패 (모두 되돌림)"), sql: request.statements.joined(separator: "\n"))
            throw error
        }
        log(.success, .query, tr("데이터 변경 %@건 적용", "\(request.statements.count)"),
            detail: request.statements.joined(separator: "\n"))
        revertEdits(request.tabID)
        if let page = tab.result?.page, tab.result?.isPaged == true {
            await loadPage(page, in: request.tabID)
        } else if let sql = tab.result?.sql {
            selectTab(request.tabID)
            await run(sql: sql)
        }
    }
}

/// 결과 위 편집 막대
struct EditBar: View {
    @Environment(AppState.self) private var app
    let tab: QueryTab
    let target: Result<EditTarget, Error>
    @Binding var selection: Set<Int>

    var body: some View {
        HStack(spacing: 8) {
            switch target {
            case .success(let t):
                Image(systemName: "pencil.circle").foregroundStyle(Color.accentColor)
                Text(tr("%@ 편집 가능 · 행을 고르면 오른쪽에서 값을 고칠 수 있어요", t.table.name))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button {
                    if let id = app.addRow(tab.id) { selection = [id] }
                } label: { Label(tr("행 추가"), systemImage: "plus") }
                Button {
                    app.toggleDelete(tab.id, rows: selection)
                } label: { Label(tr("선택 행 삭제"), systemImage: "minus") }
                    .disabled(selection.isEmpty)
                    .help(tr("한 번 더 누르면 삭제 표시를 풀어요"))
                if !tab.edits.isEmpty {
                    Divider().frame(height: 14)
                    Text(tr("변경 %@건", "\(tab.edits.count)"))
                        .font(.caption.weight(.semibold)).foregroundStyle(.orange)
                    Button(tr("되돌리기")) { app.revertEdits(tab.id) }
                    Button {
                        app.requestApplyEdits(tab.id)
                    } label: { Label(tr("적용…"), systemImage: "checkmark.circle") }
                        .foregroundStyle(Color.accentColor)
                }
            case .failure(let error):
                Image(systemName: "lock").foregroundStyle(.secondary)
                Text(tr("편집 불가: %@", ErrorText.describe(error).message))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .help(ErrorText.describe(error).message)
                Spacer()
            }
        }
        .buttonStyle(.hover)
        .font(.callout)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.bar)
    }
}

/// 변경 적용 확인 창 (실행할 SQL 미리보기)
struct EditApplySheet: View {
    @Environment(AppState.self) private var app
    let request: EditApplyRequest
    @State private var working = false
    @State private var error: String?

    var body: some View {
        let tab = app.tabs.first { $0.id == request.tabID }
        VStack(alignment: .leading, spacing: 12) {
            Label(tr("데이터 변경 적용"), systemImage: "square.and.pencil").font(.headline)
            if let tab {
                Text("\(app.profile(tab.profileID)?.name ?? "") / \(tab.database)").foregroundStyle(.secondary)
            }
            Text(tr("아래 %@개 문장을 한 트랜잭션으로 실행해요. 하나라도 실패하면 모두 되돌려요.", "\(request.statements.count)"))
                .font(.callout)
            ScrollView {
                Text(request.statements.joined(separator: "\n"))
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(minHeight: 120, maxHeight: 300)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            if let error {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                Button { Pasteboard.copy(request.statements.joined(separator: "\n")) } label: {
                    Label(tr("SQL 복사"), systemImage: "doc.on.doc")
                }
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button(tr("취소")) { app.editApply = nil }
                    .keyboardShortcut(.cancelAction)
                Button(tr("적용")) {
                    working = true
                    error = nil
                    Task {
                        do {
                            try await app.applyEdits(request)
                            app.editApply = nil
                        } catch {
                            self.error = ErrorText.describe(error).message
                        }
                        working = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(working)
            }
        }
        .padding(20)
        .frame(width: 620)
    }
}

/// 행 상세를 편집기로 쓸 때 필요한 것
struct RowEditor {
    let target: EditTarget
    let edits: PendingEdits
    let set: (Int, String?) -> Void
    let resetToDefault: (Int) -> Void
}
