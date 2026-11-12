import AppKit
import GodDBCore
import Observation
import SwiftUI

/// CSV 저장 창 옵션
@MainActor
@Observable
final class CSVExportOptions {
    enum Scope: Hashable { case visible, all }
    var scope: Scope = .all
    var excelBOM = true
}

/// 저장 창 아래에 붙는 옵션 (범위, 엑셀 호환)
private struct CSVExportAccessory: View {
    @Bindable var options: CSVExportOptions
    let visibleRows: Int
    let canFetchAll: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(tr("범위"), selection: $options.scope) {
                Text(tr("쿼리 전체 결과 (페이지 제한 없이 다시 조회)")).tag(CSVExportOptions.Scope.all)
                    .disabled(!canFetchAll)
                Text(tr("지금 보이는 행만 (%@행)", "\(visibleRows)")).tag(CSVExportOptions.Scope.visible)
            }
            .pickerStyle(.radioGroup)
            Toggle(tr("엑셀 호환 (UTF-8 BOM, 한글 깨짐 방지)"), isOn: $options.excelBOM)
        }
        .padding(12)
        .frame(width: 460, alignment: .leading)
    }
}

extension AppState {
    /// 지금 보고 있는 결과를 CSV 파일로 저장한다.
    func exportCSV(_ tabID: UUID) {
        guard let tab = tabs.first(where: { $0.id == tabID }), let result = tab.result, !result.columns.isEmpty else { return }
        let options = CSVExportOptions()
        // 페이지가 하나뿐이면 지금 보이는 게 전체 결과
        let morePages = result.isPaged && (result.hasMore || result.page > 0)
        let canFetchAll = morePages && result.sql != nil && dialect.pagedSQL(result.sql ?? "", limit: 1, offset: 0) != nil
        if !canFetchAll { options.scope = .visible }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        let base = result.sql.flatMap(ResultEditing.singleTable(in:))?.split(separator: ".").last.map(String.init) ?? "query"
        let stamp = Date().formatted(.iso8601.year().month().day().dateSeparator(.omitted)
            .time(includingFractionalSeconds: false).timeSeparator(.omitted)).replacingOccurrences(of: "T", with: "_")
        panel.nameFieldStringValue = "\(base)_\(stamp).csv"
        panel.accessoryView = NSHostingView(rootView: CSVExportAccessory(options: options,
                                                                          visibleRows: result.rows.count,
                                                                          canFetchAll: canFetchAll))
        guard panel.runModal() == .OK, let url = panel.url else { return }

        Task {
            update(tabID) { $0.pageLoading = true }
            defer { update(tabID) { $0.pageLoading = false } }
            do {
                var rows = result
                if options.scope == .all && canFetchAll, let sql = result.sql {
                    guard let session = connections[tab.profileID]?.session else { throw DBError.notConnected }
                    if !tab.database.isEmpty, await session.current != tab.database { try await session.use(tab.database) }
                    rows = try await session.execute(sql, limit: 0, sort: result.serverSort)
                }
                let text = (options.excelBOM ? "\u{FEFF}" : "") + rows.csv(lineEnding: "\r\n") + "\r\n"
                try text.write(to: url, atomically: true, encoding: .utf8)
                log(.success, .query, tr("CSV 저장 · %@행 · %@", "\(rows.rows.count)", url.lastPathComponent), detail: url.path)
                lastExportURL = url
            } catch {
                logError(error, .query, context: tr("CSV 저장 실패"))
            }
        }
    }
}
