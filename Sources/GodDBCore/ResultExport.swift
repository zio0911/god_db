import Foundation

/// 결과 내보내기 형식
public enum ExportFormat: String, CaseIterable, Sendable, Identifiable {
    case csv, tsv, xlsx, json, sql, markdown

    public var id: String { rawValue }

    public var fileExtension: String {
        switch self {
        case .csv: return "csv"
        case .tsv: return "tsv"
        case .xlsx: return "xlsx"
        case .json: return "json"
        case .sql: return "sql"
        case .markdown: return "md"
        }
    }

    public var title: String {
        switch self {
        case .csv: return "CSV"
        case .tsv: return "TSV"
        case .xlsx: return "Excel (.xlsx)"
        case .json: return "JSON"
        case .sql: return "SQL INSERT"
        case .markdown: return "Markdown"
        }
    }

    /// 한 파일에 담을 수 있는 최대 데이터 행 (Excel 시트는 머리글 포함 1,048,576행)
    public var maxRows: Int? { self == .xlsx ? 1_048_575 : nil }
}

public struct ExportOptions: Sendable {
    /// CSV / TSV 앞에 UTF-8 BOM (엑셀에서 한글 깨짐 방지)
    public var excelBOM = true
    /// SQL INSERT 대상 테이블, Excel 시트 이름
    public var tableName = "table"
    /// INSERT 한 문장에 넣을 행 수
    public var insertBatch = 100

    public init() {}
}

/// 결과를 파일로 조금씩 쓴다. 전체 결과는 페이지 단위로 받아 write 를 여러 번 부르고, 마지막에 finish.
/// 행을 메모리에 모아 두지 않는다 (Excel 은 시트 XML 을 임시 파일에 쓰고 finish 때 zip 으로 묶는다).
public final class ResultExportWriter {
    public let format: ExportFormat
    public let url: URL
    public private(set) var rowsWritten = 0

    private let columns: [String]
    private let options: ExportOptions
    private let dialect: (any SQLDialect)?
    private var handle: FileHandle
    private var buffer = ""
    private var tempDir: URL?
    private var pendingInsert: [String] = []
    private var jsonKeys: [String] = []
    private var finished = false

