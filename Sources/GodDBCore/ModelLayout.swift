import CoreGraphics
import Foundation

/// 모델링 다이어그램 자동 정렬: 관계를 따라 부모는 왼쪽 열, 자식은 오른쪽 열에 겹치지 않게 놓는다.
/// 관계 없는 테이블은 그 아래에 격자로. 같은 열 안에서는 부모 위치의 평균 순서로 놓아 선이 덜 엇갈리게 한다.
public enum ModelLayout {
    public struct Options: Sendable {
        public var cardWidth: CGFloat
        /// 열 사이 간격 (관계선이 지나갈 자리)
        public var columnGap: CGFloat
        /// 같은 열 카드 사이 간격
        public var rowGap: CGFloat
        /// 왼쪽 위 여백
        public var origin: CGPoint

        public init(cardWidth: CGFloat = 260, columnGap: CGFloat = 120, rowGap: CGFloat = 48,
                    origin: CGPoint = CGPoint(x: 40, y: 40)) {
            self.cardWidth = cardWidth
            self.columnGap = columnGap
            self.rowGap = rowGap
            self.origin = origin
        }
    }

    /// 테이블 id → 카드 영역
    public static func frames(_ model: DataModel, options: Options = Options(),
                              cardHeight: (ModelTable) -> CGFloat) -> [UUID: CGRect] {
        let ids = Set(model.tables.map(\.id))
        let rels = model.relations.filter { $0.parent != $0.child && ids.contains($0.parent) && ids.contains($0.child) }
        var parents: [UUID: [UUID]] = [:]
        var connected = Set<UUID>()
        for r in rels {
            parents[r.child, default: []].append(r.parent)
            connected.insert(r.parent)
            connected.insert(r.child)
        }
        let order = model.tables.map(\.id).filter { connected.contains($0) }

        // 단계 = 1 + 부모 단계의 최대값 (순환은 반복 횟수로 끊는다)
        var level: [UUID: Int] = Dictionary(uniqueKeysWithValues: order.map { ($0, 0) })
        for _ in 0..<max(order.count, 1) {
            var changed = false
            for id in order {
                let l = (parents[id] ?? []).compactMap { level[$0] }.max().map { $0 + 1 } ?? 0
                if l > level[id]! && l < order.count { level[id] = l; changed = true }
            }
            if !changed { break }
        }
        let maxLevel = level.values.max() ?? -1
        var columns: [[UUID]] = maxLevel >= 0 ? (0...maxLevel).map { l in order.filter { level[$0] == l } } : []
        // 같은 열 안 순서: 부모들의 위치 평균 (두 번 다듬기)
        for _ in 0..<2 where columns.count > 1 {
            for l in 1..<columns.count {
                var pos: [UUID: Double] = [:]
                for prev in columns[..<l] { for (i, id) in prev.enumerated() { pos[id] = Double(i) } }
                let keyed = columns[l].enumerated().map { i, id -> (UUID, Double, Int) in
                    let ps = (parents[id] ?? []).compactMap { pos[$0] }
                    return (id, ps.isEmpty ? Double(i) : ps.reduce(0, +) / Double(ps.count), i)
                }
                columns[l] = keyed.sorted { $0.1 != $1.1 ? $0.1 < $1.1 : $0.2 < $1.2 }.map(\.0)
            }
        }

        let byID = Dictionary(model.tables.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let w = options.cardWidth
        var result: [UUID: CGRect] = [:]
        var bottom = options.origin.y
        for (l, col) in columns.enumerated() {
            var y = options.origin.y
            for id in col {
                guard let t = byID[id] else { continue }
                let h = cardHeight(t)
                result[id] = CGRect(x: options.origin.x + CGFloat(l) * (w + options.columnGap), y: y, width: w, height: h)
                y += h + options.rowGap
            }
            bottom = max(bottom, y)
        }

        // 관계 없는 테이블: 격자 (관계 그림이 있으면 그 아래에 한 칸 더 띄워서)
        let loose = model.tables.filter { !connected.contains($0.id) }
        if !loose.isEmpty {
            let perRow = max(columns.count, Int(Double(loose.count).squareRoot().rounded(.up)), 1)
            var top = result.isEmpty ? options.origin.y : bottom + options.rowGap
            var i = 0
            while i < loose.count {
                let row = loose[i..<min(i + perRow, loose.count)]
                var rowHeight: CGFloat = 0
                for (c, t) in row.enumerated() {
                    let h = cardHeight(t)
                    result[t.id] = CGRect(x: options.origin.x + CGFloat(c) * (w + options.columnGap), y: top, width: w, height: h)
                    rowHeight = max(rowHeight, h)
                }
                top += rowHeight + options.rowGap
                i += perRow
            }
        }
        return result
    }
}
