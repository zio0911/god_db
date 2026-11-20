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
    /// JSON 칸인데 JSON 이 깨진 컬럼 (경고만, 저장은 가능)
    var invalidJSONColumns: [String] = []
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
        if result.truncatedCells > 0 { return .failure(ResultEditingError.valuesTruncated) }
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
        editApply = EditApplyRequest(tabID: tabID, statements: statements,
                                     invalidJSONColumns: JSONView.invalidEdits(tab.edits, target: target,
                                                                               columns: result.columns.map(\.name), rows: result.rows))
    }

    /// 트랜잭션으로 적용하고, 성공하면 같은 페이지를 다시 읽는다.
    func applyEdits(_ request: EditApplyRequest) async throws {
        guard let tab = tabs.first(where: { $0.id == request.tabID }),
              let session = connections[tab.profileID]?.session else { throw DBError.notConnected }
        if !tab.database.isEmpty, await session.current != tab.database { try await session.use(tab.database) }
        do {
            try await session.executeInTransaction(request.statements)
        } catch {
            logError(error, .query, context: tr("데이터 변경 실패 (모두 되돌림)"), sql: request.statements.joined(separator: "\n"),
                     audit: AuditRecord(AuditRecord.classify(sql: request.statements[0]), target: auditTarget(tab),
                                        statement: request.statements.joined(separator: " ; ")))
            throw error
        }
        log(.success, .query, tr("데이터 변경 %@건 적용", "\(request.statements.count)"),
            detail: request.statements.joined(separator: "\n"))
        // 감사 로그: 문장마다 한 줄 (추가/수정/삭제 구분)
        for (n, st) in request.statements.enumerated() {
            LogFile.shared.append(LogEntry(level: .success, source: .query, message: "",
                audit: AuditRecord(AuditRecord.classify(sql: st), target: auditTarget(tab),
                                   result: "결과 편집 \(n + 1)/\(request.statements.count) (한 트랜잭션)", statement: st)))
        }
        await refreshTx(tab.profileID)
        revertEdits(request.tabID)
        if tab.result?.appendMode == true, let sql = tab.result?.sql {
            // 이어 붙인 결과는 처음부터 다시 읽는다
            selectTab(request.tabID)
            await run(sql: sql)
        } else if let page = tab.result?.page, tab.result?.isPaged == true {
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
                Text(tr("%@ 편집 가능 · 칸을 더블클릭해 바로 고치거나, 행을 고르면 오른쪽에서 고쳐요", t.table.name))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button {
                    InlineCellTextField.endActiveEditing()
                    if let id = app.addRow(tab.id) { selection = [id] }
                } label: { Label(tr("행 추가"), systemImage: "plus") }
                Button {
                    InlineCellTextField.endActiveEditing()
                    app.toggleDelete(tab.id, rows: selection)
                } label: { Label(tr("선택 행 삭제"), systemImage: "minus") }
                    .disabled(selection.isEmpty)
                    .help(tr("한 번 더 누르면 삭제 표시를 풀어요"))
                if !tab.edits.isEmpty {
                    Divider().frame(height: 14)
                    Text(tr("변경 %@건", "\(tab.edits.count)"))
                        .font(.caption.weight(.semibold)).foregroundStyle(.orange)
                    Button(tr("되돌리기")) {
                        InlineCellTextField.endActiveEditing()
                        app.revertEdits(tab.id)
                    }
                    Button {
                        InlineCellTextField.endActiveEditing()
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
            if let tab, app.profile(tab.profileID)?.environment == .production {
                Label(tr("운영 접속이에요. 적용하면 운영 데이터가 바뀌어요."), systemImage: "exclamationmark.triangle.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.red)
            }
            if !request.invalidJSONColumns.isEmpty {
                Label(tr("JSON 형식이 아니에요: %@", request.invalidJSONColumns.joined(separator: ", ")),
                      systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
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

/// 결과 표에서 고르고 있는 칸 (행 id, 컬럼 번호)
struct GridCell: Hashable {
    let row: Int
    let column: Int
}

/// 마우스가 올라간 칸. 더블클릭 · 우클릭이 어느 칸인지 알기 위해 쓰며, 바뀌어도 화면을 다시 그리지 않는다.
final class PointerCell {
    var cell: GridCell?

    /// 지금 처리 중인 마우스 이벤트가 표의 몇 번째 컬럼(화면 순서)에 떨어졌는지와 그 머리글.
    /// 마우스를 움직이지 않고 누르면(결과가 새로 그려진 뒤 등) hover 가 오지 않으므로 이벤트 위치로 직접 찾는다.
    /// 마지막으로 누른 마우스 (창 · 창 안 위치). 더블클릭 처리 시점에는 현재 이벤트가 마우스가 아닐 수 있어 따로 기억한다
    private static var lastDown: (window: NSWindow, point: NSPoint)?
    private static var monitor: Any?

    /// 지금 보이는 결과 표 (더블클릭을 받을 곳)
    nonisolated(unsafe) static weak var active: PointerCell?
    /// 더블클릭한 칸 (표의 행 번호 · 컬럼 번호 · 머리글). 받으면 doubleClicked 가 불린다
    var pendingDouble: (row: Int, column: Int, title: String)?
    var doubleClicked: (() -> Void)?

    /// 결과 표가 처음 나올 때 한 번 건다 (앱 안 마우스 누름만 본다, 이벤트는 그대로 통과).
    /// 표(NSTableView)는 두 번째 클릭을 칸 안의 SwiftUI 동작에 넘기지 않아서, 더블클릭은 여기서 위치로 칸을 찾는다
    static func startTracking() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { ev in
            if let w = ev.window { lastDown = (w, ev.locationInWindow) }
            if ev.type == .leftMouseDown, ev.clickCount == 2, ev.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty,
               let w = ev.window, let table = tableView(in: w, at: ev.locationInWindow) {
                let p = table.convert(ev.locationInWindow, from: nil)
                let r = table.row(at: p), c = table.column(at: p)
                if r >= 0, c >= 0, c < table.tableColumns.count, let target = active {
                    target.pendingDouble = (r, c, table.tableColumns[c].title)
                    DispatchQueue.main.async { target.doubleClicked?() }
                }
            }
            return ev
        }
    }

    private static func tableView(in window: NSWindow, at point: NSPoint) -> NSTableView? {
        guard var view = window.contentView?.hitTest(point) else { return nil }
        while !(view is NSTableView) {
            guard let parent = view.superview else { return nil }
            view = parent
        }
        return view as? NSTableView
    }

    static func clickedColumn() -> (index: Int, title: String)? {
        let ev = NSApp.currentEvent
        let fromEvent = ev.flatMap { e -> (NSWindow, NSPoint)? in
            guard let w = e.window, [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp].contains(e.type) else { return nil }
            return (w, e.locationInWindow)
        }
        guard let (window, point) = fromEvent ?? lastDown.map({ ($0.window, $0.point) }),
              var view = window.contentView?.hitTest(point) else { return nil }
        while !(view is NSTableView) {
            guard let parent = view.superview else { return nil }
            view = parent
        }
        guard let table = view as? NSTableView else { return nil }
        let index = table.column(at: table.convert(point, from: nil))
        guard index >= 0, index < table.tableColumns.count else { return nil }
        return (index, table.tableColumns[index].title)
    }
}

/// 결과 표 칸 하나를 그 자리에서 고치는 한 줄 입력란 (고치는 칸에만 하나 만든다)
/// ↩ 넣기 · Esc 취소 · Tab/⇧Tab 넣고 옆 칸 · 다른 곳 클릭 넣기
struct InlineCellEditor: NSViewRepresentable {
    let initial: String
    /// (입력한 글자, 끝낸 방법, 키보드로 끝냈는지)
    let onFinish: (String, InlineCellEdit.Finish, Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeNSView(context: Context) -> InlineCellTextField {
        let field = InlineCellTextField(string: initial)
        field.font = .monospacedSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .callout).pointSize, weight: .regular)
        field.isBordered = false
        field.drawsBackground = true
        field.backgroundColor = .textBackgroundColor
        field.focusRingType = .exterior
        field.usesSingleLineMode = true
        field.lineBreakMode = .byClipping
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = context.coordinator
        field.setAccessibilityLabel(tr("칸 편집"))
        return field
    }

    func updateNSView(_ field: InlineCellTextField, context: Context) {
        context.coordinator.onFinish = onFinish
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var onFinish: (String, InlineCellEdit.Finish, Bool) -> Void
        private var finished = false

        init(onFinish: @escaping (String, InlineCellEdit.Finish, Bool) -> Void) { self.onFinish = onFinish }

        private func finish(_ text: String, _ how: InlineCellEdit.Finish, keyboard: Bool) {
            guard !finished else { return }
            finished = true
            onFinish(text, how, keyboard)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            let how: InlineCellEdit.Finish
            switch selector {
            case #selector(NSResponder.insertNewline(_:)): how = .commit
            case #selector(NSResponder.cancelOperation(_:)): how = .cancel
            case #selector(NSResponder.insertTab(_:)): how = .next
            case #selector(NSResponder.insertBacktab(_:)): how = .previous
            default: return false
            }
            let table = sequence(first: control.superview, next: { $0?.superview }).lazy.compactMap { $0 as? NSTableView }.first
            finish(textView.string, how, keyboard: true)
            // ↩ · Esc 로 끝내면 키보드 포커스를 표로 돌린다 (화살표 · ⌘C 가 이어지게)
            if how == .commit || how == .cancel, let table {
                DispatchQueue.main.async {
                    guard let window = table.window, !(window.firstResponder is NSTextView) else { return }
                    window.makeFirstResponder(table)
                }
            }
            return true
        }

        /// 다른 곳을 눌러 포커스가 빠지면 넣는다
        func controlTextDidEndEditing(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            finish(field.stringValue, .commit, keyboard: false)
        }
    }
}

final class InlineCellTextField: NSTextField {
    private var focusOnAttach = true

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard focusOnAttach, window != nil else { return }
        focusOnAttach = false
        // 표에 붙은 뒤 포커스 (첫 응답자가 되면 글자 전체가 선택된다)
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
        }
    }

    /// 칸을 고치는 중이면 지금 값을 넣고 끝낸다 (적용 · 되돌리기 · 페이지 이동 등 버튼은 포커스를 가져가지 않으므로)
    @MainActor
    static func endActiveEditing() {
        guard let window = NSApp.keyWindow, let editor = window.firstResponder as? NSTextView,
              (editor.delegate as? NSObject) is InlineCellTextField else { return }
        window.makeFirstResponder(nil)
    }
}
