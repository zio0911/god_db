import GodDBCore
import SwiftUI

/// 테이블 수정 화면 (DataGrip Modify 와 비슷한 구성)
/// 왼쪽: 테이블 > 컬럼 / 키 / 인덱스 / 외래 키 트리, 오른쪽: 고른 항목의 속성, 아래: ALTER 미리보기.
struct TableEditorView: View {
    @Environment(AppState.self) private var app
    let table: TableMeta

    enum Node: Hashable {
        case table
        case column(UUID)
        case index(UUID)
        case foreignKey(String)
        case deletedColumn(String)
    }

    @State private var columns: [EditableColumn]
    @State private var indexes: [EditableIndex]
    @State private var comment: String
    @State private var selection: Node? = .table
    @State private var showPreview = true
    @State private var confirming = false
    @State private var executing = false
    @State private var execError: String?
    @State private var columnsOpen = true
    @State private var keysOpen = true
    @State private var indexesOpen = true
    @State private var fksOpen = true

    init(table: TableMeta) {
        self.table = table
        _columns = State(initialValue: table.columns.sorted { $0.position < $1.position }.map(EditableColumn.init))
        _indexes = State(initialValue: table.indexes.map(EditableIndex.init))
        _comment = State(initialValue: table.comment)
    }

    private var kind: DatabaseKind { app.dialect.kind }
    private var readOnly: Bool { app.selectedProfile?.readOnly == true }

    private var preview: Result<String?, Error> {
        Result { try TableAlter.statement(original: table, columns: columns, indexes: indexes, comment: comment,
                                          dialect: app.dialect) }
    }

    private var sqlText: String? {
        if case .success(let sql) = preview { return sql }
        return nil
    }

    /// 기본 키 인덱스 위치
    private var primaryIndex: Int? {
        indexes.firstIndex { e in
            if let n = e.originalName, let o = table.indexes.first(where: { $0.name == n }) { return o.isPrimary }
            return e.name == "PRIMARY" || e.name.hasPrefix("pk_")
        }
    }

    private var deletedColumns: [ColumnMeta] {
        let kept = Set(columns.compactMap(\.originalName))
        return table.columns.filter { !kept.contains($0.name) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    treeToolbar
                    Divider()
                    tree
                }
                .frame(width: 360)
                Divider()
                ScrollView {
                    inspector
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            Divider()
            previewSection
            Divider()
            footer
        }
        .frame(width: 1040, height: 740)
        .alert(tr("이 ALTER 문을 실행할까요?"), isPresented: $confirming) {
            Button(tr("실행"), role: .destructive) { Task { await execute() } }
            Button(tr("취소"), role: .cancel) {}
        } message: {
            Text(tr("%@ / %@ 에서 바로 실행돼요. 컬럼 삭제는 되돌릴 수 없어요.", "\(app.selectedProfile?.name ?? "")", "\(app.currentDatabase)"))
        }
    }

    // MARK: - 트리

