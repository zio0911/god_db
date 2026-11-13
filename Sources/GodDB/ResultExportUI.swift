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

/// 내보내기 설정 창에 넘길 정보 (결과를 보고 미리 계산)
struct ExportRequest: Identifiable {
    let id = UUID()
    let tabID: UUID
    let result: QueryResult
    let kind: DatabaseKind
    let visibleRows: Int
    /// 쿼리 전체를 다시 조회할 수 있는지 (여러 페이지짜리 SELECT)
    let canFetchAll: Bool
    let knownTotal: Int?
    /// 페이지 사이 순서가 안정적인지 (정렬 기준 있음)
    let stable: Bool
    let sort: ResultSort?
    let defaultTable: String
    let baseName: String
}

/// 설정 창에서 고른 값
struct ExportChoice {
    var format: ExportFormat
    var fetchAll: Bool
    var excelBOM = true
    var tableName: String

    static let lastFormatKey = "GodDB.export.format"
}

/// 내보내기 설정 창: 형식 → 범위 → 형식별 옵션 → [저장 위치 선택…]
struct ExportSheet: View {
    let request: ExportRequest
    var onCancel: () -> Void = {}
    var onContinue: (ExportChoice) -> Void = { _ in }
    @State private var choice: ExportChoice

    init(request: ExportRequest, onCancel: @escaping () -> Void = {}, onContinue: @escaping (ExportChoice) -> Void = { _ in }) {
        self.request = request
        self.onCancel = onCancel
        self.onContinue = onContinue
        let saved = UserDefaults.standard.string(forKey: ExportChoice.lastFormatKey).flatMap(ExportFormat.init(rawValue:))
        _choice = State(initialValue: ExportChoice(format: saved ?? .csv, fetchAll: request.canFetchAll, tableName: request.defaultTable))
    }

    private static func icon(_ f: ExportFormat) -> String {
        switch f {
        case .csv: return "doc.text"
        case .tsv: return "tablecells"
        case .xlsx: return "tablecells.fill"
        case .json: return "curlybraces"
        case .sql: return "chevron.left.forwardslash.chevron.right"
        case .markdown: return "text.alignleft"
        }
    }

