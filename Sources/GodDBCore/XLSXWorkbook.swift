import Foundation

/// 작은 여러 시트 Excel(.xlsx) 작성기: 글꼴·채우기·테두리 스타일, 병합, 열 너비, 틀 고정, 문서 안 링크, 인쇄 설정.
/// 메모리에서 만들어 Data 로 돌려준다 (압축 없는 ZIP).
public struct XLSXStyle: Hashable, Sendable {
    public enum Align: String, Sendable { case general, left, center, right }

    public var bold = false
    public var size: Double = 10
    /// ARGB 16진 (예: FF0C447C). nil 이면 기본 글자색
    public var color: String?
    public var underline = false
    /// 단색 채우기 ARGB. nil 이면 채우기 없음
    public var fill: String?
    /// 얇은 테두리 색 ARGB. nil 이면 테두리 없음
    public var border: String?
    public var align: Align = .general
    public var wrap = false

    public init(bold: Bool = false, size: Double = 10, color: String? = nil, underline: Bool = false, fill: String? = nil,
                border: String? = nil, align: Align = .general, wrap: Bool = false) {
        self.bold = bold
        self.size = size
        self.color = color
        self.underline = underline
        self.fill = fill
        self.border = border
        self.align = align
        self.wrap = wrap
    }
}

public enum XLSXValue: Hashable, Sendable {
    case text(String)
    case number(Int)
    case empty
}

public struct XLSXSheet: Sendable {
    public struct Cell: Sendable {
        public var value: XLSXValue
        public var style: XLSXStyle
    }

    public struct Link: Sendable {
        public var ref: String
        /// 문서 안 위치 (예: 'tb_member'!A1)
        public var location: String
        public var display: String
    }

    public var name: String
    /// 열 너비 (문자 수 단위), A 열부터
    public var columnWidths: [Double] = []
    /// 위에서 몇 행을 고정할지 (0 이면 고정 없음)
    public var freezeRows = 0
    /// 인쇄: A4 가로, 너비 한 페이지에 맞춤
    public var printLandscapeFitWidth = true
    public private(set) var cells: [Int: [Int: Cell]] = [:]
    public private(set) var rowHeights: [Int: Double] = [:]
    public private(set) var merges: [String] = []
    public private(set) var links: [Link] = []

    public init(name: String) { self.name = name }

    /// row, col 은 1부터
    public mutating func set(_ row: Int, _ col: Int, _ value: XLSXValue, style: XLSXStyle) {
        cells[row, default: [:]][col] = Cell(value: value, style: style)
    }

    public mutating func set(_ row: Int, _ col: Int, _ text: String, style: XLSXStyle) {
        set(row, col, text.isEmpty ? .empty : .text(text), style: style)
    }

    /// 같은 행의 from...to 열을 병합. 덮이는 칸도 같은 스타일로 채워 테두리가 이어지게 한다
    public mutating func merge(_ row: Int, _ from: Int, _ to: Int, style: XLSXStyle) {
        guard to > from else { return }
        for c in (from + 1)...to { set(row, c, .empty, style: style) }
        merges.append("\(Self.ref(row, from)):\(Self.ref(row, to))")
    }

    public mutating func link(_ row: Int, _ col: Int, location: String, display: String) {
        links.append(Link(ref: Self.ref(row, col), location: location, display: display))
    }

    public mutating func setHeight(_ row: Int, _ height: Double) { rowHeights[row] = height }

    public var maxRow: Int { cells.keys.max() ?? 0 }
    public var maxColumn: Int { cells.values.flatMap(\.keys).max() ?? 0 }

    /// 1 → A, 27 → AA
    public static func column(_ c: Int) -> String {
        var n = c
        var s = ""
        while n > 0 {
            let r = (n - 1) % 26
            s = String(UnicodeScalar(UInt8(65 + r))) + s
            n = (n - 1) / 26
        }
        return s
    }

    public static func ref(_ row: Int, _ col: Int) -> String { "\(column(col))\(row)" }

    /// 시트 이름을 수식·링크에서 쓰는 꼴로: '이름' (작은따옴표는 두 번)
    public static func quoted(_ name: String) -> String { "'" + name.replacingOccurrences(of: "'", with: "''") + "'" }
}

public struct XLSXWorkbook: Sendable {
    public var sheets: [XLSXSheet]
    /// 기본 글꼴 이름 (모든 스타일에 쓴다)
    public var fontName: String
    /// 글꼴 문자 집합 (129 = 한글). nil 이면 쓰지 않음
    public var fontCharset: Int?

