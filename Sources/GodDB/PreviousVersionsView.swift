import AppKit
import GodDBCore
import SwiftUI

/// 메뉴 GodDB > 이전 버전 설치… (F5)
struct PreviousVersionsView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var installer = PreviousVersionInstaller()

    private static let dateFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(tr("이전 버전 설치"), systemImage: "clock.arrow.circlepath")
                    .font(.title3.weight(.semibold))
                Spacer()
                Text(tr("지금 버전 %@", PreviousVersionInstaller.currentVersion))
                    .font(.callout).foregroundStyle(.secondary)
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            status
            Text(tr("이전 버전에는 이후에 추가된 기능이 없어요. 문제가 해결되면 메뉴에서 업데이트 확인으로 최신으로 돌아오세요."))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Link(tr("GitHub 에서 직접 받기"), destination: PreviousVersions.releasesPage)
                    .font(.callout)
                Spacer()
                Button(tr("닫기")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(installer.busy)
            }
        }
        .padding(20)
        .frame(width: 620, height: 520)
        .task { await installer.load() }
    }

    @ViewBuilder private var content: some View {
        switch installer.list {
        case .loading:
            ProgressView(tr("릴리스 목록을 가져오는 중…"))
        case .failed(let message):
            VStack(spacing: 8) {
                Image(systemName: "wifi.exclamationmark").font(.largeTitle).foregroundStyle(.secondary)
                Text(tr("릴리스 목록을 가져오지 못했어요")).font(.headline)
                Text(message).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                HStack {
                    Button(tr("다시 시도")) { Task { await installer.load() } }
                    Link(tr("GitHub 에서 직접 받기"), destination: PreviousVersions.releasesPage)
                }
            }
        case .loaded(let entries) where entries.isEmpty:
            Text(tr("설치할 수 있는 다른 버전이 없어요")).foregroundStyle(.secondary)
        case .loaded(let entries):
            List(entries) { e in row(e) }
                .listStyle(.inset(alternatesRowBackgrounds: true))
        }
    }

    private func row(_ e: PreviousVersions.Entry) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(e.version).font(.headline)
                    if let d = e.date {
                        Text(Self.dateFormat.string(from: d)).font(.caption).foregroundStyle(.secondary)
                    }
                    if ReleaseNotes.compare(e.version, PreviousVersionInstaller.currentVersion) == .orderedDescending {
                        Text(tr("더 새 버전")).font(.caption.bold()).foregroundStyle(.orange)
                    }
                }
                ForEach(Array(e.notes.enumerated()), id: \.offset) { _, line in
                    Text((try? AttributedString(markdown: "• " + line)) ?? AttributedString("• " + line))
                        .font(.caption)
                        .lineLimit(2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(tr("설치…")) { installer.confirmAndInstall(e, app: app) }
                .disabled(installer.busy)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private var status: some View {
        let version = installer.target ?? ""
        switch installer.phase {
        case .idle:
            EmptyView()
        case .backingUp:
            progressRow(tr("데이터 폴더 백업 중…"), value: nil, cancellable: true)
        case .downloading(let p):
            progressRow(tr("%@ 내려받는 중… %@%%", version, "\(Int(p * 100))"), value: p, cancellable: true)
        case .verifying:
            progressRow(tr("서명 · 공증 확인 중…"), value: nil, cancellable: false)
        case .launching:
            progressRow(tr("앱을 끄고 %@ 를 설치해요…", version), value: nil, cancellable: false)
        case .failed(let message):
            Label {
                Text(tr("설치하지 않았어요: %@", message)).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            .font(.callout)
            .textSelection(.enabled)
        }
    }

    private func progressRow(_ title: String, value: Double?, cancellable: Bool) -> some View {
        HStack(spacing: 10) {
            if let value {
                ProgressView(value: value).frame(width: 220)
            } else {
                ProgressView().controlSize(.small)
            }
            Text(title).font(.callout)
            Spacer()
            if cancellable {
                Button(tr("취소")) { installer.cancel() }
            }
        }
    }
}
