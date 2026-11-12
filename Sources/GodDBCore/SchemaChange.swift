import Foundation

/// 테이블 하나에 대한 구조 변경. 테이블 수정 화면과 스키마 비교가 만들고, DB 별 Dialect 가 SQL 로 바꾼다.
public enum SchemaChange: Hashable, Sendable {
    case dropIndex(IndexMeta)
    case dropColumn(String)
    /// 이름 변경 (속성도 함께 바뀔 수 있음)
    case renameColumn(old: ColumnMeta, new: ColumnMeta)
    case modifyColumn(old: ColumnMeta, new: ColumnMeta)
    /// after == nil 이면 맨 앞
    case addColumn(ColumnMeta, after: String?)
    case addIndex(IndexMeta)
    case tableComment(old: String, new: String)
}
