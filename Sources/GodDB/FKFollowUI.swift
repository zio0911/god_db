import GodDBCore
import SwiftUI

/// 결과 하나에 대한 외래 키 따라가기 정보 (명세 docs/specs/1.4.0.md · F3)
/// 결과가 테이블 하나에서 온 조회이고, 그 테이블에 관계(진짜 외래 키 · 추정)가 있을 때만 만든다.
struct FKContext {
    let source: TableMeta
    let resultColumns: [String]
    /// 이 테이블이 참조하는 관계
    let outgoing: [FKRelation]
    /// 이 테이블(단일 기본 키)을 참조하는 관계
    let incoming: [FKRelation]
    /// 단일 컬럼 기본 키
    let primaryKey: String?
    let tables: [TableMeta]
    let dialect: any SQLDialect
    /// 새 탭(제목)에 SQL 을 넣고 평소 실행 경로로 실행
    let open: (_ sql: String, _ title: String) -> Void
    /// 외래 키가 들어 있는 결과 컬럼 번호 → 관계
    let byColumn: [Int: [FKRelation]]

    init(source: TableMeta, resultColumns: [String], tables: [TableMeta], inferred: [ForeignKeyMeta],
         dialect: any SQLDialect, open: @escaping (String, String) -> Void) {
        self.source = source
        self.resultColumns = resultColumns
        self.tables = tables
        self.dialect = dialect
        self.open = open
        outgoing = FKFollow.outgoing(from: source, inferred: inferred)
        incoming = FKFollow.incoming(to: source, tables: tables, inferred: inferred)
        primaryKey = FKFollow.singlePrimaryKey(source)
        var map: [Int: [FKRelation]] = [:]
        for (i, name) in resultColumns.enumerated() {
            let rs = FKFollow.relations(forColumn: name, in: outgoing)
            if !rs.isEmpty { map[i] = rs }
        }
        byColumn = map
    }

    var isEmpty: Bool { outgoing.isEmpty && incoming.isEmpty }

    /// 우클릭 메뉴에 보일 항목이 있는지 (참조 따라가기, 또는 기본 키 값이 있을 때 참조하는 행)
    func hasMenu(row: [String?]) -> Bool {
        !outgoing.isEmpty || (!incoming.isEmpty && primaryKeyValue(row) != nil)
    }

    /// 머리글 표시: 진짜 외래 키가 하나라도 있으면 false, 추정만 있으면 true, 관계 없으면 nil
    func inferredOnly(column: Int) -> Bool? {
        byColumn[column].map { rs in rs.allSatisfy(\.inferred) }
    }

    func followSQL(_ r: FKRelation, row: [String?]) -> String? {
        FKFollow.followSQL(r, values: FKFollow.values(for: r, resultColumns: resultColumns, row: row),
                           tables: tables, dialect: dialect)
    }

    func primaryKeyValue(_ row: [String?]) -> String? {
        primaryKey.flatMap { FKFollow.value(of: $0, resultColumns: resultColumns, row: row) }
    }

    func referencingSQL(_ r: FKRelation, row: [String?]) -> String? {
        FKFollow.referencingSQL(r, primaryKeyValue: primaryKeyValue(row), tables: tables, dialect: dialect)
    }

    func follow(_ r: FKRelation, row: [String?]) {
        if let sql = followSQL(r, row: row) { open(sql, FKFollow.followTitle(r)) }
    }

    func openReferencing(_ r: FKRelation, row: [String?]) {
        if let sql = referencingSQL(r, row: row) { open(sql, FKFollow.referencingTitle(r)) }
    }

    /// ⌘ 클릭: 그 칸이 들어 있는 관계 중 값이 있는 첫 관계를 따라간다 (NULL 이면 아무것도 안 함)
    func follow(column: Int, row: [String?]) {
        guard let r = byColumn[column]?.first(where: { followSQL($0, row: row) != nil }) else { return }
        follow(r, row: row)
    }