    public init(sheets: [XLSXSheet] = [], fontName: String = "Calibri", fontCharset: Int? = nil) {
        self.sheets = sheets
        self.fontName = fontName
        self.fontCharset = fontCharset
    }

    // MARK: 직렬화

    public func data() -> Data {
        let styles = StyleTable(sheets: sheets)
        var files: [(String, String)] = []
        let head = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        let main = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
        let rel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        let pkg = "http://schemas.openxmlformats.org/package/2006/relationships"
        let sheetType = "application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"
        let overrides = sheets.indices.map {
            "<Override PartName=\"/xl/worksheets/sheet\($0 + 1).xml\" ContentType=\"\(sheetType)\"/>"
        }.joined()
        files.append(("[Content_Types].xml", head + """
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
        <Default Extension="xml" ContentType="application/xml"/>\
        <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>\
        \(overrides)\
        <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>\
        </Types>
        """))
        files.append(("_rels/.rels", head + """
        <Relationships xmlns="\(pkg)"><Relationship Id="rId1" Type="\(rel)/officeDocument" Target="xl/workbook.xml"/></Relationships>
        """))
        let sheetList = sheets.enumerated().map { i, s in
            "<sheet name=\"\(Self.esc(s.name))\" sheetId=\"\(i + 1)\" r:id=\"rId\(i + 1)\"/>"
        }.joined()
        files.append(("xl/workbook.xml", head + """
        <workbook xmlns="\(main)" xmlns:r="\(rel)"><bookViews><workbookView activeTab="0"/></bookViews>\
        <sheets>\(sheetList)</sheets></workbook>
        """))
        let sheetRels = sheets.indices.map {
            "<Relationship Id=\"rId\($0 + 1)\" Type=\"\(rel)/worksheet\" Target=\"worksheets/sheet\($0 + 1).xml\"/>"
        }.joined()
        files.append(("xl/_rels/workbook.xml.rels", head + """
        <Relationships xmlns="\(pkg)">\(sheetRels)\
        <Relationship Id="rId\(sheets.count + 1)" Type="\(rel)/styles" Target="styles.xml"/></Relationships>
        """))
        files.append(("xl/styles.xml", head + styles.xml(fontName: fontName, charset: fontCharset, ns: main)))
        for (i, s) in sheets.enumerated() {
            files.append(("xl/worksheets/sheet\(i + 1).xml", head + sheetXML(s, index: i, styles: styles, ns: main, rel: rel)))
        }
        return ZipWriter.stored(files.map { ($0.0, Data($0.1.utf8)) })
    }

