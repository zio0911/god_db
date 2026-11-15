import AppKit
import GodDBCore
import SwiftUI

/// 문제 보고: 미리 채운 내용을 확인·수정하고 GitHub 이슈 작성 화면을 연다
struct ProblemReportView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var db = "해당 없음"
    @State private var steps = ""
    @State private var expected = ""
    @State private var includeErrors = true
    @State private var includeCrashes = true
    @State private var log = ""
    @State private var crashes: [ProblemReport.Crash] = []

    private var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev" }
    private static let dbs = ["MySQL", "PostgreSQL", "SQL Server", "Redis", "해당 없음"]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(tr("문제 보고"), systemImage: "ladybug").font(.title3.weight(.semibold))
            Text(ProblemReport.environment(appVersion: version)).font(.callout).foregroundStyle(.secondary)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text(tr("제목")).gridColumnAlignment(.trailing)
                    TextField(tr("예: Redis 키 트리를 보다가 앱이 종료돼요"), text: $title).textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text(tr("DB 종류"))
                    Picker("", selection: $db) { ForEach(Self.dbs, id: \.self) { Text($0).tag($0) } }
                        .labelsHidden().fixedSize()
                }
                GridRow(alignment: .top) {
                    Text(tr("재현 방법"))
                    editor($steps, height: 70)
                }
                GridRow(alignment: .top) {
                    Text(tr("기대 / 실제"))
                    editor($expected, height: 50)
                }
                GridRow(alignment: .top) {
                    Text(tr("함께 보낼 기록"))
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 16) {
                            Toggle(tr("최근 오류"), isOn: $includeErrors).toggleStyle(.checkbox)
                            Toggle(tr("크래시 보고서 %@개", "\(crashes.count)"), isOn: $includeCrashes).toggleStyle(.checkbox)
                                .disabled(crashes.isEmpty)
                        }
                        editor($log, height: 150, mono: true)
                        Label(tr("호스트 · IP · 이메일 · 계정 · 홈 경로는 가렸어요. 공개 이슈로 올라가니 보내기 전에 한 번 더 확인해 주세요."),
                              systemImage: "eye.slash")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            HStack {
                Button(tr("복사")) {
                    Pasteboard.copy("## \(title)\n\(ProblemReport.environment(appVersion: version))\n\n### 재현 방법\n\(steps)\n\n### 기대 / 실제\n\(expected)\n\n```\n\(log)\n```")
                }
                Spacer()
                Button(tr("취소"), role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(tr("GitHub 에서 열기")) {
                    if let url = ProblemReport.issueURL(title: title.isEmpty ? tr("문제 보고") : title, version: version,
                                                        db: db, steps: steps, expected: expected, log: log) {
                        NSWorkspace.shared.open(url)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .help(tr("GitHub 버그 신고 화면을 미리 채워 브라우저로 열어요 (GitHub 로그인 필요)"))
            }
        }
        .padding(20)
        .frame(width: 640)
        .onAppear {
            crashes = ProblemReport.recentCrashes()
            rebuild()
        }
        .onChange(of: includeErrors) { rebuild() }
        .onChange(of: includeCrashes) { rebuild() }
    }

    private func rebuild() {
        let errors = includeErrors
            ? app.logs.filter { $0.level == .error }.suffix(20).map { e in
                "[\(e.source.rawValue)] \(e.message)" + (e.hint.map { " — \($0)" } ?? "")
            }
            : []
        log = ProblemReport.redact(ProblemReport.logText(errors: errors, crashes: includeCrashes ? crashes : []))
    }

    private func editor(_ text: Binding<String>, height: CGFloat, mono: Bool = false) -> some View {
        TextEditor(text: text)
            .font(mono ? .system(.caption, design: .monospaced) : .body)
            .frame(height: height)
            .padding(4)
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.3)))
    }
}
