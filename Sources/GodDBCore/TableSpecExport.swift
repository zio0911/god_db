import Foundation

/// 테이블 명세서 머리 정보
public struct TableSpecInfo: Hashable, Sendable {
    public var systemName: String
    public var author: String
    /// yyyy-MM-dd
    public var date: String

    public init(systemName: String, author: String, date: String) {
        self.systemName = systemName
        self.author = author
        self.date = date
    }
}

/// 모델을 테이블 명세서(엑셀)로: 목차 시트 + 테이블마다 시트 (컬럼 · 인덱스 · 관계).
/// 명세서 내용은 한국어 그대로 쓴다 (화면 언어와 상관없이).
public enum TableSpecExport {
    public static let tocSheetName = "목차"

    public struct ColumnRow: Hashable, Sendable {
        public var no: Int
        public var physical: String
        public var logical: String
        public var type: String
        public var length: String
        public var key: String
        public var notNull: String
        public var defaultValue: String
        public var comment: String
        public var references: String
        public var note: String
    }

    public struct IndexRow: Hashable, Sendable {
        public var no: Int
        public var name: String
        public var kind: String
        public var columns: String
    }

    public struct RelationRow: Hashable, Sendable {
        public var no: Int
        public var name: String
        public var mapping: String
        public var relation: String
        public var onDelete: String
        public var onUpdate: String
    }

    // MARK: 행 만들기