    private func sheetXML(_ s: XLSXSheet, index: Int, styles: StyleTable, ns: String, rel: String) -> String {
        var x = "<worksheet xmlns=\"\(ns)\" xmlns:r=\"\(rel)\">"
        if s.printLandscapeFitWidth { x += "<sheetPr><pageSetUpPr fitToPage=\"1\"/></sheetPr>" }
        let lastRow = max(1, s.maxRow), lastCol = max(1, s.maxColumn)
        x += "<dimension ref=\"A1:\(XLSXSheet.ref(lastRow, lastCol))\"/>"
        x += "<sheetViews><sheetView workbookViewId=\"0\"\(index == 0 ? " tabSelected=\"1\"" : "")>"
        if s.freezeRows > 0 {
            let top = XLSXSheet.ref(s.freezeRows + 1, 1)
            x += "<pane ySplit=\"\(s.freezeRows)\" topLeftCell=\"\(top)\" activePane=\"bottomLeft\" state=\"frozen\"/>"
            x += "<selection pane=\"bottomLeft\" activeCell=\"\(top)\" sqref=\"\(top)\"/>"
        }
        x += "</sheetView></sheetViews>"
        x += "<sheetFormatPr defaultRowHeight=\"16.5\"/>"
        if !s.columnWidths.isEmpty {
            x += "<cols>" + s.columnWidths.enumerated().map { i, w in
                "<col min=\"\(i + 1)\" max=\"\(i + 1)\" width=\"\(w)\" customWidth=\"1\"/>"
            }.joined() + "</cols>"
        }
        x += "<sheetData>"
        for r in s.cells.keys.sorted() {
            let height = s.rowHeights[r].map { " ht=\"\($0)\" customHeight=\"1\"" } ?? ""
            x += "<row r=\"\(r)\"\(height)>"
            for (c, cell) in s.cells[r]!.sorted(by: { $0.key < $1.key }) {
                let ref = XLSXSheet.ref(r, c)
                let sid = styles.index(cell.style)
                let sAttr = sid > 0 ? " s=\"\(sid)\"" : ""
                switch cell.value {
                case .empty: x += "<c r=\"\(ref)\"\(sAttr)/>"
                case .number(let n): x += "<c r=\"\(ref)\"\(sAttr)><v>\(n)</v></c>"
                case .text(let t):
                    let text = t.count > 32_767 ? String(t.prefix(32_767)) : t
                    x += "<c r=\"\(ref)\"\(sAttr) t=\"inlineStr\"><is><t xml:space=\"preserve\">\(Self.esc(text))</t></is></c>"
                }
            }
            x += "</row>"
        }
        x += "</sheetData>"
        if !s.merges.isEmpty {
            x += "<mergeCells count=\"\(s.merges.count)\">" + s.merges.map { "<mergeCell ref=\"\($0)\"/>" }.joined() + "</mergeCells>"
        }
        if !s.links.isEmpty {
            x += "<hyperlinks>" + s.links.map {
                "<hyperlink ref=\"\($0.ref)\" location=\"\(Self.esc($0.location))\" display=\"\(Self.esc($0.display))\"/>"
            }.joined() + "</hyperlinks>"
        }
        x += "<pageMargins left=\"0.5\" right=\"0.5\" top=\"0.6\" bottom=\"0.6\" header=\"0.3\" footer=\"0.3\"/>"
        if s.printLandscapeFitWidth {
            x += "<pageSetup paperSize=\"9\" orientation=\"landscape\" fitToWidth=\"1\" fitToHeight=\"0\"/>"
        }
        x += "</worksheet>"
        return x
    }

    static func esc(_ s: String) -> String { ResultExportWriter.xmlEscape(s) }

    /// 시트에 쓰인 스타일을 모아 styles.xml 의 글꼴·채우기·테두리·셀 서식 번호로 바꾼다
    struct StyleTable {
        struct Font: Hashable { var bold: Bool; var size: Double; var color: String?; var underline: Bool }
        var xfs: [XLSXStyle] = [XLSXStyle()]
        var xfIndex: [XLSXStyle: Int] = [XLSXStyle(): 0]
        var fonts: [Font] = []
        var fills: [String?] = [nil, nil]   // 0: none, 1: gray125 (Excel 예약)
        var borders: [String?] = [nil]

        init(sheets: [XLSXSheet]) {
            for s in sheets {
                for row in s.cells.values {
                    for cell in row.values where xfIndex[cell.style] == nil {
                        xfIndex[cell.style] = xfs.count
                        xfs.append(cell.style)
                    }
                }
            }
            for st in xfs {
                let f = Font(bold: st.bold, size: st.size, color: st.color, underline: st.underline)
                if !fonts.contains(f) { fonts.append(f) }
                if let fill = st.fill, !fills.contains(fill) { fills.append(fill) }
                if let b = st.border, !borders.contains(b) { borders.append(b) }
            }
        }

        func index(_ s: XLSXStyle) -> Int { xfIndex[s] ?? 0 }

        func xml(fontName: String, charset: Int?, ns: String) -> String {
            let name = XLSXWorkbook.esc(fontName)
            let fontXML = fonts.map { f in
                var x = "<font>"
                if f.bold { x += "<b/>" }
                if f.underline { x += "<u/>" }
                x += "<sz val=\"\(Self.num(f.size))\"/>"
                if let c = f.color { x += "<color rgb=\"\(c)\"/>" }
                x += "<name val=\"\(name)\"/><family val=\"3\"/>"
                if let charset { x += "<charset val=\"\(charset)\"/>" }
                return x + "</font>"
            }.joined()
            let fillXML = fills.enumerated().map { i, f in
                if i == 0 { return "<fill><patternFill patternType=\"none\"/></fill>" }
                if i == 1 { return "<fill><patternFill patternType=\"gray125\"/></fill>" }
                return "<fill><patternFill patternType=\"solid\"><fgColor rgb=\"\(f!)\"/><bgColor indexed=\"64\"/></patternFill></fill>"
            }.joined()
            let borderXML = borders.map { b in
                guard let b else { return "<border><left/><right/><top/><bottom/><diagonal/></border>" }
                let side = { (n: String) in "<\(n) style=\"thin\"><color rgb=\"\(b)\"/></\(n)>" }
                return "<border>" + side("left") + side("right") + side("top") + side("bottom") + "<diagonal/></border>"
            }.joined()
            let xfXML = xfs.map { s in
                let fontId = fonts.firstIndex(of: Font(bold: s.bold, size: s.size, color: s.color, underline: s.underline)) ?? 0
                let fillId = s.fill.flatMap { f in fills.firstIndex(of: f) } ?? 0
                let borderId = s.border.flatMap { b in borders.firstIndex(of: b) } ?? 0
                var x = "<xf numFmtId=\"0\" fontId=\"\(fontId)\" fillId=\"\(fillId)\" borderId=\"\(borderId)\" xfId=\"0\""
                x += " applyFont=\"1\"" + (fillId > 0 ? " applyFill=\"1\"" : "") + (borderId > 0 ? " applyBorder=\"1\"" : "")
                if s.align != .general || s.wrap {
                    x += " applyAlignment=\"1\"><alignment"
                    if s.align != .general { x += " horizontal=\"\(s.align.rawValue)\"" }
                    x += " vertical=\"center\""
                    if s.wrap { x += " wrapText=\"1\"" }
                    x += "/></xf>"
                } else {
                    x += "><alignment vertical=\"center\"/></xf>"
                }
                return x
            }.joined()
            return "<styleSheet xmlns=\"\(ns)\">"
                + "<fonts count=\"\(fonts.count)\">\(fontXML)</fonts>"
                + "<fills count=\"\(fills.count)\">\(fillXML)</fills>"
                + "<borders count=\"\(borders.count)\">\(borderXML)</borders>"
                + "<cellStyleXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/></cellStyleXfs>"
                + "<cellXfs count=\"\(xfs.count)\">\(xfXML)</cellXfs>"
                + "<cellStyles count=\"1\"><cellStyle name=\"Normal\" xfId=\"0\" builtinId=\"0\"/></cellStyles>"
                + "</styleSheet>"
        }

        static func num(_ d: Double) -> String { d == d.rounded() ? String(Int(d)) : String(d) }
    }
}

