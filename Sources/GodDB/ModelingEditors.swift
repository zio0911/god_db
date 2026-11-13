import AppKit
import GodDBCore
import SwiftUI

// MARK: - 테이블 편집기 (다이어그램 아래)

struct ModelTableEditor: View {
    @Environment(AppState.self) private var app
    @Binding var model: DataModel
    let tableIndex: Int
    @Binding var selection: ModelSelection?
    let onDelete: () -> Void
    @State private var tab = 0
    @State private var selectedColumn: UUID?

    private var table: ModelTable { model.tables[tableIndex] }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "tablecells").foregroundStyle(Color.accentColor)
                TextField(tr("논리명"), text: $model.tables[tableIndex].logicalName)
                    .textFieldStyle(.roundedBorder).frame(width: 180)
                    .help(tr("논리명 (업무 이름, 예: 회원)"))
                TextField(tr("물리명"), text: $model.tables[tableIndex].physicalName)
                    .textFieldStyle(.roundedBorder).frame(width: 180)
                    .font(.system(.body, design: .monospaced))
                    .help(tr("물리명 (실제 테이블 이름, 예: tb_member)"))
                Picker("", selection: $tab) {
                    Text(tr("컬럼 %@", "\(table.columns.count)")).tag(0)
                    Text(tr("인덱스 %@", "\(table.indexes.count)")).tag(1)
                    Text(tr("관계 %@", "\(model.relations.filter { $0.child == table.id || $0.parent == table.id }.count)")).tag(2)
                    Text(tr("설명")).tag(3)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                Spacer()
                Menu {
                    ForEach(["blue", "purple", "green", "orange", "red", "teal", "gray"], id: \.self) { c in
                        Button(c) { model.tables[tableIndex].color = c == "blue" ? nil : c }
                    }
                } label: {
                    Circle().fill(ModelTableCard.colors[table.color ?? ""] ?? .accentColor).frame(width: 12, height: 12)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help(tr("카드 색"))
                Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
                    .buttonStyle(.hover)
                    .help(tr("테이블 삭제"))
                Button { selection = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.hover)
                    .help(tr("닫기"))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            switch tab {
            case 0: columnsGrid
            case 1: indexList
            case 2: relationList
            default:
                VStack(alignment: .leading, spacing: 6) {
                    Text(tr("테이블 설명 (DB 코멘트에 논리명 다음 줄로 들어가요)")).font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $model.tables[tableIndex].comment)
                        .font(.body)
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.15)))
                }
                .padding(12)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: 컬럼

    private var columnsGrid: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("").frame(width: 40)
                Text(tr("논리명")).frame(width: 140, alignment: .leading)
                Text(tr("물리명")).frame(width: 140, alignment: .leading)
                Text(tr("타입")).frame(width: 150, alignment: .leading)
                Text("PK").frame(width: 26)
                Text("NN").frame(width: 26)
                Text("AI").frame(width: 26)
                Text("UQ").frame(width: 26)
                Text(tr("기본값")).frame(width: 110, alignment: .leading)
                Text(tr("설명")).frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    model.tables[tableIndex].columns.append(ModelColumn(logicalName: tr("새 컬럼")))
                } label: { Label(tr("컬럼 추가"), systemImage: "plus") }
                    .buttonStyle(.hover)
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, 12).padding(.vertical, 4)
            Divider()
            ScrollView {
                VStack(spacing: 2) {
                    ForEach($model.tables[tableIndex].columns) { $c in
                        columnRow($c)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 4)
            }
        }
    }

    private func columnRow(_ c: Binding<ModelColumn>) -> some View {
        let cols = model.tables[tableIndex].columns
        let index = cols.firstIndex { $0.id == c.wrappedValue.id } ?? 0
        let isFK = model.relations.contains { $0.child == table.id && $0.pairs.contains { $0.child == c.wrappedValue.id } }
        return HStack(spacing: 6) {
            HStack(spacing: 0) {
                Button { move(index, -1) } label: { Image(systemName: "chevron.up") }.disabled(index == 0)
                Button { move(index, 1) } label: { Image(systemName: "chevron.down") }.disabled(index == cols.count - 1)
            }
            .buttonStyle(.borderless)
            .frame(width: 40)
            TextField(tr("논리명"), text: c.logicalName).frame(width: 140)
            TextField(tr("물리명"), text: c.physicalName).frame(width: 140)
                .font(.system(.callout, design: .monospaced))
                .overlay(alignment: .trailing) {
                    if c.wrappedValue.physicalName.isEmpty {
                        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange).font(.caption).padding(.trailing, 4)
                    }
                }
            HStack(spacing: 2) {
                TextField(tr("타입"), text: c.dataType).font(.system(.callout, design: .monospaced))
                Menu {
                    ForEach(DataModel.commonTypes(model.kind), id: \.self) { t in Button(t) { c.wrappedValue.dataType = t } }
                } label: { Image(systemName: "chevron.down") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            .frame(width: 150)
            Toggle("", isOn: c.primaryKey).labelsHidden().frame(width: 26)
            Toggle("", isOn: Binding(get: { c.wrappedValue.notNull || c.wrappedValue.primaryKey },
                                     set: { c.wrappedValue.notNull = $0 }))
                .labelsHidden().frame(width: 26).disabled(c.wrappedValue.primaryKey)
            Toggle("", isOn: c.autoIncrement).labelsHidden().frame(width: 26)
            Toggle("", isOn: c.unique).labelsHidden().frame(width: 26).disabled(c.wrappedValue.primaryKey)
            TextField(tr("없음"), text: c.defaultValue).frame(width: 110).font(.system(.callout, design: .monospaced))
            TextField("", text: c.comment)
            Image(systemName: "link").foregroundStyle(Color.accentColor).opacity(isFK ? 1 : 0).frame(width: 14)
                .help(tr("관계로 생긴 FK 컬럼"))
            Button(role: .destructive) {
                let id = c.wrappedValue.id
                app.modeling.checkpoint(model.id)
                model.tables[tableIndex].columns.removeAll { $0.id == id }
                for k in model.tables[tableIndex].indexes.indices { model.tables[tableIndex].indexes[k].columns.removeAll { $0 == id } }
                for r in model.relations.indices { model.relations[r].pairs.removeAll { $0.child == id || $0.parent == id } }
                model.relations.removeAll { $0.pairs.isEmpty }
            } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
                .help(tr("컬럼 삭제"))
        }
        .textFieldStyle(.roundedBorder)
        .font(.callout)
    }

    private func move(_ index: Int, _ by: Int) {
        let t = index + by
        guard model.tables[tableIndex].columns.indices.contains(t) else { return }
        model.tables[tableIndex].columns.swapAt(index, t)
    }

    // MARK: 인덱스

    private var indexList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(tr("PK 와 UQ 표시 컬럼은 자동으로 만들어져요. 여러 컬럼 인덱스를 여기서 추가하세요."))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        model.tables[tableIndex].indexes.append(ModelIndex(name: "idx_\(table.physicalName)_"))
                    } label: { Label(tr("인덱스 추가"), systemImage: "plus") }
                        .buttonStyle(.hover)
                }
                ForEach($model.tables[tableIndex].indexes) { $idx in
                    HStack(alignment: .top, spacing: 8) {
                        TextField(tr("이름"), text: $idx.name).frame(width: 200)
                            .font(.system(.callout, design: .monospaced))
                        Toggle("UNIQUE", isOn: $idx.unique)
                        // 고른 순서대로 컬럼
                        Menu {
                            ForEach(table.columns) { c in
                                Button {
                                    if let k = idx.columns.firstIndex(of: c.id) { idx.columns.remove(at: k) } else { idx.columns.append(c.id) }
                                } label: {
                                    Text((idx.columns.firstIndex(of: c.id).map { "\($0 + 1). " } ?? "") + c.displayName
                                         + (c.physicalName.isEmpty ? "" : " (\(c.physicalName))"))
                                }
                            }
                        } label: {
                            Text(idx.columns.isEmpty ? tr("컬럼 고르기") : idx.columns.compactMap { id in
                                table.columns.first { $0.id == id }?.displayName }.joined(separator: ", "))
                        }
                        .frame(maxWidth: 360)
                        Spacer()
                        Button(role: .destructive) {
                            model.tables[tableIndex].indexes.removeAll { $0.id == idx.id }
                        } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                    }
                    .textFieldStyle(.roundedBorder)
                }
            }
            .padding(12)
        }
    }

    // MARK: 관계

    private var relationList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                let rels = model.relations.filter { $0.child == table.id || $0.parent == table.id }
                if rels.isEmpty {
                    Text(tr("관계가 없어요. 위 도구 막대의 1:N / 1:1 도구로 부모 → 자식 순서로 테이블을 누르세요."))
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(rels) { r in
                    Button { selection = .relation(r.id) } label: {
                        HStack {
                            Image(systemName: r.parent == table.id ? "arrow.right" : "arrow.left")
                            Text("\(model.table(r.parent)?.displayName ?? "?") → \(model.table(r.child)?.displayName ?? "?")")
                            Text(r.cardinality.title + (r.identifying ? tr(" · 식별") : tr(" · 비식별")))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.hover)
                }
            }
            .padding(12)
        }
    }
}