    /// varchar(50) → (varchar, 50), decimal(10,2) → (decimal, 10,2), 괄호 없으면 길이는 빈 칸
    public static func splitType(_ dataType: String) -> (type: String, length: String) {
        let t = dataType.trimmingCharacters(in: .whitespaces)
        guard let open = t.firstIndex(of: "("), let close = t.lastIndex(of: ")"), open < close else { return (t, "") }
        let base = t[..<open].trimmingCharacters(in: .whitespaces)
        let inner = t[t.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
        // 괄호 뒤 꾸밈말 (예: int(10) unsigned) 은 타입 쪽에 붙인다
        let tail = t[t.index(after: close)...].trimmingCharacters(in: .whitespaces)
        return (tail.isEmpty ? base : "\(base) \(tail)", inner)
    }

    public static func columnRows(_ model: DataModel, _ table: ModelTable) -> [ColumnRow] {
        let childRelations = model.relations.filter { $0.child == table.id }
        return table.columns.enumerated().map { i, c in
            var refs: [String] = []
            var isFK = false
            for r in childRelations {
                for p in r.pairs where p.child == c.id {
                    isFK = true
                    if let parent = model.table(r.parent), let pc = parent.columns.first(where: { $0.id == p.parent }) {
                        let ref = "\(parent.physicalName).\(pc.physicalName)"
                        if !refs.contains(ref) { refs.append(ref) }
                    }
                }
            }
            let key = [c.primaryKey ? "PK" : nil, isFK ? "FK" : nil].compactMap { $0 }.joined(separator: ", ")
            let defaults = [c.defaultValue.isEmpty ? nil : c.defaultValue, c.autoIncrement ? "AUTO_INCREMENT" : nil]
            let (type, length) = splitType(c.dataType)
            return ColumnRow(no: i + 1, physical: c.physicalName, logical: c.logicalName, type: type, length: length,
                             key: key, notNull: (c.notNull || c.primaryKey) ? "Y" : "",
                             defaultValue: defaults.compactMap { $0 }.joined(separator: ", "),
                             comment: c.comment, references: refs.joined(separator: ", "), note: c.unique ? "UQ" : "")
        }
    }

    /// 기본 키(있으면 맨 앞) + 유니크 컬럼 + 인덱스 — SQL 추출과 같은 이름
    public static func indexRows(_ model: DataModel, _ table: ModelTable) -> [IndexRow] {
        model.tableMeta(table).indexes.enumerated().map { i, idx in
            IndexRow(no: i + 1, name: idx.name, kind: idx.isPrimary ? "PK" : (idx.unique ? "유니크" : "일반"),
                     columns: idx.columns.joined(separator: ", "))
        }
    }

    /// 이 테이블이 자식인 관계 (외래 키)
    public static func relationRows(_ model: DataModel, _ table: ModelTable) -> [RelationRow] {
        model.relations.filter { $0.child == table.id }.enumerated().map { i, r in
            let parent = model.table(r.parent)
            let pairs = r.pairs.map { p -> String in
                let cc = table.columns.first { $0.id == p.child }?.physicalName ?? "?"
                let pc = parent?.columns.first { $0.id == p.parent }?.physicalName ?? "?"
                return "\(cc) → \(parent?.physicalName ?? "?").\(pc)"
            }
            let name = r.name.isEmpty ? "fk_\(table.physicalName)_\(parent?.physicalName ?? "")" : r.name
            return RelationRow(no: i + 1, name: name, mapping: pairs.joined(separator: ", "),
                               relation: r.cardinality.title + (r.identifying ? " · 식별" : " · 비식별"),
                               onDelete: r.onDelete.rawValue, onUpdate: r.onUpdate.rawValue)
        }
    }

    // MARK: 시트 이름

    /// Excel 시트 이름 규칙: 31자, []:*?/\ 불가, 앞뒤 작은따옴표 불가, 대소문자 무시하고 겹치지 않게 (~2, ~3 …)
    public static func sheetNames(_ names: [String], reserved: [String] = [tocSheetName]) -> [String] {
        var used = Set(reserved.map { $0.lowercased() } + ["history"])
        return names.map { raw in
            var base = String(raw.map { "[]:*?/\\".contains($0) ? "_" : $0 })
                .trimmingCharacters(in: .whitespacesAndNewlines)
            while base.hasPrefix("'") { base.removeFirst() }
            while base.hasSuffix("'") { base.removeLast() }
            if base.isEmpty { base = "Table" }
            var name = String(base.prefix(31))
            var n = 2
            while used.contains(name.lowercased()) {
                let suffix = "~\(n)"
                name = String(base.prefix(31 - suffix.count)) + suffix
                n += 1
            }
            used.insert(name.lowercased())
            return name
        }
    }

    // MARK: 통합 문서

    static let border = "FFD3DCE6"
    static let accentFill = "FFE6F1FB"
    static let accentText = "FF0C447C"
    static let linkText = "FF0563C1"

    static let title = XLSXStyle(bold: true, size: 14, color: accentText)
    static let section = XLSXStyle(bold: true, size: 11, color: accentText)
    static let label = XLSXStyle(bold: true, color: accentText, fill: accentFill, border: border)
    static let header = XLSXStyle(bold: true, color: accentText, fill: accentFill, border: border, align: .center)
    static let cell = XLSXStyle(border: border)
    static let center = XLSXStyle(border: border, align: .center)
    static let wrap = XLSXStyle(border: border, wrap: true)
    static let link = XLSXStyle(color: linkText, underline: true, border: border)
    static let backLink = XLSXStyle(color: linkText, underline: true, align: .right)

    public static func workbook(_ model: DataModel, info: TableSpecInfo) -> XLSXWorkbook {
        let names = sheetNames(model.tables.map { $0.physicalName.isEmpty ? $0.logicalName : $0.physicalName })
        var sheets = [tocSheet(model, info: info, names: names)]
        for (t, name) in zip(model.tables, names) {
            sheets.append(tableSheet(model, t, name: name))
        }
        return XLSXWorkbook(sheets: sheets, fontName: "맑은 고딕", fontCharset: 129)
    }

    public static func data(_ model: DataModel, info: TableSpecInfo) -> Data {
        workbook(model, info: info).data()
    }

    static func tocSheet(_ model: DataModel, info: TableSpecInfo, names: [String]) -> XLSXSheet {
        var s = XLSXSheet(name: tocSheetName)
        s.columnWidths = [6, 26, 24, 56, 8]
        s.set(1, 1, "테이블 명세서 — \(info.systemName)", style: title)
        s.merge(1, 1, 5, style: title)
        s.setHeight(1, 26)
        let rows: [(String, String)] = [("DBMS", model.kind.title), ("DB / 스키마", model.name),
                                        ("작성자", info.author), ("작성일", info.date)]
        for (i, (k, v)) in rows.enumerated() {
            let r = 3 + i
            s.set(r, 1, k, style: label); s.merge(r, 1, 2, style: label)
            s.set(r, 3, v, style: cell); s.merge(r, 3, 5, style: cell)
        }
        s.set(8, 1, "테이블 목록 (\(model.tables.count)개)", style: section)
        s.merge(8, 1, 5, style: section)
        for (c, h) in ["no", "테이블", "테이블명", "설명", "컬럼"].enumerated() { s.set(9, c + 1, h, style: header) }
        s.freezeRows = 9
        for (i, (t, name)) in zip(model.tables, names).enumerated() {
            let r = 10 + i
            let shown = t.physicalName.isEmpty ? name : t.physicalName
            s.set(r, 1, .number(i + 1), style: center)
            s.set(r, 2, shown, style: link)
            s.link(r, 2, location: "\(XLSXSheet.quoted(name))!A1", display: shown)
            s.set(r, 3, t.logicalName, style: cell)
            s.set(r, 4, t.comment, style: wrap)
            s.set(r, 5, .number(t.columns.count), style: center)
        }
        if model.tables.isEmpty { emptyRow(&s, 10, spans: [(1, 5)]) }
        return s
    }

    static func tableSheet(_ model: DataModel, _ t: ModelTable, name: String) -> XLSXSheet {
        var s = XLSXSheet(name: name)
        // no, 컬럼, 컬럼명, 타입, 길이, 키, NN, 기본값, 설명, 참조, 비고
        s.columnWidths = [5, 22, 18, 12, 8, 8, 5, 18, 32, 24, 8]
        let heading = t.physicalName.isEmpty ? name : t.physicalName
        s.set(1, 1, t.logicalName.isEmpty ? heading : "\(heading) · \(t.logicalName)", style: title)
        s.merge(1, 1, 9, style: title)
        s.set(1, 10, "← 목차", style: backLink)
        s.merge(1, 10, 11, style: backLink)
        s.link(1, 10, location: "\(XLSXSheet.quoted(tocSheetName))!A1", display: "← 목차")
        s.setHeight(1, 26)
        let info: [(String, String)] = [("설명", t.comment), ("DBMS · 스키마", "\(model.kind.title) · \(model.name)")]
        for (i, (k, v)) in info.enumerated() {
            let r = 2 + i
            s.set(r, 1, k, style: label); s.merge(r, 1, 2, style: label)
            s.set(r, 3, v, style: wrap); s.merge(r, 3, 11, style: wrap)
        }

        // 컬럼
        var r = 5
        s.set(r, 1, "컬럼", style: section)
        r += 1
        for (c, h) in ["no", "컬럼", "컬럼명", "타입", "길이", "키", "NN", "기본값", "설명", "참조", "비고"].enumerated() {
            s.set(r, c + 1, h, style: header)
        }
        s.freezeRows = r
        r += 1
        let cols = columnRows(model, t)
        for c in cols {
            s.set(r, 1, .number(c.no), style: center)
            s.set(r, 2, c.physical, style: cell)
            s.set(r, 3, c.logical, style: cell)
            s.set(r, 4, c.type, style: cell)
            s.set(r, 5, c.length, style: center)
            s.set(r, 6, c.key, style: center)
            s.set(r, 7, c.notNull, style: center)
            s.set(r, 8, c.defaultValue, style: cell)
            s.set(r, 9, c.comment, style: wrap)
            s.set(r, 10, c.references, style: cell)
            s.set(r, 11, c.note, style: center)
            r += 1
        }
        if cols.isEmpty { emptyRow(&s, r, spans: [(1, 11)]); r += 1 }

        // 인덱스: no | 인덱스 (B:C) | 종류 (D:E) | 컬럼 (F:K)
        r += 1
        s.set(r, 1, "인덱스", style: section)
        r += 1
        let idxSpans = [(1, 1), (2, 3), (4, 5), (6, 11)]
        headerRow(&s, r, ["no", "인덱스", "종류", "컬럼"], spans: idxSpans)
        r += 1
        let idx = indexRows(model, t)
        for i in idx {
            spanRow(&s, r, [.number(i.no), .text(i.name), .text(i.kind), .text(i.columns)], spans: idxSpans,
                    styles: [center, cell, center, cell])
            r += 1
        }
        if idx.isEmpty { emptyRow(&s, r, spans: [(1, 11)]); r += 1 }

        // 관계: no | 이름 (B:C) | 컬럼 → 참조 (D:H) | 관계 (I) | ON DELETE (J) | ON UPDATE (K)
        r += 1
        s.set(r, 1, "관계 (외래 키)", style: section)
        s.merge(r, 1, 3, style: section)
        r += 1
        let relSpans = [(1, 1), (2, 3), (4, 8), (9, 9), (10, 10), (11, 11)]
        headerRow(&s, r, ["no", "이름", "컬럼 → 참조", "관계", "ON DELETE", "ON UPDATE"], spans: relSpans)
        r += 1
        let rels = relationRows(model, t)
        for x in rels {
            spanRow(&s, r, [.number(x.no), .text(x.name), .text(x.mapping), .text(x.relation), .text(x.onDelete), .text(x.onUpdate)],
                    spans: relSpans, styles: [center, cell, cell, center, center, center])
            r += 1
        }
        if rels.isEmpty { emptyRow(&s, r, spans: [(1, 11)]) }
        return s
    }

    private static func headerRow(_ s: inout XLSXSheet, _ r: Int, _ titles: [String], spans: [(Int, Int)]) {
        spanRow(&s, r, titles.map { .text($0) }, spans: spans, styles: Array(repeating: header, count: titles.count))
    }

    private static func spanRow(_ s: inout XLSXSheet, _ r: Int, _ values: [XLSXValue], spans: [(Int, Int)], styles: [XLSXStyle]) {
        for (i, (from, to)) in spans.enumerated() {
            let v: XLSXValue = { if case .text(let t) = values[i], t.isEmpty { return .empty }; return values[i] }()
            s.set(r, from, v, style: styles[i])
            s.merge(r, from, to, style: styles[i])
        }
    }

    private static func emptyRow(_ s: inout XLSXSheet, _ r: Int, spans: [(Int, Int)]) {
        for (from, to) in spans {
            s.set(r, from, "없음", style: center)
            s.merge(r, from, to, style: center)
        }
    }
}