    public init(format: ExportFormat, columns: [String], url: URL, options: ExportOptions = ExportOptions(),
                dialect: (any SQLDialect)? = nil) throws {
        self.format = format
        self.columns = columns
        self.url = url
        self.options = options
        self.dialect = dialect
        let target: URL
        if format == .xlsx {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("goddb-xlsx-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir.appendingPathComponent("xl/worksheets"), withIntermediateDirectories: true)
            tempDir = dir
            target = dir.appendingPathComponent("xl/worksheets/sheet1.xml")
        } else {
            target = url
        }
        FileManager.default.createFile(atPath: target.path, contents: nil)
        guard let h = try? FileHandle(forWritingTo: target) else { throw ExportError.cannotWrite(target.path) }
        handle = h
        try writeHeader()
    }

    public enum ExportError: LocalizedError {
        case cannotWrite(String)
        case zipFailed(String)

        public var errorDescription: String? {
            switch self {
            case .cannotWrite(let p): return tr("파일을 쓸 수 없어요: %@", p)
            case .zipFailed(let m): return tr("Excel 파일을 만들지 못했어요: %@", m)
            }
        }
    }

    // MARK: 쓰기

    public func write(_ rows: [[String?]]) throws {
        for r in rows {
            let values = (0..<columns.count).map { $0 < r.count ? r[$0] : nil }
            switch format {
            case .csv: emit(values.map(Self.csvField).joined(separator: ",") + "\r\n")
            case .tsv: emit(values.map(Self.tsvField).joined(separator: "\t") + "\r\n")
            case .markdown: emit("| " + values.map(Self.markdownField).joined(separator: " | ") + " |\n")
            case .json:
                let obj = zip(jsonKeys, values).map { "\(Self.jsonString($0)): \(Self.jsonValue($1))" }.joined(separator: ", ")
                emit((rowsWritten == 0 ? "\n  {" : ",\n  {") + obj + "}")
            case .sql:
                pendingInsert.append("(" + values.map(sqlLiteral).joined(separator: ", ") + ")")
                if pendingInsert.count >= max(1, options.insertBatch) { flushInsert() }
            case .xlsx:
                emit("<row>" + values.map(Self.xlsxCell).joined() + "</row>\n")
            }
            rowsWritten += 1
        }
        try flush(force: false)
    }

    public func finish() throws {
        guard !finished else { return }
        finished = true
        switch format {
        case .json: emit(rowsWritten == 0 ? "]\n" : "\n]\n")
        case .sql: flushInsert()
        case .xlsx: emit("</sheetData></worksheet>\n")
        default: break
        }
        try flush(force: true)
        try handle.close()
        if format == .xlsx, let dir = tempDir {
            defer { try? FileManager.default.removeItem(at: dir) }
            try writeXlsxParts(dir)
            try zipDirectory(dir, to: url)
        }
    }

    /// 취소: 쓰던 파일을 지운다
    public func cancel() {
        finished = true
        try? handle.close()
        try? FileManager.default.removeItem(at: url)
        if let dir = tempDir { try? FileManager.default.removeItem(at: dir) }
    }

    private func emit(_ s: String) { buffer += s }

    private func flush(force: Bool) throws {
        guard force || buffer.utf8.count > 1 << 20, !buffer.isEmpty else { return }
        try handle.write(contentsOf: Data(buffer.utf8))
        buffer = ""
    }

    private func writeHeader() throws {
        switch format {
        case .csv:
            emit((options.excelBOM ? "\u{FEFF}" : "") + columns.map(Self.csvField).joined(separator: ",") + "\r\n")
        case .tsv:
            emit((options.excelBOM ? "\u{FEFF}" : "") + columns.map(Self.tsvField).joined(separator: "\t") + "\r\n")
        case .markdown:
            emit("| " + columns.map(Self.markdownField).joined(separator: " | ") + " |\n")
            emit("|" + String(repeating: " --- |", count: columns.count) + "\n")
        case .json:
            jsonKeys = Self.uniqueNames(columns)
            emit("[")
        case .sql:
            emit("-- GodDB export · \(columns.count) columns\n")
        case .xlsx:
            emit("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n")
            emit("<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">")
            // 머리글 고정
            emit("<sheetViews><sheetView workbookViewId=\"0\"><pane ySplit=\"1\" topLeftCell=\"A2\" activePane=\"bottomLeft\" state=\"frozen\"/></sheetView></sheetViews>")
            emit("<sheetData>\n<row>" + columns.map { Self.xlsxString($0, style: 1) }.joined() + "</row>\n")
        }
        try flush(force: true)
    }

    // MARK: 형식별 값

    static func csvField(_ v: String?) -> String {
        guard let v else { return "" }
        if v.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) {
            return "\"" + v.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return v
    }

    /// TSV 는 따옴표 규칙이 없어 탭·줄바꿈을 공백으로 바꾼다 (엑셀 붙여넣기용)
    static func tsvField(_ v: String?) -> String {
        guard let v else { return "" }
        return v.replacingOccurrences(of: "\r\n", with: " ").map { $0 == "\t" || $0 == "\n" || $0 == "\r" ? " " : String($0) }.joined()
    }

    static func markdownField(_ v: String?) -> String {
        guard let v else { return "NULL" }
        return v.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\r\n", with: "<br>")
            .replacingOccurrences(of: "\n", with: "<br>")
            .replacingOccurrences(of: "\r", with: "<br>")
    }

    /// 숫자로 써도 값이 바뀌지 않는 문자열만 숫자로 (앞자리 0, 15자리 넘는 수, 지수 표기는 문자열로 둔다)
    public static func isPlainNumber(_ v: String) -> Bool {
        guard !v.isEmpty, v.count <= 17 else { return false }
        guard v.range(of: "^-?(0|[1-9][0-9]*)(\\.[0-9]+)?$", options: .regularExpression) != nil else { return false }
        return v.filter(\.isNumber).count <= 15
    }

    static func jsonString(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if u.value < 0x20 { out += String(format: "\\u%04x", u.value) } else { out.unicodeScalars.append(u) }
            }
        }
        return out + "\""
    }

    static func jsonValue(_ v: String?) -> String {
        guard let v else { return "null" }
        return isPlainNumber(v) ? v : jsonString(v)
    }

    /// 같은 이름 컬럼이 있으면 뒤에 _2, _3 (JSON 키 중복 방지)
    static func uniqueNames(_ names: [String]) -> [String] {
        var seen: [String: Int] = [:]
        return names.map { n in
            let k = n.lowercased()
            seen[k, default: 0] += 1
            return seen[k]! == 1 ? n : "\(n)_\(seen[k]!)"
        }
    }

    private func sqlLiteral(_ v: String?) -> String {
        guard let v else { return "NULL" }
        return dialect?.quoteString(v) ?? SQLText.quoteString(v)
    }

    private func flushInsert() {
        guard !pendingInsert.isEmpty else { return }
        let table = dialect?.quoteTable(options.tableName) ?? SQLText.quoteIdent(options.tableName)
        let cols = columns.map { dialect?.quoteIdent($0) ?? SQLText.quoteIdent($0) }.joined(separator: ", ")
        emit("INSERT INTO \(table) (\(cols)) VALUES\n  " + pendingInsert.joined(separator: ",\n  ") + ";\n")
        pendingInsert = []
    }

    // MARK: Excel

