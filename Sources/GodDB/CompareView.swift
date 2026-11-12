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

    private var controls: some View {
        HStack(spacing: 12) {
            endpointPicker(tr("기준"), id: $sourceID, db: $sourceDB)
            Image(systemName: "arrow.right").foregroundStyle(.secondary)
            endpointPicker(tr("대상"), id: $targetID, db: $targetDB)
            Spacer()
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

    private func endpointPicker(_ title: String, id: Binding<UUID?>, db: Binding<String>) -> some View {
        HStack(spacing: 6) {
            Text(title).foregroundStyle(.secondary)
            Picker(title, selection: id) {
                Text(tr("선택")).tag(UUID?.none)
                ForEach(app.profiles.filter { $0.kind.isSQL }) { Text($0.name).tag(UUID?.some($0.id)) }
            }
            .labelsHidden()
            .fixedSize()
            TextField(tr("DB/스키마 (비우면 기본)"), text: db)
                .frame(width: 150)
        }
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
                    tr("%@/%@ → %@/%@ 비교 완료 · 누락 %@, 다름 %@", "\(s.name)", "\(sdb)", "\(t.name)", "\(tdb)", "\(result.missingCount)", "\(result.differentCount)"))
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