    private static func note(_ f: ExportFormat) -> String {
        switch f {
        case .csv: return tr("쉼표 구분 · 엑셀 호환")
        case .tsv: return tr("탭 구분 · 엑셀에 붙여넣기")
        case .xlsx: return tr("엑셀 파일 · 숫자 셀 유지")
        case .json: return tr("행마다 {컬럼: 값}")
        case .sql: return tr("INSERT 문 (다른 DB 로 옮기기)")
        case .markdown: return tr("Confluence · Jira 붙여넣기")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 2) {
                Label(tr("결과 내보내기"), systemImage: "square.and.arrow.down").font(.title3.weight(.semibold))
                Text(request.defaultTable == "table" ? tr("쿼리 결과") : request.defaultTable)
                    .foregroundStyle(.secondary)
            }

            section(tr("형식")) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(ExportFormat.allCases) { f in
                        card(selected: choice.format == f, icon: Self.icon(f), title: f.title, note: Self.note(f)) {
                            choice.format = f
                        }
                    }
                }
            }

            section(tr("범위")) {
                VStack(spacing: 8) {
                    card(selected: choice.fetchAll, icon: "square.stack.3d.down.right",
                         title: tr("쿼리 전체 데이터"),
                         note: request.canFetchAll
                            ? (request.knownTotal.map { tr("전체 %@행 · 5,000행씩 다시 조회하며 바로 저장", $0.formatted()) }
                               ?? tr("COUNT 로 전체 행 수 확인 후 5,000행씩 다시 조회하며 바로 저장"))
                            : tr("결과가 한 페이지뿐이라 보이는 행이 전체예요"),
                         disabled: !request.canFetchAll) { choice.fetchAll = true }
                    card(selected: !choice.fetchAll, icon: "rectangle.on.rectangle",
                         title: tr("지금 보이는 행만"),
                         note: tr("화면의 %@행 그대로", request.visibleRows.formatted())) { choice.fetchAll = false }
                }
                if choice.fetchAll && !request.stable {
                    Label(tr("정렬 기준(ORDER BY 또는 결과에 포함된 기본 키)이 없어 페이지 사이에 행이 빠지거나 겹칠 수 있어요. ORDER BY 를 넣고 다시 실행하는 걸 권장해요."),
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            options

            HStack {
                Spacer()
                Button(tr("취소"), role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button(tr("저장 위치 선택…")) {
                    UserDefaults.standard.set(choice.format.rawValue, forKey: ExportChoice.lastFormatKey)
                    onContinue(choice)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(choice.format == .sql && choice.tableName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 540)
    }

    @ViewBuilder
    private var options: some View {
        switch choice.format {
        case .csv, .tsv:
            section(tr("옵션")) {
                Toggle(tr("엑셀 호환 (UTF-8 BOM, 한글 깨짐 방지)"), isOn: $choice.excelBOM)
                    .toggleStyle(.checkbox)
            }
        case .sql:
            section(tr("옵션")) {
                HStack {
                    Text(tr("대상 테이블"))
                    TextField("", text: $choice.tableName).textFieldStyle(.roundedBorder)
                }
                hint(tr("INSERT 문 하나에 100행씩. 값은 모두 문자열 리터럴로 써요 (NULL 은 NULL)."))
            }
        case .xlsx:
            hint(tr("시트 하나에 최대 1,048,575행. 넘으면 그 앞까지만 저장하고 알려줘요. 숫자로 바꿔도 값이 그대로인 것만 숫자 셀로 써요 (앞자리 0 은 문자)."))
        case .json:
            hint(tr("행마다 {컬럼: 값} 객체. NULL 은 null."))
        case .markdown:
            hint(tr("Confluence · Jira · 슬랙에 붙여 넣기 좋은 표. 큰 결과에는 맞지 않아요."))
        }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    /// 고를 수 있는 카드 한 칸 (선택 표시 + 아이콘 + 제목 + 설명)
    private func card(selected: Bool, icon: String, title: String, note: String, disabled: Bool = false,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                    .frame(width: 16)
                Image(systemName: icon)
                    .frame(width: 20)
                    .foregroundStyle(selected ? Color.accentColor : .primary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).fontWeight(.medium)
                    Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(selected ? Color.accentColor.opacity(0.10) : Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: selected ? 1.5 : 1))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
    }
}

extension AppState {
    /// 결과 내보내기: 먼저 설정 창(형식·범위)을 띄운다
    func exportResult(_ tabID: UUID) {
        guard let tab = tabs.first(where: { $0.id == tabID }), let result = tab.result, !result.columns.isEmpty,
              tab.exportProgress == nil else { return }
        // 페이지가 하나뿐이면 지금 보이는 게 전체 결과
        let morePages = result.isPaged && (result.hasMore || result.page > 0)
        let kind = profiles.first(where: { $0.id == tab.profileID })?.kind ?? .mysql
        let dialect = Dialects.of(kind)
        let canFetchAll = morePages && result.sql != nil && dialect.pagedSQL(result.sql ?? "", limit: 1, offset: 0) != nil
        let tableRef = result.sql.flatMap(ResultEditing.singleTable(in:))
        let bare = tableRef?.split(separator: ".").last.map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "`\"[]")) }
        let meta = bare.flatMap { b in connections[tab.profileID]?.tables.first { $0.name.caseInsensitiveCompare(b) == .orderedSame } }
        let pk = meta?.indexes.first(where: \.isPrimary)?.columns
        let plan = ResultExportPlan.stableSort(sql: result.sql ?? "", serverSort: result.serverSort,
                                               columns: result.columns.map(\.name), primaryKey: pk)
        let stamp = Date().formatted(.iso8601.year().month().day().dateSeparator(.omitted)
            .time(includingFractionalSeconds: false).timeSeparator(.omitted)).replacingOccurrences(of: "T", with: "_")
        exportRequest = ExportRequest(tabID: tabID, result: result, kind: kind, visibleRows: result.rows.count,
                                      canFetchAll: canFetchAll, knownTotal: result.totalCount, stable: plan.stable,
                                      sort: plan.sort, defaultTable: bare ?? "table", baseName: "\(bare ?? "query")_\(stamp)")
    }

    /// 설정 창에서 [저장 위치 선택…] → 저장 창 → 내보내기 시작
    func continueExport(_ request: ExportRequest, _ choice: ExportChoice) {
        exportRequest = nil
        // 시트가 닫힌 뒤 저장 창을 띄운다
        DispatchQueue.main.async { [self] in
            let panel = NSSavePanel()
            panel.canCreateDirectories = true
            panel.allowedContentTypes = [UTType(filenameExtension: choice.format.fileExtension) ?? .data]
            panel.nameFieldStringValue = request.baseName + "." + choice.format.fileExtension
            panel.message = choice.fetchAll ? tr("%@ · 쿼리 전체 데이터", choice.format.title)
                                            : tr("%@ · 보이는 %@행", choice.format.title, request.visibleRows.formatted())
            guard panel.runModal() == .OK, let url = panel.url else { return }
            var options = ExportOptions()
            options.excelBOM = choice.excelBOM
            options.tableName = choice.tableName.trimmingCharacters(in: .whitespaces).isEmpty ? "table" : choice.tableName
            let tabID = request.tabID
            exportTasks[tabID] = Task { [weak self] in
                guard let self else { return }
                await self.runExport(tabID: tabID, result: request.result, url: url, format: choice.format, options: options,
                                     dialect: Dialects.of(request.kind), fetchAll: choice.fetchAll && request.canFetchAll,
                                     sort: request.sort, stable: request.stable)
            }
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
