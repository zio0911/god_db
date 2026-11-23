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

/// 테이블 설명 JSON 가져오기 · 내보내기 · 지우기, Claude 로 만들기 (빈 양식 · 분석 요청문), 설명 목록
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
            makeWithClaude
            Divider()
            list
            HStack {
                Spacer()
                Button(tr("닫기")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(width: 620, height: 600)
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
            note(tr("아직 테이블 설명이 없어요. 아래 순서로 Claude 에 분석을 맡겨 만든 JSON 을 가져오세요."),
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

    private var makeWithClaude: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(tr("Claude 로 만들기")).font(.subheadline.weight(.semibold))
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    Text("1").foregroundStyle(.secondary)
                    Text(tr("지금 테이블 · 컬럼 이름 · 코멘트로 빈 양식 만들기 (데이터 값은 넣지 않아요)"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(tr("양식 저장…")) { saveSkeleton() }
                        .disabled(liveTables == nil)
                        .help(liveTables == nil ? tr("이 DB 에 연결해 있어야 해요") : "")
                }
                GridRow {
                    Text("2").foregroundStyle(.secondary)
                    Text(tr("분석 요청문 복사 → 빈 양식 · 소스 저장소와 함께 Claude 에 붙여넣기"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button { copyPrompt() } label: {
                        Label(copied ? tr("복사했어요") : tr("복사"), systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                }
                GridRow {
                    Text("3").foregroundStyle(.secondary)
                    Text(tr("받은 JSON 가져오기 (양식이 어긋나면 어디가 틀렸는지 알려 줘요)"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear.frame(width: 1, height: 1)
                }
            }
            .font(.callout)
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField(tr("테이블 · 설명 찾기"), text: $search).textFieldStyle(.roundedBorder)
            let tables = filtered
            List(tables, id: \.name) { t in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(t.name).font(.body.monospaced())
                        if let title = t.title, !title.isEmpty { Text(title) }
                        Spacer()
                        Text(tr("컬럼 %@", "\(t.columns?.count ?? 0)")).font(.caption).foregroundStyle(.secondary)
                    }
                    if let d = t.description, !d.isEmpty {
                        Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
            .listStyle(.bordered)
            .overlay {
                if entry != nil, tables.isEmpty { Text(tr("맞는 테이블이 없어요")).foregroundStyle(.secondary) }
            }
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
        // 이미 설명이 있으면 그 위에 새 테이블 · 컬럼만 더한 양식을 준다
        var doc = TableDescriptionDoc.skeleton(tables: live, database: request.database)
        if let current = entry?.doc {
            doc.overview = current.overview
            doc.tables = doc.tables.map { t in
                guard let old = current.table(t.name) else { return t }
                var merged = old
                var cols = old.columns ?? []
                for c in t.columns ?? [] where !cols.contains(where: { $0.name.lowercased() == c.name.lowercased() }) { cols.append(c) }
                merged.columns = cols
                if (merged.title ?? "").isEmpty { merged.title = t.title }
                return merged
            }
        }
        guard let data = try? doc.encoded() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(request.database)-table-descriptions.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        SaveFile.write(data, to: url)
    }

    private func copyPrompt() {
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
