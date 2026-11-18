import GodDBCore
import SwiftUI

/// 두 접속의 스키마를 비교하고 보정 SQL 을 만든다. (SQL 은 자동 실행하지 않음)
struct CompareView: View {
    @Environment(AppState.self) private var app

    @State private var sourceID: UUID?
    @State private var targetID: UUID?
    @State private var sourceDB = ""
    @State private var targetDB = ""
    @State private var running = false
    @State private var error: String?
    @State private var report: SchemaDiffReport?
    @State private var showExtra = false
    @State private var selection: SchemaDiffItem.ID?

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            if running {
                ProgressView(tr("두 DB 스키마를 읽는 중…")).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
            } else if let report {
                resultView(report)
            } else {
                ContentUnavailableView(tr("기준과 대상을 고르고 비교를 눌러 주세요"),
                                       systemImage: "arrow.left.arrow.right",
                                       description: Text(tr("대상 DB에 없는 테이블·컬럼·인덱스를 기준에 맞추는 SQL을 만들어요. 삭제(DROP)는 만들지 않아요.")))
            }
        }
    }

    /// 기준 / 대상을 두 줄로 둔다. 접속 이름이 길어도 선택 상자가 남은 폭 안에서 줄어 화면 밖으로 밀리지 않는다.
    private var controls: some View {
        HStack(alignment: .center, spacing: 12) {
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                endpointRow(tr("기준"), id: $sourceID, db: $sourceDB)
                endpointRow(tr("대상"), id: $targetID, db: $targetDB)
            }
            Button {
                Task { await compare() }
            } label: {
                Label(tr("비교"), systemImage: "arrow.left.arrow.right")
            }
            .buttonStyle(.borderedProminent)
            .disabled(sourceID == nil || targetID == nil || running)
        }
        .padding(10)
    }

    private func endpointRow(_ title: String, id: Binding<UUID?>, db: Binding<String>) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            let sql = app.profiles.filter { $0.kind.isSQL }
            let selected = app.profiles.first { $0.id == id.wrappedValue }
            HStack(spacing: 6) {
                Picker(title, selection: id) {
                    Text(tr("선택")).tag(UUID?.none)
                    // 그룹 없는 접속 먼저, 그다음 그룹별 (사이드바와 같은 순서)
                    ForEach(sql.filter { $0.group.isEmpty }) { profileItem($0) }
                    ForEach(app.profileGroups.filter { g in sql.contains { $0.group == g } }, id: \.self) { g in
                        Section(g) { ForEach(sql.filter { $0.group == g }) { profileItem($0) } }
                    }
                }
                .labelsHidden()
                .frame(minWidth: 160, maxWidth: .infinity, alignment: .leading)
                .help(selected.map { Self.label($0) + ($0.group.isEmpty ? "" : " · " + $0.group) } ?? "")
                // 고른 접속의 환경을 사이드바와 같은 색으로
                if let selected { EnvironmentBadge(environment: selected.environment) }
            }
            TextField(tr("DB/스키마 (비우면 기본)"), text: db)
                .frame(width: 170)
        }
    }

    /// 선택 목록 항목: [DB 아이콘] 이름 · 환경
    private func profileItem(_ p: ConnectionProfile) -> some View {
        Label { Text(Self.label(p)) } icon: { Image(nsImage: BrandLogo.image(p.kind)) }
            .tag(UUID?.some(p.id))
    }

    /// "이름 · 운영" (환경 표시 안 함이면 이름만)
    static func label(_ p: ConnectionProfile) -> String {
        p.environment == .none ? p.name : "\(p.name) · \(p.environment.title)"
    }

    @ViewBuilder
    private func resultView(_ report: SchemaDiffReport) -> some View {
        let visible = report.items.filter { showExtra || $0.severity != .extra }
        HStack(spacing: 8) {
            Chip(text: tr("일치 테이블 %@", "\(report.matchedTables)"), color: .green)
            Chip(text: tr("다름 %@", "\(report.differentCount)"), color: .orange)
            Chip(text: tr("누락 %@", "\(report.missingCount)"), color: .red)
            Toggle(tr("대상에만 있는 항목 %@", "\(report.extraCount)"), isOn: $showExtra)
                .toggleStyle(.checkbox)
            Spacer()
            Button {
                Pasteboard.copy(report.fixScript)
            } label: { Label(tr("전체 SQL 복사"), systemImage: "doc.on.doc") }
                .disabled(report.fixScript.isEmpty)
            Button {
                app.addTab(text: tr("-- 스키마 보정 SQL (실행 전 반드시 검토하세요)\n\n") + report.fixScript)
            } label: { Label(tr("쿼리 탭으로 열기"), systemImage: "square.and.pencil") }
                .disabled(report.fixScript.isEmpty)
        }
        .padding(10)

        if visible.isEmpty {
            ContentUnavailableView(tr("차이가 없어요"), systemImage: "checkmark.circle",
                                   description: Text(tr("두 스키마의 테이블·컬럼·인덱스가 같아요.")))
        } else {
            HStack(spacing: 0) {
                Table(visible, selection: $selection) {
                    TableColumn("") { item in icon(item) }.width(20)
                    TableColumn(tr("테이블"), value: \.table).width(min: 100, ideal: 160)
                    TableColumn(tr("대상")) { item in Text(item.object ?? "—") }.width(min: 80, ideal: 140)
                    TableColumn(tr("내용"), value: \.detail)
                }
                .frame(minWidth: 300)

                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text(tr("보정 SQL")).font(.headline)
                    let sql = visible.first { $0.id == selection }?.fixSQL
                        ?? (selection == nil ? tr("왼쪽에서 항목을 선택하세요.") : tr("-- 참고용 항목이라 SQL을 만들지 않아요."))
                    ScrollView {
                        Text(sql)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    Button(tr("이 SQL 복사")) { Pasteboard.copy(sql) }
                }
                .padding(10)
                .frame(width: 360)
            }
        }
    }

    @ViewBuilder
    private func icon(_ item: SchemaDiffItem) -> some View {
        switch item.severity {
        case .missing: Image(systemName: "xmark.circle").foregroundStyle(.red)
        case .different: Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
        case .extra: Image(systemName: "info.circle").foregroundStyle(.secondary)
        }
    }

    private func compare() async {
        guard let s = app.profiles.first(where: { $0.id == sourceID }),
              let t = app.profiles.first(where: { $0.id == targetID }) else { return }
        running = true
        error = nil
        report = nil
        defer { running = false }
        do {
            async let sourceSession = DBSession.connect(profile: s, password: app.password(for: s))
            async let targetSession = DBSession.connect(profile: t, password: app.password(for: t))
            let (ss, ts) = try await (sourceSession, targetSession)
            defer { Task { await ss.close(); await ts.close() } }

            // PostgreSQL 은 DB 가 아니라 스키마를 비교한다 (기본 public)
            let sdb = sourceDB.isEmpty ? (s.kind == .postgres ? "public" : s.database) : sourceDB
            let tdb = targetDB.isEmpty ? (t.kind == .postgres ? "public" : t.database) : targetDB
            guard !sdb.isEmpty, !tdb.isEmpty else {
                error = tr("비교할 DB 이름을 입력하거나 접속의 기본 DB를 설정해 주세요.")
                return
            }
            try await ss.use(sdb)
            let source = try await ss.loadSchema(sdb)
            let target = try await ts.loadSchema(tdb)

            let targetNames = Set(target.map { $0.name.lowercased() })
            var creates: [String: String] = [:]
            for table in source where !targetNames.contains(table.name.lowercased()) {
                creates[table.name] = try await ss.showCreateTable(table.name)
            }
            // 보정 SQL 은 대상 DB 문법으로 만든다. 종류가 다르면 MySQL 의 SHOW CREATE 결과는 쓰지 않는다.
            if s.kind != t.kind {
                creates = [:]
                app.log(.warning, .compare, tr("기준(%@)과 대상(%@) DB 종류가 달라요. 타입 이름 차이로 '다름'이 많이 나올 수 있어요.", "\(s.kind.title)", "\(t.kind.title)"))
            }
            let result = SchemaDiff.compare(source: source, target: target, createStatements: creates, dialect: ts.dialect)
            report = result
            selection = nil
            app.log(.success, .compare,
                    tr("%@/%@ → %@/%@ 비교 완료 · 누락 %@, 다름 %@", "\(s.name)", "\(sdb)", "\(t.name)", "\(tdb)", "\(result.missingCount)", "\(result.differentCount)"),
                    audit: AuditRecord(.compare, target: "\(s.name)/\(sdb) → \(t.name)/\(tdb)",
                                       result: "누락 \(result.missingCount), 다름 \(result.differentCount)"))
        } catch {
            self.error = app.logError(error, .compare, context: tr("스키마 비교 실패"))
        }
    }
}

struct Chip: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.callout)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(color)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }
}
