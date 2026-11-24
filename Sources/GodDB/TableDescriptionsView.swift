import AppKit
import GodDBCore
import SwiftUI
import UniformTypeIdentifiers

/// 테이블 설명 관리 창 요청 (사이드바 DB 머리 우클릭 > 테이블 설명 (AI 참고)…) — #178
struct TableDescriptionsRequest: Identifiable {
    let id = UUID()
    let profileID: UUID
    let database: String
}

extension AppState {
    func openTableDescriptions() {
        guard let id = selectedProfileID, state == .connected else { return }
        tableDescriptionsRequest = TableDescriptionsRequest(profileID: id, database: currentDatabase)
    }

    func saveTableDescriptions() {
        TableDescriptionStore.shared.save(tableDescriptions)
    }
}

/// 테이블 설명 JSON 가져오기 · 내보내기 · 지우기, AI 에이전트로 채우기 (빈 양식에 할 일이 들어 있다), 설명 목록
struct TableDescriptionsView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    let request: TableDescriptionsRequest

    @State private var search = ""
    @State private var problem: String?
    @State private var confirmClear = false
    /// JSON 의 database 가 지금 DB 와 다를 때 확인
    @State private var pending: PendingImport?
    @State private var copied = false
    /// 상세로 볼 테이블 (#189)
    @State private var selected: String?

    struct PendingImport: Identifiable {
        let id = UUID()
        let doc: TableDescriptionDoc
        let fileName: String
    }

    private var entry: TableDescriptionEntry? {
        app.tableDescriptions.entry(profileID: request.profileID, database: request.database)
    }

    private var profile: ConnectionProfile? { app.profiles.first { $0.id == request.profileID } }

    /// 지금 보고 있는 DB 의 구조 (맞춰 보기 · 빈 양식에 쓴다)
    private var liveTables: [TableMeta]? {
        app.selectedProfileID == request.profileID && app.state == .connected && app.currentDatabase == request.database
            ? app.tables : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            status
            HStack(spacing: 8) {
                Button { importJSON() } label: { Label(tr("JSON 가져오기…"), systemImage: "square.and.arrow.down") }
                Button { exportJSON() } label: { Label(tr("내보내기…"), systemImage: "square.and.arrow.up") }
                    .disabled(entry == nil)
                Button(role: .destructive) { confirmClear = true } label: { Label(tr("지우기"), systemImage: "trash") }
                    .disabled(entry == nil)
            }
            Divider()
            makeWithAgent
            Divider()
            list
            HStack {
                Spacer()
                Button(tr("닫기")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(width: 880, height: 700)
        .alert(tr("이 DB 의 테이블 설명을 지울까요?"), isPresented: $confirmClear) {
            Button(tr("지우기"), role: .destructive) { clear() }
            Button(tr("취소"), role: .cancel) {}
        } message: {
            Text(tr("AI 어시스턴트 · 데이터 찾기가 더는 참고하지 않아요. 되돌릴 수 없으니 필요하면 먼저 내보내세요."))
        }
        .alert(item: $pending) { p in
            Alert(title: Text(tr("JSON 은 ‘%@’ DB 용이에요. ‘%@’ 에 넣을까요?", p.doc.database ?? "", request.database)),
                  primaryButton: .default(Text(tr("넣기"))) { apply(p.doc, fileName: p.fileName) },
                  secondaryButton: .cancel(Text(tr("취소"))))
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "doc.text").foregroundStyle(.purple)
                Text(tr("테이블 설명 (AI 참고)")).font(.headline)
                Text("· \(profile?.name ?? "") / \(request.database)").foregroundStyle(.secondary).lineLimit(1)
            }
            Text(tr("AI 어시스턴트 · 데이터 찾기가 질문에 맞는 테이블의 설명 · 코드 값 · 규칙을 함께 봐요 (이 PC 의 Ollama 에만)."))
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var status: some View {
        if let problem {
            note(problem, systemImage: "xmark.octagon", color: .red)
        }
        if let e = entry {
            note(entryLine(e), systemImage: "checkmark.circle", color: .green)
            if let live = liveTables {
                let c = e.doc.check(against: live)
                if !c.missingTables.isEmpty || !c.unknownColumns.isEmpty || !c.undescribedTables.isEmpty {
                    note(checkText(c), systemImage: "exclamationmark.triangle", color: .orange)
                }
            }
        } else {
            note(tr("아직 테이블 설명이 없어요. 아래 순서대로 AI 에이전트에게 맡겨 채운 JSON 을 가져오세요."),
                 systemImage: "info.circle", color: .secondary)
        }
    }

    private func entryLine(_ e: TableDescriptionEntry) -> String {
        let d = e.doc
        var line = tr("테이블 %@개 · 컬럼 %@개 · 코드 값 %@개", "\(d.tables.count)", "\(d.columnCount)", "\(d.valueCount)")
        line += " · " + e.updatedAt.formatted(date: .abbreviated, time: .shortened)
        if !e.fileName.isEmpty { line += " (\(e.fileName))" }
        return line
    }

    private func checkText(_ c: TableDescriptionDoc.Check) -> String {
        var parts: [String] = []
        if !c.missingTables.isEmpty {
            parts.append(tr("DB 에 없는 테이블 %@개 (%@)", "\(c.missingTables.count)", c.missingTables.prefix(3).joined(separator: ", ")))
        }
        if !c.unknownColumns.isEmpty {
            parts.append(tr("DB 에 없는 컬럼 %@개 (%@)", "\(c.unknownColumns.count)", c.unknownColumns.prefix(3).joined(separator: ", ")))
        }
        if !c.undescribedTables.isEmpty {
            parts.append(tr("설명 없는 테이블 %@개", "\(c.undescribedTables.count)"))
        }
        return parts.joined(separator: " · ")
    }

    private func note(_ text: String, systemImage: String, color: Color) -> some View {
        Label(text, systemImage: systemImage)
            .font(.callout)
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            .textSelection(.enabled)
    }

    private var makeWithAgent: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(tr("AI 에이전트로 채우기")).font(.subheadline.weight(.semibold))
            Text(tr("빈 양식을 Claude · Codex 같은 AI 에이전트에게 소스 저장소와 함께 주면, 소스와 테이블 구조를 분석해 채워 줘요. 채운 설명이 있으면 AI 어시스턴트가 질문을 더 정확히 이해해요."))
                .font(.callout).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    Text("1").foregroundStyle(.secondary)
                    Text(tr("빈 양식 내려받기 — 지금 테이블 · 컬럼 이름과 코멘트가 들어 있어요 (데이터 값은 없어요)"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(tr("빈 양식 내려받기…")) { saveSkeleton() }
                        .disabled(liveTables == nil)
                        .help(liveTables == nil ? tr("이 DB 에 연결해 있어야 해요") : "")
                }
                GridRow {
                    Text("2").foregroundStyle(.secondary)
                    Text(tr("요청문 샘플을 복사해 AI 에이전트에게 양식 · 소스 저장소와 함께 주기 (같은 내용이 양식 안 instructions 에도 있어요)"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button { copyRequest() } label: {
                        Label(copied ? tr("복사했어요") : tr("요청문 샘플 복사"), systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                }
                GridRow {
                    Text("3").foregroundStyle(.secondary)
                    Text(tr("채워 온 JSON 가져오기 (양식이 어긋나면 어디가 틀렸는지 알려 줘요)"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear.frame(width: 1, height: 1)
                }
            }
            .font(.callout)
        }
    }

    /// 지금 DB 와 맞춰 본 결과 (연결해 있을 때만)
    private var liveCheck: TableDescriptionDoc.Check? {
        guard let doc = entry?.doc, let live = liveTables else { return nil }
        return doc.check(against: live)
    }

    /// 왼쪽 목록 + 오른쪽 읽기 전용 상세 (#189)
    private var list: some View {
        let tables = filtered
        let check = liveCheck
        let missing = Set((check?.missingTables ?? []).map { $0.lowercased() })
        let current = tables.first { $0.name == selected } ?? tables.first
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                TextField(tr("테이블 · 설명 찾기"), text: $search).textFieldStyle(.roundedBorder)
                List(tables, id: \.name, selection: Binding(get: { current?.name }, set: { selected = $0 })) { t in
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Text(t.name).font(.callout.monospaced()).lineLimit(1)
                            if missing.contains(t.name.lowercased()) {
                                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                                    .help(tr("지금 DB 에 없는 테이블"))
                            }
                        }
                        Text([t.title ?? "", tr("컬럼 %@", "\(t.columns?.count ?? 0)")].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .tag(t.name)
                }
                .listStyle(.bordered)
                .overlay {
                    if entry != nil, tables.isEmpty { Text(tr("맞는 테이블이 없어요")).foregroundStyle(.secondary) }
                }
            }
            .frame(width: 220)
            Group {
                if let t = current {
                    TableDescriptionDetail(table: t, missing: missing.contains(t.name.lowercased()),
                                           unknownColumns: Set((check?.unknownColumns ?? []).map { $0.lowercased() }))
                } else {
                    Text(entry == nil ? tr("테이블 설명을 가져오면 여기에서 내용을 볼 수 있어요") : tr("왼쪽에서 테이블을 고르세요"))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var filtered: [TableDescriptionDoc.Table] {
        let all = entry?.doc.tables ?? []
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return all }
        return all.filter { t in
            ([t.name, t.title ?? "", t.description ?? ""] + (t.terms ?? []) + (t.columns ?? []).flatMap { [$0.name, $0.title ?? ""] })
                .contains { $0.lowercased().contains(q) }
        }
    }

    // MARK: 동작

    private func importJSON() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.message = tr("테이블 설명 JSON 파일을 고르세요.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let doc = try TableDescriptionDoc.parse(Data(contentsOf: url))
            problem = nil
            if let db = doc.database, !db.isEmpty, db.lowercased() != request.database.lowercased() {
                pending = PendingImport(doc: doc, fileName: url.lastPathComponent)
            } else {
                apply(doc, fileName: url.lastPathComponent)
            }
        } catch {
            problem = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            app.log(.warning, .schema, tr("테이블 설명을 가져오지 못했어요: %@", url.lastPathComponent), detail: problem)
        }
    }

    private func apply(_ doc: TableDescriptionDoc, fileName: String) {
        var doc = doc
        doc.database = request.database
        doc.instructions = nil
        app.tableDescriptions.set(TableDescriptionEntry(profileID: request.profileID, database: request.database,
                                                        fileName: fileName, doc: doc))
        app.saveTableDescriptions()
        app.log(.success, .schema, tr("테이블 설명을 가져왔어요: %@ · 테이블 %@개", "\(profile?.name ?? "")/\(request.database)", "\(doc.tables.count)"))
    }

    private func exportJSON() {
        guard let doc = entry?.doc, let data = try? doc.encoded() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(request.database)-table-descriptions.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        SaveFile.write(data, to: url)
    }

    private func saveSkeleton() {
        guard let live = liveTables else { return }
        // 이미 설명이 있으면 그 위에 새 테이블 · 컬럼만 더한 양식 + AI 에이전트가 할 일(instructions)
        let doc = TableDescriptionDoc.form(tables: live, database: request.database, kind: profile?.kind ?? .mysql,
                                           english: L10n.isEnglish, current: entry?.doc)
        guard let data = try? doc.encoded() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(request.database)-table-descriptions-form.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        SaveFile.write(data, to: url)
    }

    private func copyRequest() {
        Pasteboard.copy(TableDescriptionDoc.requestPrompt(database: request.database, kind: profile?.kind ?? .mysql,
                                                          english: L10n.isEnglish))
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
    }

    private func clear() {
        app.tableDescriptions.remove(profileID: request.profileID, database: request.database)
        app.saveTableDescriptions()
        app.log(.info, .schema, tr("테이블 설명을 지웠어요: %@", "\(profile?.name ?? "")/\(request.database)"))
    }
}

/// 테이블 설명 하나를 읽기 전용으로 보기 좋게 (#189): title · 설명 · 찾는 말 · 규칙 · 컬럼 표 (코드 값 · 관계)
struct TableDescriptionDetail: View {
    let table: TableDescriptionDoc.Table
    /// 지금 DB 에 없는 테이블
    let missing: Bool
    /// 지금 DB 에 없는 컬럼 (`table.column`, 소문자)
    let unknownColumns: Set<String>

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(table.name).font(.title3.monospaced().weight(.semibold)).textSelection(.enabled)
                    if let title = table.title, !title.isEmpty { Text(title).font(.title3) }
                }
                if missing {
                    Label(tr("지금 DB 에 없는 테이블이에요"), systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                if let d = table.description, !d.isEmpty {
                    Text(d).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if let terms = table.terms, !terms.isEmpty {
                    row(tr("찾는 말")) { chips(terms, color: .purple) }
                }
                if let notes = table.notes, !notes.isEmpty {
                    row(tr("규칙")) {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(notes.enumerated()), id: \.offset) { _, n in Text("• " + n).textSelection(.enabled) }
                        }
                    }
                }
                columns
                if (table.columns ?? []).isEmpty, (table.description ?? "").isEmpty, (table.terms ?? []).isEmpty {
                    Text(tr("이 테이블은 이름만 있어요")).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 6)
        }
    }

    @ViewBuilder
    private var columns: some View {
        let cols = table.columns ?? []
        if !cols.isEmpty {
            Text(tr("컬럼 %@", "\(cols.count)")).font(.subheadline.weight(.semibold)).padding(.top, 4)
            Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    Text(tr("컬럼")); Text(tr("이름")); Text(tr("설명 · 코드 값 · 관계"))
                }
                .font(.caption).foregroundStyle(.secondary)
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(cols, id: \.name) { c in
                    GridRow {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 3) {
                                Text(c.name).font(.callout.monospaced()).textSelection(.enabled)
                                if unknownColumns.contains("\(table.name).\(c.name)".lowercased()) {
                                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                                        .help(tr("지금 DB 에 없는 컬럼"))
                                }
                            }
                            if let terms = c.terms, !terms.isEmpty { chips(terms, color: .purple) }
                        }
                        .frame(width: 150, alignment: .leading)
                        Text(c.title ?? "").frame(width: 110, alignment: .leading)
                        VStack(alignment: .leading, spacing: 4) {
                            if let d = c.description, !d.isEmpty { Text(d).textSelection(.enabled) }
                            if let v = c.values, !v.isEmpty {
                                chips(v.sorted { $0.key < $1.key }.map { "\($0.key) = \($0.value)" }, color: .gray)
                            }
                            if let r = c.references, !r.isEmpty {
                                Text("→ " + r).font(.callout.monospaced()).textSelection(.enabled)
                            }
                            if unknownColumns.contains("\(table.name).\(c.name)".lowercased()) {
                                Text(tr("지금 DB 에 없는 컬럼")).font(.caption).foregroundStyle(.orange)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.callout)
                    Divider().gridCellUnsizedAxes(.horizontal)
                }
            }
        }
    }

    private func row<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.caption).foregroundStyle(.secondary).frame(width: 48, alignment: .leading)
            content()
        }
    }

    private func chips(_ items: [String], color: Color) -> some View {
        WrapLayout(spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Text(item)
                    .font(.caption)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(color.opacity(0.14), in: Capsule())
                    .accessibilityLabel(item)
            }
        }
    }
}

/// 칩을 가로로 늘어놓다 넘치면 다음 줄로
struct WrapLayout: SwiftUI.Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let w = rows.map { $0.width }.max() ?? 0
        let h = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width.map { min($0, w) } ?? w, height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for i in row.items {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var items: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for (i, sub) in subviews.enumerated() {
            let size = sub.sizeThatFits(.unspecified)
            let extra = rows[rows.count - 1].items.isEmpty ? size.width : size.width + spacing
            if rows[rows.count - 1].width + extra > width, !rows[rows.count - 1].items.isEmpty {
                rows.append(Row())
            }
            let last = rows.count - 1
            rows[last].width += rows[last].items.isEmpty ? size.width : size.width + spacing
            rows[last].height = max(rows[last].height, size.height)
            rows[last].items.append(i)
        }
        return rows
    }
}
