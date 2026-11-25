import AppKit
import GodDBCore
import SwiftUI
import UniformTypeIdentifiers

/// CSV / TSV 가져오기: 파일을 미리 보고 컬럼을 맞춘 뒤 한 트랜잭션으로 INSERT (실패하면 모두 되돌림)
struct CSVImportView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    let table: TableMeta

    @State private var url: URL?
    @State private var text = ""
    @State private var delimiter: Character = ","
    @State private var hasHeader = true
    @State private var emptyAsNull = true
    @State private var mapping: [String?] = []
    @State private var working = false
    @State private var error: String?

    private var rows: [[String]] { CSVImport.parse(text, delimiter: delimiter) }
    private var header: [String]? { hasHeader ? rows.first : nil }
    private var dataRows: [[String]] { hasHeader ? Array(rows.dropFirst()) : rows }
    private var csvColumns: Int { rows.map(\.count).max() ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(tr("CSV 가져오기 → %@", table.name)).font(.headline)
                Spacer()
                Button(url == nil ? tr("파일 고르기…") : tr("다른 파일…")) { pickFile() }
            }
            if let url {
                Text(url.path).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 16) {
                    Picker(tr("구분자"), selection: Binding(get: { String(delimiter) }, set: { delimiter = Character($0); remap() })) {
                        Text(tr("쉼표 ,")).tag(",")
                        Text(tr("탭")).tag("\t")
                        Text(tr("세미콜론 ;")).tag(";")
                    }
                    .fixedSize()
                    Toggle(tr("첫 줄은 머리글"), isOn: Binding(get: { hasHeader }, set: { hasHeader = $0; remap() }))
                    Toggle(tr("빈 칸은 NULL"), isOn: $emptyAsNull)
                }
                .toggleStyle(.checkbox)
                Text(tr("%@행 · %@열", "\(dataRows.count)", "\(csvColumns)")).foregroundStyle(.secondary)
                preview
            } else {
                ContentUnavailableView(tr("가져올 CSV / TSV 파일을 고르세요"), systemImage: "tablecells.badge.ellipsis",
                                       description: Text(tr("머리글이 컬럼 이름과 같으면 자동으로 맞춰요. 모든 행을 한 트랜잭션으로 넣고, 하나라도 실패하면 모두 되돌려요.")))
                    .frame(maxHeight: .infinity)
            }
            if let error {
                Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled).lineLimit(4)
            }
            HStack {
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button(tr("취소")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(tr("%@행 가져오기", "\(dataRows.count)")) { Task { await runImport() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(url == nil || dataRows.isEmpty || !mapping.contains { $0 != nil } || working)
            }
        }
        .padding(16)
        .frame(minWidth: 720, minHeight: 520)
    }

    /// 열마다 넣을 컬럼 고르기 + 앞 20행 미리 보기
    private var preview: some View {
        ScrollView([.horizontal, .vertical]) {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                GridRow {
                    ForEach(0..<csvColumns, id: \.self) { i in
                        Picker("", selection: Binding(get: { i < mapping.count ? mapping[i] : nil },
                                                      set: { v in if i < mapping.count { mapping[i] = v } })) {
                            Text(tr("건너뛰기")).tag(String?.none)
                            ForEach(table.columns) { c in Text(c.name).tag(String?.some(c.name)) }
                        }
                        .labelsHidden()
                        .frame(width: 150)
                    }
                }
                if let header {
                    GridRow {
                        ForEach(0..<csvColumns, id: \.self) { i in
                            Text(i < header.count ? header[i] : "").bold().lineLimit(1).frame(width: 150, alignment: .leading)
                        }
                    }
                    Divider()
                }
                ForEach(Array(dataRows.prefix(20).enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(0..<csvColumns, id: \.self) { i in
                            let v = i < row.count ? row[i] : ""
                            Text(v.isEmpty && emptyAsNull ? "NULL" : v)
                                .foregroundStyle(v.isEmpty ? .tertiary : .primary)
                                .font(.callout.monospaced()).lineLimit(1)
                                .frame(width: 150, alignment: .leading)
                        }
                    }
                }
            }
            .padding(8)
        }
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .tabSeparatedText, .plainText]
        guard panel.runModal() == .OK, let picked = panel.url else { return }
        do {
            var enc = String.Encoding.utf8
            text = try String(contentsOf: picked, usedEncoding: &enc)
            url = picked
            delimiter = CSVImport.detectDelimiter(text)
            error = nil
            remap()
        } catch {
            self.error = ErrorText.describe(error).message
        }
    }

    private func remap() {
        mapping = CSVImport.autoMap(header: header, csvColumns: csvColumns, tableColumns: table.columns.map(\.name))
    }

    private func runImport() async {
        working = true
        error = nil
        defer { working = false }
        let statements = CSVImport.inserts(table: table.name, mapping: mapping, rows: dataRows,
                                           dialect: app.dialect, emptyAsNull: emptyAsNull)
        do {
            try await app.importRows(into: table.name, statements: statements, rowCount: dataRows.count)
            dismiss()
        } catch {
            self.error = ErrorText.describe(error).message
        }
    }
}

extension AppState {
    /// 가져오기 INSERT 들을 한 트랜잭션으로 실행 (수동 커밋 모드면 열린 트랜잭션에 합류)
    func importRows(into table: String, statements: [String], rowCount: Int) async throws {
        guard let id = selectedProfileID, let session = connections[id]?.session else { throw DBError.notConnected }
        let target = (profile(id)?.name ?? "?") + (currentDatabase.isEmpty ? "" : "/\(currentDatabase)")
        do {
            try await QueryAudit.labeled("CSV 가져오기") { try await session.executeInTransaction(statements) }
        } catch {
            logError(error, .query, context: tr("CSV 가져오기 실패 (모두 되돌림)"),
                     audit: AuditRecord(.insert, target: target, statement: "CSV → \(table)"))
            await refreshTx(id)
            throw error
        }
        await refreshTx(id)
        log(.success, .query, tr("%@ 에 %@행 가져옴", table, "\(rowCount)"),
            audit: AuditRecord(.insert, target: target, result: "CSV 가져오기 \(rowCount)행", statement: "CSV → \(table)"))
    }
}
