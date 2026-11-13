import AppKit
import GodDBCore
import SwiftUI

/// 창 맨 아래 상태 표시줄. 마지막 이벤트를 한 줄로 보여주고, 누르면 상태창(로그 패널)을 연다.
struct MainStatusBar: View {
    @Environment(AppState.self) private var app

    var body: some View {
        HStack(spacing: 8) {
            if let last = app.lastLog {
                LevelIcon(level: last.level)
                Text(last.message)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(last.level == .error ? .red : .secondary)
            } else {
                Text(tr("준비됨")).foregroundStyle(.secondary)
            }
            Spacer()
            if app.errorCount > 0 {
                Label("\(app.errorCount)", systemImage: "exclamationmark.octagon.fill")
                    .foregroundStyle(.red)
                    .help(tr("오류 %@건", "\(app.errorCount)"))
            }
            Button {
                app.toggleLog()
            } label: {
                Label(tr("상태창"), systemImage: app.showLog ? "chevron.down" : "chevron.up")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("l", modifiers: [.command, .shift])
            .help(tr("상태창 열기/닫기 (⇧⌘L)"))
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.bar)
        .contentShape(Rectangle())
        .onTapGesture { app.toggleLog() }
    }
}

/// 상태창: 접속·쿼리·스키마·비교 이벤트와 오류 상세를 모아 보여준다.
struct LogPanelView: View {
    @Environment(AppState.self) private var app
    @State private var errorsOnly = false
    @State private var detailWidth: CGFloat = 380

    private var visible: [LogEntry] {
        (errorsOnly ? app.logs.filter { $0.level == .error || $0.level == .warning } : app.logs).reversed()
    }

    var body: some View {
        @Bindable var app = app
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(tr("상태창")).font(.headline)
                Toggle(tr("오류만"), isOn: $errorsOnly).toggleStyle(.checkbox)
                Spacer()
                Button {
                    Pasteboard.copy(visible.reversed().map(\.fullText).joined(separator: "\n\n"))
                } label: { Label(tr("전체 복사"), systemImage: "doc.on.doc") }
                    .disabled(visible.isEmpty)
                if LogFile.enabled {
                    Button {
                        try? FileManager.default.createDirectory(at: LogFile.shared.directory, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(LogFile.shared.directory)
                    } label: { Label(tr("로그 폴더"), systemImage: "folder") }
                        .help(tr("날짜별 감사 로그(goddb-audit-날짜.tsv) 폴더를 열어요 (~/Library/Logs/GodDB)"))
                }
                Button {
                    app.clearLogs()
                } label: { Label(tr("지우기"), systemImage: "trash") }
                    .disabled(app.logs.isEmpty)
                Button {
                    app.showLog = false
                } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help(tr("닫기"))
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()

            if visible.isEmpty {
                Text(errorsOnly ? tr("오류가 없어요.") : tr("아직 기록이 없어요."))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { geo in
                    HStack(spacing: 0) {
                        List(visible, selection: $app.selectedLogID) { entry in
                            LogRow(entry: entry).tag(entry.id)
                        }
                        .listStyle(.plain)
                        let maxDetail = max(200, geo.size.width - 200)
                        ResizeHandle(axis: .vertical, size: $detailWidth, range: 200...maxDetail)
                        LogDetail(entry: app.logs.first { $0.id == app.selectedLogID })
                            .frame(width: min(detailWidth, maxDetail))
                    }
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct LogRow: View {
    let entry: LogEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(entry.date, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            LevelIcon(level: entry.level)
            Text(entry.source.title)
                .font(.caption)
                .padding(.horizontal, 5)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
            Text(entry.message)
                .lineLimit(1)
                .foregroundStyle(entry.level == .error ? .red : .primary)
        }
        .font(.callout)
    }
}

struct LogDetail: View {
    let entry: LogEntry?

    var body: some View {
        if let entry {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        LevelIcon(level: entry.level)
                        Text(entry.message).font(.callout.weight(.medium)).textSelection(.enabled)
                    }
                    if let hint = entry.hint {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "lightbulb").foregroundStyle(.yellow)
                            Text(hint).textSelection(.enabled)
                        }
                        .font(.callout)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.yellow.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                    }
                    if let detail = entry.detail {
                        Text(detail)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Button {
                        Pasteboard.copy(entry.fullText)
                    } label: { Label(tr("이 항목 복사"), systemImage: "doc.on.doc") }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
            }
        } else {
            Text(tr("항목을 선택하면 자세한 내용이 나와요."))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct LevelIcon: View {
    let level: LogEntry.Level

    var body: some View {
        switch level {
        case .info: Image(systemName: "info.circle").foregroundStyle(.secondary)
        case .success: Image(systemName: "checkmark.circle").foregroundStyle(.green)
        case .warning: Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
        case .error: Image(systemName: "xmark.octagon").foregroundStyle(.red)
        }
    }
}