    private var treeToolbar: some View {
        HStack(spacing: 4) {
            Menu {
                Button(tr("컬럼 추가")) { addColumn() }
                Button(tr("인덱스 추가")) { addIndex() }
            } label: { Image(systemName: "plus") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help(tr("컬럼 / 인덱스 추가"))
            Button { removeSelected() } label: { Image(systemName: "minus") }
                .disabled(!canRemove)
                .help(tr("고른 컬럼 / 인덱스 삭제"))
            Button { duplicateSelected() } label: { Image(systemName: "plus.square.on.square") }
                .disabled(!isColumnSelected)
                .help(tr("컬럼 복제"))
            Button { moveSelected(-1) } label: { Image(systemName: "arrow.up") }
                .disabled(!canMove(-1))
                .help(tr("위로"))
            Button { moveSelected(1) } label: { Image(systemName: "arrow.down") }
                .disabled(!canMove(1))
                .help(tr("아래로"))
            Spacer()
            Text(changeSummary).font(.caption).foregroundStyle(.secondary)
        }
        .buttonStyle(.hover)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private var changeSummary: String {
        guard let list = try? TableAlter.changes(original: table, columns: columns, indexes: indexes, comment: comment),
              !list.isEmpty else { return tr("변경 없음") }
        return tr("변경 %@건", "\(list.count)")
    }

    private var tree: some View {
        List(selection: $selection) {
            HStack(spacing: 6) {
                Image(systemName: "tablecells").foregroundStyle(Color.accentColor)
                Text(table.name).fontWeight(.semibold)
                Text("\(app.currentDatabase) [\(app.selectedProfile?.name ?? "")]").font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1)
                if comment != table.comment { changeDot(.orange) }
            }
            .tag(Node.table)

            DisclosureGroup(isExpanded: $columnsOpen) {
                ForEach(columns) { c in
                    HStack(spacing: 5) {
                        Image(systemName: isPK(c.name) ? "key.fill" : (isFK(c.name) ? "link" : "rectangle.split.1x2"))
                            .foregroundStyle(isPK(c.name) ? Color.yellow : (isFK(c.name) ? Color.accentColor : Color.secondary))
                            .frame(width: 16)
                        Text(c.name.isEmpty ? tr("(이름 없음)") : c.name)
                        Text(c.columnType + (ColumnExtraParts(c.extra, kind: kind).autoIncrement ? " (auto increment)" : ""))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 0)
                        status(for: c)
                    }
                    .tag(Node.column(c.id))
                }
                ForEach(deletedColumns) { c in
                    HStack(spacing: 5) {
                        Image(systemName: "rectangle.split.1x2").foregroundStyle(.red).frame(width: 16)
                        Text(c.name).strikethrough().foregroundStyle(.red)
                        Text(tr("삭제 예정")).font(.caption).foregroundStyle(.red)
                    }
                    .tag(Node.deletedColumn(c.name))
                }
            } label: {
                folder("columns", count: columns.count)
            }

            DisclosureGroup(isExpanded: $keysOpen) {
                if let i = primaryIndex {
                    HStack(spacing: 5) {
                        Image(systemName: "key.fill").foregroundStyle(.yellow).frame(width: 16)
                        Text(indexes[i].name)
                        Text("(\(indexes[i].columns.joined(separator: ", ")))").font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(Node.index(indexes[i].id))
                }
            } label: {
                folder("keys", count: primaryIndex == nil ? 0 : 1)
            }

            DisclosureGroup(isExpanded: $indexesOpen) {
                ForEach(indexes) { idx in
                    HStack(spacing: 5) {
                        Image(systemName: "list.number").foregroundStyle(.teal).frame(width: 16)
                        Text(idx.name)
                        Text("(\(idx.columns.joined(separator: ", ")))" + (idx.unique ? " UNIQUE" : ""))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 0)
                        indexStatus(idx)
                    }
                    .tag(Node.index(idx.id))
                }
            } label: {
                folder("indexes", count: indexes.count)
            }

            DisclosureGroup(isExpanded: $fksOpen) {
                ForEach(table.foreignKeys) { fk in
                    HStack(spacing: 5) {
                        Image(systemName: "link").foregroundStyle(Color.accentColor).frame(width: 16)
                        Text(fk.name)
                        Text("(\(fk.columns.joined(separator: ", "))) → \(fk.referencedTable)")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .tag(Node.foreignKey(fk.name))
                }
            } label: {
                folder("foreign keys", count: table.foreignKeys.count)
            }
        }
        .listStyle(.sidebar)
    }

    private func folder(_ title: String, count: Int) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "folder").foregroundStyle(Color.accentColor)
            Text(title)
            if count > 0 { Text("\(count)").font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func changeDot(_ color: Color) -> some View {
        Circle().fill(color).frame(width: 7, height: 7)
    }

    @ViewBuilder
    private func status(for c: EditableColumn) -> some View {
        if c.originalName == nil {
            Text(tr("새")).font(.caption2.weight(.semibold)).foregroundStyle(.green)
        } else if let o = table.columns.first(where: { $0.name == c.originalName }),
                  o.name != c.name || !SchemaDiff.columnDifferences(c.metaForCompare, o).isEmpty {
            changeDot(.orange)
        }
    }

    @ViewBuilder
    private func indexStatus(_ e: EditableIndex) -> some View {
        if e.originalName == nil {
            Text(tr("새")).font(.caption2.weight(.semibold)).foregroundStyle(.green)
        } else if let o = table.indexes.first(where: { $0.name == e.originalName }),
                  o.name != e.name || o.unique != e.unique || o.columns != e.columns {
            changeDot(.orange)
        }
    }

    private func isPK(_ name: String) -> Bool {
        primaryIndex.map { indexes[$0].columns.contains { $0.lowercased() == name.lowercased() } } ?? false
    }

    private func isFK(_ name: String) -> Bool {
        table.foreignKeys.contains { $0.columns.contains { $0.lowercased() == name.lowercased() } }
    }

    // MARK: - 속성 (오른쪽)

    @ViewBuilder
    private var inspector: some View {
        switch selection {
        case .column(let id):
            if let i = columns.firstIndex(where: { $0.id == id }) { columnForm(i) } else { tableForm }
        case .index(let id):
            if let i = indexes.firstIndex(where: { $0.id == id }) { indexForm(i) } else { tableForm }
        case .foreignKey(let name):
            if let fk = table.foreignKeys.first(where: { $0.name == name }) { fkForm(fk) } else { tableForm }
        case .deletedColumn(let name):
            VStack(alignment: .leading, spacing: 12) {
                Label(tr("%@ 컬럼을 삭제할 예정이에요.", name), systemImage: "trash").foregroundStyle(.red)
                Button(tr("삭제 취소 (되살리기)")) { restore(name) }
            }
        case .table, nil:
            tableForm
        }
    }

    private func header(_ icon: String, _ title: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
            Text(title).font(.system(.title3, design: .monospaced))
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
    }

    private var tableForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            header("tablecells", table.name)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
                GridRow {
                    Text(tr("이름")).foregroundStyle(.secondary)
                    Text(table.name).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                }
                GridRow {
                    Text(tr("코멘트")).foregroundStyle(.secondary)
                    TextField(tr("테이블 코멘트"), text: $comment, axis: .vertical)
                        .lineLimit(2...6)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text(tr("요약")).foregroundStyle(.secondary)
                    Text(tr("컬럼 %@ · 인덱스 %@ · 외래 키 %@", "\(columns.count)", "\(indexes.count)", "\(table.foreignKeys.count)"))
                        .foregroundStyle(.secondary)
                }
            }
            Text(tr("테이블 이름 변경은 사이드바에서 테이블 우클릭 > 이름 바꾸기를 쓰세요."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func columnForm(_ i: Int) -> some View {
        let col = $columns[i]
        let extra = Binding<ColumnExtraParts>(
            get: { ColumnExtraParts(columns[i].extra, kind: kind) },
            set: { columns[i].extra = $0.compose(kind: kind) })
        return VStack(alignment: .leading, spacing: 14) {
            header("rectangle.split.1x2", columns[i].name.isEmpty ? tr("(이름 없음)") : columns[i].name)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
                GridRow {
                    Text(tr("이름")).foregroundStyle(.secondary)
                    TextField(tr("이름"), text: col.name).textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }
                GridRow {
                    Text(tr("코멘트")).foregroundStyle(.secondary)
                    TextField("", text: col.comment, axis: .vertical).lineLimit(1...4).textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text(tr("데이터 타입")).foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        TextField(tr("타입"), text: col.columnType).textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                        Menu {
                            ForEach(DataModel.commonTypes(kind), id: \.self) { t in Button(t) { columns[i].columnType = t } }
                        } label: { Image(systemName: "chevron.down") }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    }
                }
                GridRow {
                    Text("")
                    HStack(spacing: 24) {
                        Toggle("Not Null", isOn: Binding(get: { !columns[i].nullable }, set: { columns[i].nullable = !$0 }))
                        Toggle("Auto Increment", isOn: extra.autoIncrement)
                        Toggle(tr("기본 키"), isOn: Binding(get: { isPK(columns[i].name) }, set: { setPK(columns[i].name, $0) }))
                    }
                    .toggleStyle(.checkbox)
                }
                GridRow {
                    Text(tr("기본값")).foregroundStyle(.secondary)
                    TextField(kind == .mysql ? tr("없음") : tr("없음 (SQL 식)"), text: Binding(
                        get: { columns[i].defaultValue ?? "" },
                        set: { columns[i].defaultValue = $0.isEmpty ? nil : $0 }))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }
                if kind == .mysql {
                    GridRow {
                        Text("On Update").foregroundStyle(.secondary)
                        TextField("CURRENT_TIMESTAMP", text: extra.onUpdate).textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                    }
                    GridRow {
                        Text(tr("기타 Extra")).foregroundStyle(.secondary)
                        TextField("", text: extra.rest).textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                    }
                }
            }
            if let o = columns[i].originalName, o != columns[i].name {
                Label(tr("원래 이름: %@ (이름 변경)", o), systemImage: "pencil").font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private func indexForm(_ i: Int) -> some View {
        let isPrimary = i == primaryIndex
        return VStack(alignment: .leading, spacing: 14) {
            header(isPrimary ? "key.fill" : "list.number", indexes[i].name)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
                GridRow {
                    Text(tr("이름")).foregroundStyle(.secondary)
                    TextField(tr("이름"), text: $indexes[i].name).textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .disabled(isPrimary)
                }
                GridRow {
                    Text("")
                    Toggle("UNIQUE", isOn: $indexes[i].unique).toggleStyle(.checkbox).disabled(isPrimary)
                }
                GridRow(alignment: .top) {
                    Text(tr("컬럼")).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(indexes[i].columns.enumerated()), id: \.offset) { k, name in
                            HStack {
                                Text("\(k + 1).").foregroundStyle(.secondary).frame(width: 22, alignment: .trailing)
                                Text(name).font(.system(.body, design: .monospaced))
                                Spacer()
                                Button { indexes[i].columns.swapAt(k, k - 1) } label: { Image(systemName: "arrow.up") }
                                    .disabled(k == 0)
                                Button { indexes[i].columns.remove(at: k) } label: { Image(systemName: "minus.circle") }
                            }
                            .buttonStyle(.borderless)
                        }
                        Menu(tr("컬럼 추가")) {
                            ForEach(columns.filter { c in !indexes[i].columns.contains(c.name) }) { c in
                                Button(c.name) { indexes[i].columns.append(c.name) }
                            }
                        }
                        .fixedSize()
                    }
                }
            }
        }
    }

