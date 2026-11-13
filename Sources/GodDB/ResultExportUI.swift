import AppKit
import GodDBCore
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// 내보내는 중 진행 상황 (결과 아래 줄에 표시)
struct ExportProgress: Equatable {
    var format: ExportFormat
    var written = 0
    var total: Int?
}

/// 저장 창 옵션
@MainActor
@Observable
final class ResultExportOptions {
    enum Scope: Hashable { case visible, all }
    var format: ExportFormat = .csv { didSet { applyFormatToPanel() } }
    var scope: Scope = .all
    var excelBOM = true
    var tableName = "table"
    var baseName = "query"
    @ObservationIgnored weak var panel: NSSavePanel?

    static let lastFormatKey = "GodDB.export.format"

    func applyFormatToPanel() {
        guard let panel else { return }
        panel.allowedContentTypes = [UTType(filenameExtension: format.fileExtension) ?? .data]
        let current = (panel.nameFieldStringValue as NSString).deletingPathExtension
        panel.nameFieldStringValue = (current.isEmpty ? baseName : current) + "." + format.fileExtension
        UserDefaults.standard.set(format.rawValue, forKey: Self.lastFormatKey)
    }
}

/// 저장 창 아래에 붙는 옵션 (형식, 범위, 형식별 옵션)
private struct ResultExportAccessory: View {
    @Bindable var options: ResultExportOptions
    let visibleRows: Int
    let canFetchAll: Bool
    let knownTotal: Int?
    let stable: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker(tr("형식"), selection: $options.format) {
                ForEach(ExportFormat.allCases) { Text($0.title).tag($0) }
            }
            .frame(width: 260)
            Picker(tr("범위"), selection: $options.scope) {
                Text(allLabel).tag(ResultExportOptions.Scope.all).disabled(!canFetchAll)
                Text(tr("지금 보이는 행만 (%@행)", visibleRows.formatted())).tag(ResultExportOptions.Scope.visible)
            }
            .pickerStyle(.radioGroup)
            if options.scope == .all && canFetchAll {
                Text(tr("화면에 보이는 페이지가 아니라 쿼리의 전체 데이터를 5,000행씩 나눠 조회하며 파일에 바로 써요. 시작 전에 COUNT 로 전체 행 수를 확인하고, 끝나면 저장한 행 수와 맞춰 봐요."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if !stable {
                    Label(tr("정렬 기준(ORDER BY 또는 결과에 포함된 기본 키)이 없어 페이지 사이에 행이 빠지거나 겹칠 수 있어요. ORDER BY 를 넣고 다시 실행하는 걸 권장해요."),
                          systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
            switch options.format {
            case .csv, .tsv:
                Toggle(tr("엑셀 호환 (UTF-8 BOM, 한글 깨짐 방지)"), isOn: $options.excelBOM)
            case .sql:
                HStack {
                    Text(tr("대상 테이블"))
                    TextField("", text: $options.tableName).frame(width: 200)
                }
                Text(tr("INSERT 문 하나에 100행씩. 값은 모두 문자열 리터럴로 써요 (NULL 은 NULL)."))
                    .font(.caption).foregroundStyle(.secondary)
            case .xlsx:
                Text(tr("시트 하나에 최대 1,048,575행. 넘으면 그 앞까지만 저장하고 알려줘요. 숫자로 바꿔도 값이 그대로인 것만 숫자 셀로 써요 (앞자리 0 은 문자)."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            case .json:
                Text(tr("행마다 {컬럼: 값} 객체. NULL 은 null."))
                    .font(.caption).foregroundStyle(.secondary)
            case .markdown:
                Text(tr("Confluence · Jira · 슬랙에 붙여 넣기 좋은 표. 큰 결과에는 맞지 않아요."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(width: 520, alignment: .leading)
    }

    private var allLabel: String {
        if let knownTotal { return tr("쿼리 전체 결과 (전체 %@행, 페이지 단위로 다시 조회)", knownTotal.formatted()) }
        return tr("쿼리 전체 결과 (페이지 단위로 다시 조회)")
    }
}

extension AppState {
    /// 결과를 파일로 내보낸다 (형식 선택, 전체 결과는 페이지 단위로)
    func exportResult(_ tabID: UUID) {
        guard let tab = tabs.first(where: { $0.id == tabID }), let result = tab.result, !result.columns.isEmpty,
              tab.exportProgress == nil else { return }
        let options = ResultExportOptions()
        if let raw = UserDefaults.standard.string(forKey: ResultExportOptions.lastFormatKey), let f = ExportFormat(rawValue: raw) {
            options.format = f
        }
        // 페이지가 하나뿐이면 지금 보이는 게 전체 결과
        let morePages = result.isPaged && (result.hasMore || result.page > 0)
        let kind = profiles.first(where: { $0.id == tab.profileID })?.kind ?? .mysql
        let dialect = Dialects.of(kind)
        let canFetchAll = morePages && result.sql != nil && dialect.pagedSQL(result.sql ?? "", limit: 1, offset: 0) != nil
        if !canFetchAll { options.scope = .visible }

        let tableRef = result.sql.flatMap(ResultEditing.singleTable(in:))
        let bare = tableRef?.split(separator: ".").last.map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "`\"[]")) }
        options.tableName = bare ?? "table"
        let meta = bare.flatMap { b in connections[tab.profileID]?.tables.first { $0.name.caseInsensitiveCompare(b) == .orderedSame } }
        let pk = meta?.indexes.first(where: \.isPrimary)?.columns
        let plan = ResultExportPlan.stableSort(sql: result.sql ?? "", serverSort: result.serverSort,
                                               columns: result.columns.map(\.name), primaryKey: pk)

        let stamp = Date().formatted(.iso8601.year().month().day().dateSeparator(.omitted)
            .time(includingFractionalSeconds: false).timeSeparator(.omitted)).replacingOccurrences(of: "T", with: "_")
        options.baseName = "\(bare ?? "query")_\(stamp)"

        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = options.baseName + "." + options.format.fileExtension
        options.panel = panel
        options.applyFormatToPanel()
        panel.accessoryView = NSHostingView(rootView: ResultExportAccessory(
            options: options, visibleRows: result.rows.count, canFetchAll: canFetchAll,
            knownTotal: result.totalCount, stable: plan.stable))
        guard panel.runModal() == .OK, let url = panel.url else { return }

        var exportOptions = ExportOptions()
        exportOptions.excelBOM = options.excelBOM
        exportOptions.tableName = options.tableName.isEmpty ? "table" : options.tableName
        let format = options.format
        let fetchAll = options.scope == .all && canFetchAll

        exportTasks[tabID] = Task { [weak self] in
            guard let self else { return }
            await self.runExport(tabID: tabID, result: result, url: url, format: format, options: exportOptions,
                                 dialect: dialect, fetchAll: fetchAll, sort: plan.sort, stable: plan.stable)
        }
    }

    func cancelExport(_ tabID: UUID) {
        exportTasks[tabID]?.cancel()
    }

    private func runExport(tabID: UUID, result: QueryResult, url: URL, format: ExportFormat, options: ExportOptions,
                           dialect: any SQLDialect, fetchAll: Bool, sort: ResultSort?, stable: Bool) async {
        update(tabID) { $0.exportProgress = ExportProgress(format: format) }
        defer {
            update(tabID) { $0.exportProgress = nil }
            exportTasks[tabID] = nil
        }
        let started = Date()
        var writer: ResultExportWriter?
        do {
            let w = try ResultExportWriter(format: format, columns: result.columns.map(\.name), url: url,
                                           options: options, dialect: dialect)
            writer = w
            var total: Int?
            var truncated = false
            if fetchAll, let sql = result.sql {
                guard let tab = tabs.first(where: { $0.id == tabID }),
                      let session = connections[tab.profileID]?.session else { throw DBError.notConnected }
                if !tab.database.isEmpty, await session.current != tab.database { try await session.use(tab.database) }
                if !stable {
                    log(.warning, .query, tr("내보내기: 정렬 기준이 없어 페이지 사이에 행이 빠지거나 겹칠 수 있어요"))
                }
                // 전체 행 수 먼저 (실패해도 내보내기는 계속)
                total = result.totalCount
                if total == nil { total = try? await session.count(sql) }
                update(tabID) { $0.exportProgress?.total = total }
                truncated = try await session.exportAll(sql, sort: sort, to: w) { [weak self] written in
                    await MainActor.run { self?.update(tabID) { $0.exportProgress?.written = written } }
                }
            } else {
                var rows = result.rows.map(\.values)
                if let max = format.maxRows, rows.count > max { rows = Array(rows.prefix(max)); truncated = true }
                try w.write(rows)
            }
            try Task.checkCancellation()
            try w.finish()
            let secs = String(format: "%.1f", Date().timeIntervalSince(started))
            let written = w.rowsWritten
            lastExportURL = url
            if truncated {
                log(.warning, .query, tr("%@ 저장 · Excel 시트 최대 행 수를 넘어 %@행까지만 저장했어요 · %@", format.title,
                                         written.formatted(), url.lastPathComponent), detail: url.path)
            } else if fetchAll, let total, total != written {
                log(.warning, .query, tr("%@ 저장 · 전체 %@행인데 %@행을 저장했어요. 조회 중 데이터가 바뀌었거나 정렬 기준이 없어 생긴 차이일 수 있어요 · %@",
                                         format.title, total.formatted(), written.formatted(), url.lastPathComponent), detail: url.path)
            } else if fetchAll {
                log(.success, .query, tr("%@ 저장 · 전체 데이터 %@행 (COUNT 와 일치) · %@초 · %@", format.title,
                                         written.formatted(), secs, url.lastPathComponent), detail: url.path)
            } else {
                log(.success, .query, tr("%@ 저장 · 보이는 행 %@행 · %@", format.title, written.formatted(), url.lastPathComponent),
                    detail: url.path)
            }
        } catch is CancellationError {
            writer?.cancel()
            log(.info, .query, tr("내보내기를 취소했어요 (파일 삭제)"))
        } catch {
            writer?.cancel()
            logError(error, .query, context: tr("내보내기 실패"))
        }
    }
}
