import GodDBCore
import SwiftUI

/// 테이블 메모 창 요청 (사이드바 우클릭 > 테이블 메모…)
struct TableNotesRequest: Identifiable {
    let id = UUID()
    let profileID: UUID
    let database: String
    let table: String
}

extension AppState {
    func openTableNotes(table: String) {
        guard let id = selectedProfileID, state == .connected else { return }
        tableNotesRequest = TableNotesRequest(profileID: id, database: currentDatabase, table: table)
    }

    func saveTableNotes() {
        TableNoteStore.shared.save(tableNotes)
    }

    /// 사이드바 📝 표시: 지금 접속 · DB 에서 메모가 있는 테이블 (소문자)
    var tablesWithNotes: Set<String> {
        guard let id = selectedProfileID else { return [] }
        return tableNotes.tablesWithNotes(profileID: id, database: currentDatabase)
    }
}

/// 사이드바 테이블 이름 옆 📝 (메모가 있으면)
struct TableNoteBadge: View {
    @Environment(AppState.self) private var app
    let table: String

    var body: some View {
        Button { app.openTableNotes(table: table) } label: {
            Text("📝").font(.caption2)
        }
        .buttonStyle(.plain)
        .help(tr("테이블 메모 보기"))
        .accessibilityLabel(tr("테이블 메모 있음"))
    }
}

/// 테이블 메모 목록: 찾는 말(쉼표) · 컬럼 · 설명 · 확인됨 · 삭제, 직접 추가
struct TableNotesView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    let request: TableNotesRequest

    /// 고치는 중인 한 줄 (찾는 말 · 컬럼은 쉼표 글로)
    struct Draft: Identifiable, Equatable {
        var id: UUID
        var terms: String
        var columns: [String]
        var memo: String
        var confirmed: Bool
        var source: TableNote.Source
        var createdAt: Date
    }

    @State private var drafts: [Draft] = []
    @State private var loaded = false

    private var tableMeta: TableMeta? {
        app.connections[request.profileID]?.tables.first { $0.name.lowercased() == request.table.lowercased() }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(tr("테이블 메모 · %@", request.table), systemImage: "note.text").font(.headline)
            Text(tr("AI 데이터 찾기가 찾은 위치와 직접 적은 메모예요. 같은 말로 물으면 AI 없이 바로 답해요."))
                .font(.callout).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if drafts.isEmpty {
                        Text(tr("메모가 없어요")).foregroundStyle(.secondary).padding(.vertical, 8)
                    }
                    ForEach($drafts) { $d in row($d) }
                }
            }
            .frame(minHeight: 180, maxHeight: 420)
            HStack {
                Button { addDraft() } label: { Label(tr("메모 추가"), systemImage: "plus") }
                Spacer()
                Button(tr("취소")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(tr("저장")) { save() }
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(20)
        .frame(width: 580)
        .onAppear(perform: load)
    }

    @ViewBuilder
    private func row(_ d: Binding<Draft>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(d.wrappedValue.source == .ai ? tr("AI") : tr("직접"))
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color.purple.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                Toggle(tr("확인됨"), isOn: d.confirmed).toggleStyle(.checkbox)
                Spacer()
                Button(role: .destructive) { drafts.removeAll { $0.id == d.wrappedValue.id } } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help(tr("삭제"))
                .accessibilityLabel(tr("메모 삭제"))
            }
            LabeledContent(tr("찾는 말")) {
                TextField(tr("예: 학년, 학년코드"), text: d.terms)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(tr("찾는 말"))
            }
            LabeledContent(tr("컬럼")) {
                columnPicker(d)
            }
            LabeledContent(tr("설명")) {
                TextField(tr("예: 학생 테이블의 학년 코드 (1~6)"), text: d.memo, axis: .vertical)
                    .lineLimit(1...3)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(tr("설명"))
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private func columnPicker(_ d: Binding<Draft>) -> some View {
        let all = tableMeta?.columns.map(\.name) ?? []
        // 테이블에 없는 컬럼(이름이 바뀐 경우)도 보여 주고 뺄 수 있게
        let names = all + d.wrappedValue.columns.filter { c in !all.contains(c) }
        return Menu {
            ForEach(names, id: \.self) { name in
                Toggle(name, isOn: Binding(
                    get: { d.wrappedValue.columns.contains(name) },
                    set: { on in
                        if on {
                            d.wrappedValue.columns.append(name)
                        } else {
                            d.wrappedValue.columns.removeAll { $0 == name }
                        }
                    }))
            }
        } label: {
            Text(d.wrappedValue.columns.isEmpty ? tr("(테이블 전체)") : d.wrappedValue.columns.joined(separator: ", "))
                .lineLimit(1)
        }
        .fixedSize()
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        drafts = app.tableNotes.notes(profileID: request.profileID, database: request.database, table: request.table).map {
            Draft(id: $0.id, terms: $0.terms.joined(separator: ", "), columns: $0.columns, memo: $0.memo,
                  confirmed: $0.confirmed, source: $0.source, createdAt: $0.createdAt)
        }
    }

    private func addDraft() {
        drafts.append(Draft(id: UUID(), terms: "", columns: [], memo: "", confirmed: true, source: .user, createdAt: Date()))
    }

    /// 지운 메모는 지우고, 바뀐 메모만 고치고, 새 메모는 더한다 (찾는 말 · 컬럼 · 설명이 모두 빈 새 메모는 버림)
    private func save() {
        let before = app.tableNotes.notes(profileID: request.profileID, database: request.database, table: request.table)
        let keep = Set(drafts.map(\.id))
        var lib = app.tableNotes
        for n in before where !keep.contains(n.id) { lib.delete(n.id) }
        for d in drafts {
            let terms = TableNote.split(d.terms)
            let memo = d.memo.trimmingCharacters(in: .whitespacesAndNewlines)
            if let old = before.first(where: { $0.id == d.id }) {
                guard old.terms != terms || old.columns != d.columns || old.memo != memo || old.confirmed != d.confirmed else { continue }
                lib.update(d.id) {
                    $0.terms = terms
                    $0.columns = d.columns
                    $0.memo = memo
                    $0.confirmed = d.confirmed
                }
            } else if !terms.isEmpty || !d.columns.isEmpty || !memo.isEmpty {
                lib.add(TableNote(id: d.id, profileID: request.profileID, database: request.database, table: tableMeta?.name ?? request.table,
                                  columns: d.columns, terms: terms, memo: memo, source: .user, confirmed: d.confirmed,
                                  createdAt: d.createdAt))
            }
        }
        if lib != app.tableNotes {
            app.tableNotes = lib
            app.saveTableNotes()
            app.log(.info, .schema, tr("테이블 메모를 저장했어요: %@", request.table))
        }
        dismiss()
    }
}