// MARK: - 관계 편집기

struct ModelRelationEditor: View {
    @Environment(AppState.self) private var app
    @Binding var model: DataModel
    let relationID: UUID
    @Binding var selection: ModelSelection?
    @State private var dropColumns = true

    var body: some View {
        if let r = model.relations.first(where: { $0.id == relationID }),
           let parent = model.table(r.parent), let child = model.table(r.child) {
            let set: (ModelRelation) -> Void = { new in model.updateRelation(new) }
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.branch").foregroundStyle(Color.accentColor)
                    Text(tr("관계")).font(.headline)
                    Text(parent.displayName).fontWeight(.semibold)
                    Image(systemName: "arrow.right")
                    Text(child.displayName).fontWeight(.semibold)
                    Spacer()
                    Toggle(tr("FK 컬럼도 삭제"), isOn: $dropColumns).toggleStyle(.checkbox)
                    Button(tr("관계 삭제"), role: .destructive) {
                        app.modeling.checkpoint(model.id)
                        model.removeRelation(r.id, dropColumns: dropColumns)
                        selection = nil
                    }
                    Button { selection = nil } label: { Image(systemName: "xmark") }.buttonStyle(.hover)
                }
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    GridRow {
                        Text(tr("카디널리티"))
                        Picker("", selection: Binding(get: { r.cardinality }, set: { var x = r; x.cardinality = $0; set(x) })) {
                            ForEach(ModelRelation.Cardinality.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                        Toggle(tr("식별 관계 (FK 가 자식 PK 에 포함)"), isOn: Binding(get: { r.identifying },
                                                                            set: { var x = r; x.identifying = $0; set(x) }))
                        Toggle(tr("선택 (자식 FK NULL 허용)"), isOn: Binding(get: { r.optional },
                                                                       set: { var x = r; x.optional = $0; set(x) }))
                            .disabled(r.identifying)
                    }
                    GridRow {
                        Text(tr("FK 이름"))
                        TextField("fk_\(child.physicalName)_\(parent.physicalName)",
                                  text: Binding(get: { r.name }, set: { var x = r; x.name = $0; set(x) }))
                            .textFieldStyle(.roundedBorder).frame(width: 260)
                            .font(.system(.callout, design: .monospaced))
                        Toggle(tr("DB 에 FK 제약 만들기"), isOn: Binding(get: { r.createConstraint },
                                                                    set: { var x = r; x.createConstraint = $0; set(x) }))
                            .help(tr("끄면 다이어그램에만 보이는 논리 관계가 돼요 (운영 DB 처럼 FK 를 안 거는 경우)"))
                    }
                    GridRow {
                        Text("ON DELETE")
                        Picker("", selection: Binding(get: { r.onDelete }, set: { var x = r; x.onDelete = $0; set(x) })) {
                            ForEach(ModelRelation.Action.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden().fixedSize()
                        Text("ON UPDATE")
                        Picker("", selection: Binding(get: { r.onUpdate }, set: { var x = r; x.onUpdate = $0; set(x) })) {
                            ForEach(ModelRelation.Action.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden().fixedSize()
                    }
                }
                Divider()
                Text(tr("컬럼 연결")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(r.pairs, id: \.self) { p in
                    let cc = child.columns.first { $0.id == p.child }
                    let pc = parent.columns.first { $0.id == p.parent }
                    HStack {
                        Text("\(child.displayName).\(cc?.displayName ?? "?")")
                        Text(cc?.physicalName ?? "").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                        Image(systemName: "arrow.right")
                        Text("\(parent.displayName).\(pc?.displayName ?? "?")")
                        Text(pc?.physicalName ?? "").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }
}

// MARK: - SQL 추출 (Forward Engineering)

struct ModelSQLSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    let model: DataModel
    @State private var kind: DatabaseKind
    @State private var dropFirst = false

    init(model: DataModel) {
        self.model = model
        _kind = State(initialValue: model.kind)
    }

    private var result: Result<String, Error> { Result { try model.ddl(kind: kind, dropFirst: dropFirst) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(tr("SQL 추출 · %@", model.name), systemImage: "doc.text").font(.headline)
                Spacer()
                Picker("", selection: $kind) {
                    ForEach([DatabaseKind.mysql, .postgres, .mssql], id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).fixedSize()
                Toggle(tr("DROP 먼저"), isOn: $dropFirst).toggleStyle(.checkbox)
                    .help(tr("기존 테이블을 지우고 다시 만드는 스크립트 (데이터가 사라져요)"))
            }
            ScrollView {
                Group {
                    switch result {
                    case .success(let sql): Text(sql)
                    case .failure(let e): Text("-- " + e.localizedDescription).foregroundStyle(.red)
                    }
                }
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            if case .failure = result {
                Text(tr("도구 막대의 검사 버튼에서 물리명이 빠진 곳을 확인하세요.")).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                if dropFirst {
                    Label(tr("DROP 이 들어 있어요. 운영 DB 에서 실행하지 마세요."), systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red).font(.callout)
                }
                Spacer()
                Button(tr("닫기")) { dismiss() }.keyboardShortcut(.cancelAction)
                if case .success(let sql) = result {
                    CopyButton(title: tr("복사")) { sql }
                    Button(tr(".sql 저장…")) { save(sql) }
                    Button(tr("쿼리 탭으로 열기")) {
                        app.mode = .query
                        app.addTab(text: sql, title: "DDL · \(model.name)")
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(app.state != .connected)
                    .help(app.state == .connected ? tr("연결된 접속의 새 쿼리 탭에 넣어요. 실행은 직접 하세요.")
                                                  : tr("먼저 접속을 연결하세요."))
                }
            }
        }
        .padding(16)
        .frame(width: 860, height: 620)
    }

    private func save(_ sql: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "sql") ?? .plainText]
        panel.nameFieldStringValue = "\(model.name).sql"
        if panel.runModal() == .OK, let url = panel.url { try? sql.write(to: url, atomically: true, encoding: .utf8) }
    }
}

// MARK: - DB 와 비교 (Synchronize)

struct ModelCompareSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    let model: DataModel

    var body: some View {
        let result = Result { try model.compare(with: app.tables, dialect: app.dialect) }
        VStack(alignment: .leading, spacing: 10) {
            Label(tr("모델 → %@ / %@ 비교", app.selectedProfile?.name ?? "", app.currentDatabase),
                  systemImage: "arrow.left.arrow.right").font(.headline)
            Text(tr("모델을 기준으로 DB 에 없는 것, 다른 것, DB 에만 있는 것을 보여주고 DB 를 모델에 맞추는 SQL 을 만들어요."))
                .font(.caption).foregroundStyle(.secondary)
            if model.kind != app.selectedProfile?.kind {
                Label(tr("모델 대상 DB(%@)와 접속 DB(%@)가 달라서 타입 차이가 많이 보일 수 있어요.",
                         model.kind.title, app.selectedProfile?.kind.title ?? ""), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange).font(.callout)
            }
            switch result {
            case .failure(let e):
                Text(e.localizedDescription).foregroundStyle(.red)
                Spacer()
            case .success(let report):
                HStack(spacing: 14) {
                    Label(tr("DB 에 없음 %@", "\(report.missingCount)"), systemImage: "plus.circle").foregroundStyle(.green)
                    Label(tr("다름 %@", "\(report.differentCount)"), systemImage: "pencil.circle").foregroundStyle(.orange)
                    Label(tr("DB 에만 있음 %@", "\(report.extraCount)"), systemImage: "minus.circle").foregroundStyle(.secondary)
                    Text(tr("일치 테이블 %@", "\(report.matchedTables)")).foregroundStyle(.secondary)
                }
                .font(.callout)
                List(report.items) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(item.table + (item.object.map { ".\($0)" } ?? "")).font(.system(.callout, design: .monospaced))
                            Spacer()
                            Text(item.kind.rawValue).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(item.detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(minHeight: 200)
                Text(tr("DB 를 모델에 맞추는 SQL (DB 에만 있는 것은 지우지 않아요)")).font(.caption.weight(.semibold))
                ScrollView {
                    Text(report.fixScript.isEmpty ? tr("-- 차이가 없어요.") : report.fixScript)
                        .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                .frame(height: 160)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                HStack {
                    Spacer()
                    Button(tr("닫기")) { dismiss() }.keyboardShortcut(.cancelAction)
                    CopyButton(title: tr("복사")) { report.fixScript }
                    Button(tr("쿼리 탭으로 열기")) {
                        app.mode = .query
                        app.addTab(text: report.fixScript, title: "SYNC · \(model.name)")
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(report.fixScript.isEmpty)
                }
            }
            if case .failure = result {
                HStack { Spacer(); Button(tr("닫기")) { dismiss() }.keyboardShortcut(.cancelAction) }
            }
        }
        .padding(16)
        .frame(width: 820, height: 640)
    }
}

// MARK: - 리버스 엔지니어링

struct ReverseEngineerSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var picked: Set<String> = []
    @State private var filter = ""
    @State private var inferred = true
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(tr("리버스 엔지니어링"), systemImage: "arrow.uturn.backward.square").font(.headline)
            if !app.canReverseEngineer {
                Text(tr("SQL DB 접속을 연결하고 스키마를 불러온 뒤 다시 열어 주세요.")).foregroundStyle(.secondary)
                Spacer()
                HStack { Spacer(); Button(tr("닫기")) { dismiss() }.keyboardShortcut(.cancelAction) }
            } else {
                Text(tr("%@ / %@ 의 테이블 구조를 모델로 가져와요. 코멘트 첫 줄은 논리명, 나머지는 설명이 되고, FK 는 관계가 돼요.",
                        app.selectedProfile?.name ?? "", app.currentDatabase))
                    .font(.caption).foregroundStyle(.secondary)
                TextField(tr("모델 이름"), text: $name).textFieldStyle(.roundedBorder)
                HStack {
                    TextField(tr("테이블 검색"), text: $filter).textFieldStyle(.roundedBorder)
                    Button(tr("모두")) { picked = Set(shown.map(\.name)) }
                    Button(tr("해제")) { picked.removeAll() }
                }
                List(shown) { t in
                    Toggle(isOn: Binding(get: { picked.contains(t.name) },
                                         set: { if $0 { picked.insert(t.name) } else { picked.remove(t.name) } })) {
                        HStack {
                            Text(t.name).font(.system(.callout, design: .monospaced))
                            if let l = logicalName(t.comment) { Text(l).foregroundStyle(.secondary) }
                            Spacer()
                            Text(tr("컬럼 %@", "\(t.columns.count)")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
                Toggle(tr("FK 제약이 없어도 컬럼 이름으로 관계 추정 (FK 제약 없는 논리 관계로 들어가요)"), isOn: $inferred)
                    .toggleStyle(.checkbox)
                HStack {
                    Text(tr("%@개 선택", "\(picked.count)")).foregroundStyle(.secondary)
                    Spacer()
                    Button(tr("취소")) { dismiss() }.keyboardShortcut(.cancelAction)
                    Button(tr("모델 만들기")) { create() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(picked.isEmpty)
                }
            }
        }
        .padding(16)
        .frame(width: 620, height: 600)
        .onAppear {
            if name.isEmpty { name = "\(app.currentDatabase) " + tr("모델") }
            if picked.isEmpty {
                picked = app.selectedTables.isEmpty ? Set(app.tables.prefix(200).map(\.name)) : app.selectedTables
            }
        }
    }

    private var shown: [TableMeta] {
        filter.isEmpty ? app.tables : app.tables.filter { $0.name.localizedCaseInsensitiveContains(filter)
            || $0.comment.localizedCaseInsensitiveContains(filter) }
    }

    private func create() {
        let tables = app.tables.filter { picked.contains($0.name) }
        let names = Set(tables.map(\.name))
        let guesses = inferred ? DiagramLayout.inferredRelations(app.tables)
            .filter { names.contains($0.table) && names.contains($0.referencedTable) } : []
        let m = DataModel.reverse(tables, name: name.isEmpty ? app.currentDatabase : name,
                                  kind: app.selectedProfile?.kind ?? .mysql, inferred: guesses)
        app.modeling.add(m)
        app.mode = .modeling
        app.log(.info, .schema, tr("리버스 엔지니어링 · %@ · 테이블 %@개 · 관계 %@개", m.name, "\(m.tables.count)", "\(m.relations.count)"))
        dismiss()
    }
}