    static func xmlEscape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for u in s.unicodeScalars {
            switch u {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default:
                // XML 1.0 에서 허용하지 않는 제어 문자는 뺀다
                if u.value < 0x20 && u != "\t" && u != "\n" && u != "\r" { continue }
                if u.value == 0xFFFE || u.value == 0xFFFF { continue }
                out.unicodeScalars.append(u)
            }
        }
        return out
    }

    static func xlsxString(_ s: String, style: Int = 0) -> String {
        // 셀 한 칸 최대 32,767자
        let text = s.count > 32_767 ? String(s.prefix(32_767)) : s
        return "<c t=\"inlineStr\"\(style > 0 ? " s=\"\(style)\"" : "")><is><t xml:space=\"preserve\">\(xmlEscape(text))</t></is></c>"
    }

    static func xlsxCell(_ v: String?) -> String {
        guard let v else { return "<c/>" }
        return isPlainNumber(v) ? "<c><v>\(v)</v></c>" : xlsxString(v)
    }

    /// 시트 이름: 31자, []:*?/\ 불가
    static func sheetName(_ s: String) -> String {
        let cleaned = String(s.map { "[]:*?/\\".contains($0) ? "_" : $0 }).trimmingCharacters(in: .whitespaces)
        let name = cleaned.isEmpty ? "Result" : cleaned
        return String(name.prefix(31))
    }

    private func writeXlsxParts(_ dir: URL) throws {
        let main = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
        let rel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        let pkg = "http://schemas.openxmlformats.org/package/2006/relationships"
        let head = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        let files: [String: String] = [
            "[Content_Types].xml": head + """
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
            <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
            <Default Extension="xml" ContentType="application/xml"/>\
            <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>\
            <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>\
            <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>\
            </Types>
            """,
            "_rels/.rels": head + """
            <Relationships xmlns="\(pkg)"><Relationship Id="rId1" Type="\(rel)/officeDocument" Target="xl/workbook.xml"/></Relationships>
            """,
            "xl/workbook.xml": head + """
            <workbook xmlns="\(main)" xmlns:r="\(rel)"><sheets><sheet name="\(Self.xmlEscape(Self.sheetName(options.tableName)))" sheetId="1" r:id="rId1"/></sheets></workbook>
            """,
            "xl/_rels/workbook.xml.rels": head + """
            <Relationships xmlns="\(pkg)">\
            <Relationship Id="rId1" Type="\(rel)/worksheet" Target="worksheets/sheet1.xml"/>\
            <Relationship Id="rId2" Type="\(rel)/styles" Target="styles.xml"/>\
            </Relationships>
            """,
            "xl/styles.xml": head + """
            <styleSheet xmlns="\(main)">\
            <fonts count="2"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><name val="Calibri"/></font></fonts>\
            <fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>\
            <borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>\
            <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>\
            <cellXfs count="2"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>\
            <xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/></cellXfs>\
            </styleSheet>
            """,
        ]
        for (path, text) in files {
            let u = dir.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: u)
        }
    }

    /// macOS 기본 /usr/bin/zip 으로 묶는다 (deflate 압축)
    private func zipDirectory(_ dir: URL, to out: URL) throws {
        try? FileManager.default.removeItem(at: out)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        p.currentDirectoryURL = dir
        p.arguments = ["-X", "-r", "-q", "-D", out.path, "."]
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        do { try p.run() } catch { throw ExportError.zipFailed(error.localizedDescription) }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw ExportError.zipFailed("zip \(p.terminationStatus) \(msg)")
        }
    }
}

// MARK: - 전체 결과를 페이지로 나눠 받을 때의 정렬

public enum ResultExportPlan {
    /// 페이지 사이에 행이 빠지거나 겹치지 않도록 쓸 정렬.
    /// - 이미 DB 정렬(serverSort)이나 SQL 의 ORDER BY 가 있으면 그대로 (nil, stable: true)
    /// - 없으면 단일 컬럼 기본 키가 결과에 있을 때 그 컬럼으로 정렬
    /// - 둘 다 아니면 (nil, stable: false) → 화면에서 경고
    public static func stableSort(sql: String, serverSort: ResultSort?, columns: [String],
                                  primaryKey: [String]?) -> (sort: ResultSort?, stable: Bool) {
        if let serverSort { return (serverSort, true) }
        if SQLText.hasTopLevelOrderBy(SQLText.stripComments(sql).uppercased()) { return (nil, true) }
        if let pk = primaryKey, pk.count == 1,
           let col = columns.first(where: { $0.caseInsensitiveCompare(pk[0]) == .orderedSame }) {
            return (ResultSort(column: col, ascending: true), true)
        }
        return (nil, false)
    }
}

// MARK: - 전체 결과를 페이지 단위로 받아 쓰기

extension DBSession {
    /// 쿼리 전체 결과를 chunk 행씩 나눠 조회하며 writer 에 바로 쓴다. 메모리에는 한 페이지만 둔다.
    /// - Returns: 형식의 최대 행 수에 걸려 잘랐는지
    @discardableResult
    public func exportAll(_ sql: String, sort: ResultSort?, chunk: Int = 5_000, to writer: ResultExportWriter,
                          progress: @Sendable (Int) async -> Void = { _ in }) async throws -> Bool {
        var page = 0
        while true {
            try Task.checkCancellation()
            let r = try await execute(sql, limit: chunk, page: page, sort: sort)
            var rows = r.rows.map(\.values)
            var truncated = false
            if let max = writer.format.maxRows, writer.rowsWritten + rows.count > max {
                rows = Array(rows.prefix(max - writer.rowsWritten))
                truncated = true
            }
            try writer.write(rows)
            await progress(writer.rowsWritten)
            if truncated { return true }
            if !r.hasMore || r.rows.isEmpty { return false }
            page += 1
        }
    }
}
