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
    @State private var selection: Set<SchemaDiffItem.ID> = []
    /// 결과 목록이 키보드 입력(⌘C · ⌘A)을 받게. DB 이름 입력칸에 남아 있으면 ⌘C 가 그 글자를 복사한다
    @FocusState private var listFocused: Bool
    @State private var task: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            if running {
                VStack(spacing: 12) {
                    ProgressView(tr("두 DB 스키마를 읽는 중…"))
                    Button(tr("취소")) { task?.cancel() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error {
                VStack(spacing: 12) {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                        .multilineTextAlignment(.center)
                    Button {
                        startCompare()
                    } label: { Label(tr("다시 시도"), systemImage: "arrow.clockwise") }
                        .disabled(sourceID == nil || targetID == nil)
                }
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
                startCompare()
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
        Label { Text(Self.label(p)) } icon: { Image(nsImage: BrandLogo.image(p.kind, redshift: p.redshift)) }
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
                // ⌘ · ⇧ 클릭으로 여러 개 고르기, ⌘A 모두 선택
                Table(visible, selection: $selection) {
                    TableColumn("") { item in icon(item) }.width(20)
                    TableColumn(tr("테이블"), value: \.table).width(min: 100, ideal: 160)
                    TableColumn(tr("대상")) { item in Text(item.object ?? "—") }.width(min: 80, ideal: 140)
                    TableColumn(tr("내용"), value: \.detail)
                }
                .frame(minWidth: 300)
                .focused($listFocused)
                .onChange(of: selection) { listFocused = true }
                .onAppear { listFocused = true }
                // ⌘A: 보이는 항목 모두 선택 (표 기본 동작이 선택 상태에 반영되지 않아 직접)
                .onCommand(#selector(NSResponder.selectAll(_:))) { selection = Set(visible.map(\.id)) }
                // ⌘C: 고른 항목들의 보정 SQL 을 목록 순서대로
                .onCopyCommand {
                    let text = SchemaDiffReport.fixSQL(of: visible, selected: selection)
                    return text.isEmpty ? [] : [NSItemProvider(object: text as NSString)]
                }
                .contextMenu(forSelectionType: SchemaDiffItem.ID.self) { ids in
                    let text = SchemaDiffReport.fixSQL(of: visible, selected: ids)
                    Button(ids.count > 1 ? tr("복사 (%@개, ⌘C)", "\(ids.count)") : tr("복사 (⌘C)")) {
                        Pasteboard.copy(text)
                    }
                    .disabled(text.isEmpty)
                    Divider()
                    Button(tr("모두 선택")) { selection = Set(visible.map(\.id)) }
                }

                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text(selection.count > 1 ? tr("보정 SQL · %@개 선택", "\(selection.count)") : tr("보정 SQL")).font(.headline)
                    let joined = SchemaDiffReport.fixSQL(of: visible, selected: selection)
                    let sql = !joined.isEmpty ? joined
                        : (selection.isEmpty ? tr("왼쪽에서 항목을 선택하세요.") : tr("-- 참고용 항목이라 SQL을 만들지 않아요."))
                    ScrollView {
                        Text(sql)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    Button(selection.count > 1 ? tr("선택한 %@개 SQL 복사", "\(selection.count)") : tr("이 SQL 복사")) {
                        Pasteboard.copy(joined)
                    }
                    .disabled(joined.isEmpty)
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

    private func startCompare() {
        guard !running else { return }
        task = Task { await compare() }
    }

    /// 접속 하나를 연다. 서버가 응답하지 않으면 DBSession 의 연결 시간 제한(15초)에 걸려 실패한다.
    private static func open(_ p: ConnectionProfile, password: String?) async -> Result<DBSession, any Error> {
        do { return .success(try await DBSession.connect(profile: p, password: password)) } catch { return .failure(error) }
    }

    private func compare() async {
        guard let s = app.profiles.first(where: { $0.id == sourceID }),
              let t = app.profiles.first(where: { $0.id == targetID }) else { return }
        running = true
        error = nil
        report = nil
        selection = []
        defer { running = false; task = nil }
        // 두 접속을 함께 열고, 한쪽만 실패해도 열린 쪽은 닫는다. 어느 쪽이 실패했는지 알려 준다.
        async let sourceResult = Self.open(s, password: app.password(for: s))
        async let targetResult = Self.open(t, password: app.password(for: t))
        let (sr, tr_) = await (sourceResult, targetResult)
        guard case .success(let ss) = sr, case .success(let ts) = tr_ else {
            if case .success(let opened) = sr { await opened.close() }
            if case .success(let opened) = tr_ { await opened.close() }
            if Task.isCancelled {
                app.log(.info, .compare, tr("스키마 비교를 취소했어요."))
                return
            }
            var messages: [String] = []
            if case .failure(let e) = sr {
                let context = tr("기준 접속 %@ 연결 실패", "\(s.name)")
                messages.append(context + "\n" + app.logError(e, .compare, context: context))
            }
            if case .failure(let e) = tr_ {
                let context = tr("대상 접속 %@ 연결 실패", "\(t.name)")
                messages.append(context + "\n" + app.logError(e, .compare, context: context))
            }
            error = messages.joined(separator: "\n\n")
            return
        }
        defer { Task { await ss.close(); await ts.close() } }
        do {
            // PostgreSQL 은 DB 가 아니라 스키마를 비교한다 (기본 public)
            let sdb = sourceDB.isEmpty ? (s.kind == .postgres ? "public" : s.database) : sourceDB
            let tdb = targetDB.isEmpty ? (t.kind == .postgres ? "public" : t.database) : targetDB
            guard !sdb.isEmpty, !tdb.isEmpty else {
                error = tr("비교할 DB 이름을 입력하거나 접속의 기본 DB를 설정해 주세요.")
                return
            }
            // 보정 SQL 은 대상 DB 문법으로 만든다. 종류가 다르면 MySQL 의 SHOW CREATE 결과는 쓰지 않는다.
            if s.kind != t.kind {
                app.log(.warning, .compare, tr("기준(%@)과 대상(%@) DB 종류가 달라요. 타입 이름 차이로 '다름'이 많이 나올 수 있어요.", "\(s.kind.title)", "\(t.kind.title)"))
            }
            let result = try await SchemaDiff.compare(source: ss, sourceContainer: sdb, target: ts, targetContainer: tdb)
            report = result
            selection = []
            app.log(.success, .compare,
                    tr("%@/%@ → %@/%@ 비교 완료 · 누락 %@, 다름 %@", "\(s.name)", "\(sdb)", "\(t.name)", "\(tdb)", "\(result.missingCount)", "\(result.differentCount)"),
                    audit: AuditRecord(.compare, target: "\(s.name)/\(sdb) → \(t.name)/\(tdb)",
                                       result: "누락 \(result.missingCount), 다름 \(result.differentCount)"))
        } catch {
            if Task.isCancelled || error is CancellationError {
                app.log(.info, .compare, tr("스키마 비교를 취소했어요."))
                return
            }
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