    private func fkForm(_ fk: ForeignKeyMeta) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            header("link", fk.name)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                GridRow {
                    Text(tr("컬럼")).foregroundStyle(.secondary)
                    Text(fk.columns.joined(separator: ", ")).font(.system(.body, design: .monospaced))
                }
                GridRow {
                    Text(tr("참조")).foregroundStyle(.secondary)
                    Text("\(fk.referencedTable) (\(fk.referencedColumns.joined(separator: ", ")))").font(.system(.body, design: .monospaced))
                }
            }
            Text(tr("외래 키는 여기서 보기만 할 수 있어요. 바꾸려면 쿼리 탭에서 ALTER 문을 실행하세요."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - 편집 동작

    private var isColumnSelected: Bool { if case .column = selection { return true } else { return false } }

    private var canRemove: Bool {
        switch selection {
        case .column: return columns.count > 1
        case .index: return true
        default: return false
        }
    }

    private func canMove(_ by: Int) -> Bool {
        guard case .column(let id) = selection, let i = columns.firstIndex(where: { $0.id == id }) else { return false }
        return columns.indices.contains(i + by)
    }

    private func addColumn() {
        var n = 1
        while columns.contains(where: { $0.name == "new_column" + (n == 1 ? "" : "\(n)") }) { n += 1 }
        let c = EditableColumn(name: "new_column" + (n == 1 ? "" : "\(n)"))
        if case .column(let id) = selection, let i = columns.firstIndex(where: { $0.id == id }) {
            columns.insert(c, at: i + 1)
        } else {
            columns.append(c)
        }
        selection = .column(c.id)
    }

    private func addIndex() {
        var cols: [String] = []
        if case .column(let id) = selection, let c = columns.first(where: { $0.id == id }) { cols = [c.name] }
        let idx = EditableIndex(name: "idx_\(table.name)_\(cols.first ?? "")", columns: cols)
        indexes.append(idx)
        selection = .index(idx.id)
    }

    private func removeSelected() {
        switch selection {
        case .column(let id):
            guard let i = columns.firstIndex(where: { $0.id == id }) else { return }
            let name = columns[i].name
            columns.remove(at: i)
            for k in indexes.indices { indexes[k].columns.removeAll { $0 == name } }
            indexes.removeAll { $0.columns.isEmpty }
            selection = columns.indices.contains(i) ? .column(columns[i].id) : columns.last.map { .column($0.id) }
        case .index(let id):
            indexes.removeAll { $0.id == id }
            selection = .table
        default: break
        }
    }

    private func duplicateSelected() {
        guard case .column(let id) = selection, let i = columns.firstIndex(where: { $0.id == id }) else { return }
        let o = columns[i]
        let c = EditableColumn(name: o.name + "_copy", columnType: o.columnType, nullable: o.nullable, defaultValue: o.defaultValue,
                               extra: ColumnExtraParts(o.extra, kind: kind).autoIncrement ? "" : o.extra, comment: o.comment)
        columns.insert(c, at: i + 1)
        selection = .column(c.id)
    }

    private func moveSelected(_ by: Int) {
        guard case .column(let id) = selection, let i = columns.firstIndex(where: { $0.id == id }),
              columns.indices.contains(i + by) else { return }
        columns.swapAt(i, i + by)
    }

    private func restore(_ name: String) {
        guard let o = table.columns.first(where: { $0.name == name }) else { return }
        let c = EditableColumn(o)
        let pos = table.columns.sorted { $0.position < $1.position }.firstIndex { $0.name == name } ?? columns.count
        columns.insert(c, at: min(pos, columns.count))
        selection = .column(c.id)
    }

    private func setPK(_ name: String, _ on: Bool) {
        if let p = primaryIndex {
            if on {
                if !indexes[p].columns.contains(name) { indexes[p].columns.append(name) }
            } else {
                indexes[p].columns.removeAll { $0 == name }
            }
            if indexes[p].columns.isEmpty { indexes.remove(at: p) }
        } else if on {
            let pkName = kind == .mysql ? "PRIMARY" : "pk_\(table.name)"
            indexes.insert(EditableIndex(name: pkName, unique: true, columns: [name]), at: 0)
        }
        if on, let i = columns.firstIndex(where: { $0.name == name }) { columns[i].nullable = false }
    }

    // MARK: - 미리보기 / 아래

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button { withAnimation(.easeInOut(duration: 0.15)) { showPreview.toggle() } } label: {
                    Label(tr("미리보기"), systemImage: showPreview ? "chevron.down" : "chevron.right").font(.headline)
                }
                .buttonStyle(.plain)
                Spacer()
                if let sql = sqlText {
                    CopyButton(title: tr("복사")) { sql }
                    Image(systemName: "checkmark").foregroundStyle(.green)
                } else if case .failure = preview {
                    Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                }
            }
            if showPreview {
                ScrollView {
                    Group {
                        switch preview {
                        case .success(let sql?): Text(sql).foregroundStyle(.primary)
                        case .success(nil): Text(tr("-- 변경 사항이 없어요.")).foregroundStyle(.secondary)
                        case .failure(let error): Text("-- \(error.localizedDescription)").foregroundStyle(.red)
                        }
                    }
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }
                .frame(height: 150)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            }
            if let execError {
                Text(execError).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .padding(12)
    }

    private var footer: some View {
        HStack {
            if readOnly {
                Label(tr("읽기전용 접속이라 실행할 수 없어요. SQL을 복사해서 사용하세요."), systemImage: "lock")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button(tr("취소")) { app.alteringTable = nil }
                .keyboardShortcut(.cancelAction)
            Button(tr("쿼리 탭으로 열기")) {
                if let sql = sqlText {
                    app.addTab(text: sql, title: "ALTER · \(table.name)")
                    app.alteringTable = nil
                }
            }
            .disabled(sqlText == nil)
            Button(tr("실행…")) { confirming = true }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(sqlText == nil || readOnly || executing)
        }
        .padding(12)
    }

    private func execute() async {
        guard let sql = sqlText else { return }
        executing = true
        execError = nil
        defer { executing = false }
        do {
            try await app.executeAlter(sql, table: table.name)
            app.alteringTable = nil
        } catch {
            execError = ErrorText.describe(error).message
        }
    }
}