    // MARK: - 글자

    static func inferredSuffix(_ r: FKRelation) -> String { r.inferred ? " · " + tr("추정") : "" }

    /// `참조 따라가기 → ui_customers (customer_id)`
    static func followLabel(_ r: FKRelation) -> String {
        tr("참조 따라가기 → %@ (%@)", r.referencedTable, r.columns.joined(separator: ", ")) + inferredSuffix(r)
    }

    /// `ui_orders (customer_id)`
    static func referencingLabel(_ r: FKRelation) -> String {
        "\(r.table) (\(r.columns.joined(separator: ", ")))" + inferredSuffix(r)
    }
}

extension AppState {
    /// 이 탭의 결과에 대한 외래 키 따라가기 정보. 한 테이블 조회가 아니거나 관계가 없으면 nil.
    func fkContext(for tab: QueryTab) -> FKContext? {
        guard let result = tab.result, !result.columns.isEmpty, !tab.isPlan, let sql = result.sql,
              let info = connections[tab.profileID], let dialect = info.session?.dialect,
              let source = FKFollow.sourceTable(sql: sql, tables: info.tables) else { return nil }
        let profileID = tab.profileID
        let context = FKContext(source: source, resultColumns: result.columns.map(\.name), tables: info.tables,
                                inferred: info.inferredRelations, dialect: dialect) { [weak self] sql, title in
            self?.openFKQuery(sql, title: title, profileID: profileID)
        }
        return context.isEmpty ? nil : context
    }

    /// 새 탭에 넣고 평소 실행 경로(감사 로그 · 히스토리 · 안전 확인)로 실행
    func openFKQuery(_ sql: String, title: String, profileID: UUID) {
        guard addTab(text: sql, title: title, for: profileID) != nil else { return }
        Task { await run(sql: sql) }
    }
}

/// 결과 표 우클릭 메뉴 항목: 참조 따라가기 · 이 행을 참조하는 행 ▸
struct FKFollowMenuItems: View {
    let context: FKContext
    let row: [String?]

    var body: some View {
        ForEach(context.outgoing) { r in
            Button(FKContext.followLabel(r)) { context.follow(r, row: row) }
                .disabled(context.followSQL(r, row: row) == nil)
        }
        if !context.incoming.isEmpty, context.primaryKeyValue(row) != nil {
            Menu(tr("이 행을 참조하는 행")) {
                ForEach(context.incoming) { r in
                    Button(FKContext.referencingLabel(r)) { context.openReferencing(r, row: row) }
                }
            }
        }
    }
}

/// 행 상세: 외래 키 칸 값 옆 ↗ 버튼
struct FKFollowButtons: View {
    let context: FKContext
    let column: Int
    let row: [String?]

    var body: some View {
        ForEach(context.byColumn[column] ?? []) { r in
            Button { context.follow(r, row: row) } label: {
                Image(systemName: "arrow.up.right")
                    .opacity(r.inferred ? 0.45 : 1)
            }
            .buttonStyle(.hover)
            .disabled(context.followSQL(r, row: row) == nil)
            .help(FKContext.followLabel(r))
            .accessibilityLabel(FKContext.followLabel(r))
        }
    }
}

/// 행 상세 맨 아래: 참조하는 테이블 버튼 목록 (기본 키가 단일 컬럼이고 값이 있을 때만)
struct FKReferencingList: View {
    let context: FKContext
    let row: [String?]

    var body: some View {
        if !context.incoming.isEmpty, context.primaryKeyValue(row) != nil {
            VStack(alignment: .leading, spacing: 4) {
                Divider()
                Text(tr("참조하는 테이블")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(context.incoming) { r in
                    Button("↙ " + FKContext.referencingLabel(r)) { context.openReferencing(r, row: row) }
                        .buttonStyle(.hover)
                        .font(.callout)
                        .help(tr("이 행을 참조하는 행을 새 탭에서 조회해요"))
                }
            }
        }
    }
}
