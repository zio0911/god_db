import GodDBCore
import SwiftUI

/// 쿼리 히스토리: 실행한 SQL 을 접속별 · 시간순으로 찾아 편집기로 다시 연다 (⌘Y)
struct HistoryView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var all: [HistoryEntry] = []
    @State private var query = ""
    @State private var onlyThisConnection = true
    @State private var selection: HistoryEntry.ID?
    @State private var confirmClear = false

    private var visible: [HistoryEntry] {
        QueryHistory.filter(all, query: query,
                            profileID: onlyThisConnection ? app.selectedProfileID : nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
                TextField(tr("SQL · DB 검색 (여러 단어는 모두 포함)"), text: $query)
                    .textFieldStyle(.roundedBorder)
                Toggle(tr("이 접속만"), isOn: $onlyThisConnection)
                    .toggleStyle(.checkbox)
                    .disabled(app.selectedProfileID == nil)
            }
            .padding(10)
            Divider()
            if visible.isEmpty {
                ContentUnavailableView(all.isEmpty ? tr("아직 실행한 쿼리가 없어요") : tr("찾는 쿼리가 없어요"),
                                       systemImage: "clock")
                    .frame(maxHeight: .infinity)
            } else {
                List(visible, selection: $selection) { e in
                    row(e)
                        .tag(e.id)
                        .contextMenu {
                            Button(tr("편집기에 넣기")) { open(e) }
                            Button(tr("SQL 복사")) { Pasteboard.copy(e.sql) }
                        }
                }
                .listStyle(.inset)
                .contextMenu(forSelectionType: HistoryEntry.ID.self) { _ in } primaryAction: { ids in
                    if let id = ids.first, let e = all.first(where: { $0.id == id }) { open(e) }
                }
            }
            Divider()
            HStack {
                Text(tr("최근 %@건 · 두 번 누르면 편집기에 넣어요", "\(visible.count)"))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(tr("기록 지우기…"), role: .destructive) { confirmClear = true }
                    .disabled(all.isEmpty)
                Button(tr("닫기")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(tr("편집기에 넣기")) {
                    if let e = all.first(where: { $0.id == selection }) { open(e) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selection == nil)
            }
            .padding(10)
        }
        .frame(minWidth: 720, minHeight: 480)
        .onAppear { all = QueryHistory.shared.all() }
        .alert(tr("쿼리 히스토리를 모두 지울까요?"), isPresented: $confirmClear) {
            Button(tr("지우기"), role: .destructive) {
                QueryHistory.shared.clear()
                all = []
            }
            Button(tr("취소"), role: .cancel) {}
        } message: {
            Text(tr("되돌릴 수 없어요. 감사 로그는 지우지 않아요."))
        }
    }

    private func row(_ e: HistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: e.ok ? "checkmark.circle" : "xmark.octagon")
                    .foregroundStyle(e.ok ? .green : .red)
                Text(e.date.formatted(date: .abbreviated, time: .standard)).monospacedDigit()
                Text(e.database.isEmpty ? e.profileName : "\(e.profileName) / \(e.database)")
                    .foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if let s = e.summary { Text(s).foregroundStyle(.secondary) }
                if e.ok { Text("\(e.elapsedMs)ms").monospacedDigit().foregroundStyle(.secondary) }
            }
            .font(.caption)
            Text(e.sql)
                .font(.system(.callout, design: .monospaced))
                .lineLimit(3)
                .truncationMode(.tail)
        }
        .padding(.vertical, 2)
    }

    private func open(_ e: HistoryEntry) {
        app.openFromHistory(e)
        dismiss()
    }
}
