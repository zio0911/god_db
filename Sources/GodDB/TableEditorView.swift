import GodDBCore
import SwiftUI

/// 테이블 수정 화면. 컬럼/인덱스/코멘트를 고치면 ALTER TABLE 문을 미리 보여주고, 확인 후 실행한다.
struct TableEditorView: View {
    @Environment(AppState.self) private var app
    let table: TableMeta

    @State private var columns: [EditableColumn]
    @State private var indexes: [EditableIndex]
    @State private var comment: String
    @State private var confirming = false
    @State private var executing = false
    @State private var execError: String?

    init(table: TableMeta) {
        self.table = table
        _columns = State(initialValue: table.columns.sorted { $0.position < $1.position }.map(EditableColumn.init))
        _indexes = State(initialValue: table.indexes.map(EditableIndex.init))
        _comment = State(initialValue: table.comment)
    }

    private var preview: Result<String?, Error> {
        Result { try TableAlter.statement(original: table, columns: columns, indexes: indexes, comment: comment,
                                          dialect: app.dialect) }
    }

    private var readOnly: Bool { app.selectedProfile?.readOnly == true }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "tablecells")
                Text("테이블 수정 · \(table.name)").font(.headline)
                Spacer()
                Text("코멘트").foregroundStyle(.secondary)
                TextField("테이블 코멘트", text: $comment).frame(width: 260)
            }
            .padding(12)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    columnSection
                    indexSection
                }
                .padding(12)
            }

            Divider()
            previewSection
            Divider()

            HStack {
                if readOnly {
                    Label("읽기전용 접속이라 실행할 수 없어요. SQL을 복사해서 사용하세요.", systemImage: "lock")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("취소") { app.alteringTable = nil }
                    .keyboardShortcut(.cancelAction)
                Button("쿼리 탭으로 열기") {
                    if case .success(let sql?) = preview {
                        app.addTab(text: sql, title: "ALTER · \(table.name)")
                        app.alteringTable = nil
                    }
                }
                .disabled(sqlText == nil)
                Button("실행…") { confirming = true }
                    .keyboardShortcut(.defaultAction)
                    .disabled(sqlText == nil || readOnly || executing)
            }
            .padding(12)
        }
        .frame(width: 980, height: 680)
        .alert("이 ALTER 문을 실행할까요?", isPresented: $confirming) {
            Button("실행", role: .destructive) { Task { await execute() } }
            Button("취소", role: .cancel) {}
        } message: {
            Text("\(app.selectedProfile?.name ?? "") / \(app.currentDatabase) 에서 바로 실행돼요. 컬럼 삭제는 되돌릴 수 없어요.")
        }
    }

    private var sqlText: String? {
        if case .success(let sql) = preview { return sql }
        return nil
    }

    // MARK: - 컬럼

    private var columnSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("컬럼").font(.headline)
                Spacer()
                Button {
                    columns.append(EditableColumn(name: "new_column"))
                } label: { Label("컬럼 추가", systemImage: "plus") }
            }
            HStack(spacing: 6) {
                Text("").frame(width: 44)
                Text("이름").frame(width: 150, alignment: .leading)
                Text("타입").frame(width: 130, alignment: .leading)
                Text("NULL").frame(width: 40)
                Text("기본값").frame(width: 120, alignment: .leading)
                Text("Extra").frame(width: 120, alignment: .leading)
                Text("코멘트").frame(maxWidth: .infinity, alignment: .leading)
                Text("").frame(width: 24)
            }
            .font(.caption).foregroundStyle(.secondary)

            ForEach($columns) { $col in
                let index = columns.firstIndex { $0.id == col.id } ?? 0
                HStack(spacing: 6) {
                    HStack(spacing: 2) {
                        Button { move(index, by: -1) } label: { Image(systemName: "chevron.up") }
                            .disabled(index == 0)
                        Button { move(index, by: 1) } label: { Image(systemName: "chevron.down") }
                            .disabled(index == columns.count - 1)
                    }
                    .buttonStyle(.borderless)
                    .frame(width: 44)
                    TextField("이름", text: $col.name).frame(width: 150)
                    TextField("타입", text: $col.columnType).frame(width: 130)
                    Toggle("", isOn: $col.nullable).labelsHidden().frame(width: 40)
                    TextField(app.dialect.kind == .mysql ? "없음" : "없음 (SQL 식)", text: Binding(
                        get: { col.defaultValue ?? "" },
                        set: { col.defaultValue = $0.isEmpty ? nil : $0 }
                    )).frame(width: 120)
                    TextField("", text: $col.extra).frame(width: 120)
                    TextField("", text: $col.comment)
                    Button(role: .destructive) {
                        columns.removeAll { $0.id == col.id }
                    } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .frame(width: 24)
                        .help("컬럼 삭제")
                }
                .textFieldStyle(.roundedBorder)
                .font(.system(.callout, design: .monospaced))
                .padding(.vertical, 1)
                .background(rowColor(col), in: RoundedRectangle(cornerRadius: 4))
            }
        }
    }

    private func rowColor(_ c: EditableColumn) -> Color {
        guard let on = c.originalName, let o = table.columns.first(where: { $0.name == on }) else {
            return .green.opacity(0.12)   // 새 컬럼
        }
        let changed = on != c.name || o.columnType != c.columnType || o.nullable != c.nullable
            || o.defaultValue != c.defaultValue || o.extra != c.extra || o.comment != c.comment
        return changed ? .orange.opacity(0.12) : .clear
    }

    private func move(_ index: Int, by offset: Int) {
        let target = index + offset
        guard columns.indices.contains(target) else { return }
        columns.swapAt(index, target)
    }

    // MARK: - 인덱스

    private var indexSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("인덱스").font(.headline)
                Spacer()
                Button {
                    indexes.append(EditableIndex(name: "idx_\(table.name)_", columns: []))
                } label: { Label("인덱스 추가", systemImage: "plus") }
            }
            HStack(spacing: 6) {
                Text("이름").frame(width: 200, alignment: .leading)
                Text("UNIQUE").frame(width: 60)
                Text("컬럼 (쉼표로 구분, 순서대로)").frame(maxWidth: .infinity, alignment: .leading)
                Text("").frame(width: 24)
            }
            .font(.caption).foregroundStyle(.secondary)

            ForEach($indexes) { $idx in
                HStack(spacing: 6) {
                    TextField("이름", text: $idx.name).frame(width: 200)
                        .disabled(idx.name == "PRIMARY")
                    Toggle("", isOn: $idx.unique).labelsHidden().frame(width: 60)
                        .disabled(idx.name == "PRIMARY")
                    TextField("col_a, col_b", text: Binding(
                        get: { idx.columns.joined(separator: ", ") },
                        set: { idx.columns = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
                    ))
                    Button(role: .destructive) {
                        indexes.removeAll { $0.id == idx.id }
                    } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .frame(width: 24)
                        .help("인덱스 삭제")
                }
                .textFieldStyle(.roundedBorder)
                .font(.system(.callout, design: .monospaced))
            }
        }
    }

    // MARK: - 미리보기

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("미리보기 SQL").font(.headline)
                Spacer()
                if let sql = sqlText {
                    Button { Pasteboard.copy(sql) } label: { Label("복사", systemImage: "doc.on.doc") }
                        .buttonStyle(.borderless)
                }
            }
            ScrollView {
                Group {
                    switch preview {
                    case .success(let sql?):
                        Text(sql).foregroundStyle(.primary)
                    case .success(nil):
                        Text("-- 변경 사항이 없어요.").foregroundStyle(.secondary)
                    case .failure(let error):
                        Text("-- \(error.localizedDescription)").foregroundStyle(.red)
                    }
                }
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            .frame(height: 130)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            if let execError {
                Text(execError).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
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