/// 압축 없는(stored) ZIP 작성기 — xlsx 처럼 작은 묶음용
enum ZipWriter {
    static func stored(_ entries: [(String, Data)]) -> Data {
        var out = Data()
        var central = Data()
        // 1980-01-01 00:00 (DOS 날짜·시간)
        let dosTime: UInt16 = 0, dosDate: UInt16 = (0 << 9) | (1 << 5) | 1
        for (name, body) in entries {
            let nameData = Data(name.utf8)
            let crc = crc32(body)
            let offset = UInt32(out.count)
            var local = Data()
            local.le32(0x0403_4B50)
            local.le16(20); local.le16(0x0800); local.le16(0)   // 버전, 플래그(UTF-8 이름), 저장(압축 없음)
            local.le16(dosTime); local.le16(dosDate)
            local.le32(crc); local.le32(UInt32(body.count)); local.le32(UInt32(body.count))
            local.le16(UInt16(nameData.count)); local.le16(0)
            out.append(local); out.append(nameData); out.append(body)

            central.le32(0x0201_4B50)
            central.le16(20); central.le16(20); central.le16(0x0800); central.le16(0)
            central.le16(dosTime); central.le16(dosDate)
            central.le32(crc); central.le32(UInt32(body.count)); central.le32(UInt32(body.count))
            central.le16(UInt16(nameData.count)); central.le16(0); central.le16(0)
            central.le16(0); central.le16(0); central.le32(0); central.le32(offset)
            central.append(nameData)
        }
        let centralOffset = UInt32(out.count)
        out.append(central)
        out.le32(0x0605_4B50)
        out.le16(0); out.le16(0)
        out.le16(UInt16(entries.count)); out.le16(UInt16(entries.count))
        out.le32(UInt32(central.count)); out.le32(centralOffset)
        out.le16(0)
        return out
    }

    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in data { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func le16(_ v: UInt16) { append(UInt8(v & 0xFF)); append(UInt8(v >> 8)) }
    mutating func le32(_ v: UInt32) { for i in 0..<4 { append(UInt8((v >> (8 * UInt32(i))) & 0xFF)) } }
}
