import GodDBCore
import SwiftUI

/// 테이블 이름 변경 / 삭제 확인 창.
/// 삭제는 되돌릴 수 없어서 테이블 이름을 직접 입력해야 버튼이 켜진다.
struct TableActionSheet: View {
    @Environment(AppState.self) private var app
    let request: TableActionRequest
    @State private var input = ""
    @State private var working = false
    @State private var error: String?

    private var profile: ConnectionProfile? { app.profile(request.profileID) }
    private var dialect: any SQLDialect { Dialects.of(profile?.kind ?? .mysql) }
    private var database: String { app.connections[request.profileID]?.currentDatabase ?? "" }

    private var sql: String {
        switch request.kind {
        case .rename: return dialect.renameTableSQL(request.table, to: input.isEmpty ? "…" : input)
        case .drop: return dialect.dropTableSQL(request.table)
        }
    }

    private var canRun: Bool {
        guard !working else { return false }
        switch request.kind {
        case .rename:
            let name = input.trimmingCharacters(in: .whitespaces)
            return !name.isEmpty && name != request.table
        case .drop:
            return input == request.table
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if request.kind == .rename {
                Label(tr("테이블 이름 변경"), systemImage: "pencil").font(.headline)
                Text("\(profile?.name ?? "") / \(database) / \(request.table)").foregroundStyle(.secondary)
                TextField(tr("새 이름"), text: $input)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { if canRun { run() } }
                Text(tr("이 테이블을 쓰는 뷰·프로시저·애플리케이션 코드는 자동으로 바뀌지 않아요."))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Label(tr("테이블 삭제"), systemImage: "trash").font(.headline).foregroundStyle(.red)
                Text("\(profile?.name ?? "") / \(database) / \(request.table)").foregroundStyle(.secondary)
                Text(tr("테이블과 모든 데이터가 영구히 삭제돼요. 되돌릴 수 없어요."))
                    .foregroundStyle(.red)
                Text(tr("삭제하려면 테이블 이름 %@ 을(를) 입력하세요.", request.table)).font(.callout)
                TextField(request.table, text: $input)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { if canRun { run() } }
            }
            Text(sql)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            if let error {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button(tr("취소")) { app.tableAction = nil }
                    .keyboardShortcut(.cancelAction)
                Button(request.kind == .rename ? tr("이름 변경") : tr("삭제"), role: request.kind == .drop ? .destructive : nil) {
                    run()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canRun)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { if request.kind == .rename { input = request.table } }
    }

    private func run() {
        working = true
        error = nil
        let newName = input.trimmingCharacters(in: .whitespaces)
        Task {
            do {
                try await app.performTableAction(request, newName: newName)
                app.tableAction = nil
            } catch {
                self.error = ErrorText.describe(error).message
            }
            working = false
        }
    }
}
