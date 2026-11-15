import AppKit
import GodDBCore
import SwiftUI

/// 고른 폴더의 감사 로그(goddb-audit-*.tsv)를 파일만으로 검사한다
struct AuditCheckRow: View {
    @State private var folder: URL?
    @State private var reports: [AuditChain.FileReport] = []
    @State private var checking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(tr("로그 파일 검사"))
                Spacer()
                Button(tr("폴더 선택…")) { choose() }
                Button(tr("검사")) { Task { await run() } }
                    .disabled(folder == nil || checking)
            }
            Text(folder.map { $0.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") } ?? tr("검사할 감사 로그 폴더를 고르세요 (다른 사람에게 받은 로그도 가능)"))
                .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            if checking { ProgressView().controlSize(.small) }
            if !reports.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(reports) { r in
                        Text(AuditChain.describe(r)).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
                Button(tr("결과 복사")) { Pasteboard.copy(reports.map(AuditChain.describe).joined(separator: "\n")) }
            }
        }
    }

    private func choose() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.allowsMultipleSelection = false
        p.directoryURL = LogFile.shared.directory
        if p.runModal() == .OK { folder = p.url; reports = [] }
    }

    private func run() async {
        guard let folder else { return }
        checking = true
        LogFile.shared.flush()
        reports = await Task.detached { AuditChain.verify(directory: folder) }.value
        checking = false
    }
}
