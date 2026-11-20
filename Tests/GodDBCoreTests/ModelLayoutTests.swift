import CoreGraphics
import Foundation
import Testing
@testable import GodDBCore

@Suite("ModelLayout")
struct ModelLayoutTests {
    static func height(_ t: ModelTable) -> CGFloat { 34 + CGFloat(max(t.columns.count, 1)) * 20 + 10 }

    @Test func noOverlapAndParentsLeftOfChildren() {
        var m = DataModel(name: "m")
        let a = m.addTable(logicalName: "A"), b = m.addTable(logicalName: "B"), c = m.addTable(logicalName: "C")
        let d = m.addTable(logicalName: "D")
        _ = m.addTable(logicalName: "E"); _ = m.addTable(logicalName: "F")   // 관계 없음
        // 모두 같은 자리에 겹쳐 놓고, 한 테이블은 컬럼을 아주 많이
        for i in m.tables.indices { m.tables[i].x = 40; m.tables[i].y = 40 }
        let bi = m.tableIndex(b)!
        m.tables[bi].columns += (0..<40).map { ModelColumn(logicalName: "c\($0)", physicalName: "c\($0)") }
        m.addRelation(parent: a, child: b)
        m.addRelation(parent: b, child: c)
        m.addRelation(parent: a, child: d)
        m.addRelation(parent: d, child: c)

        let frames = ModelLayout.frames(m, cardHeight: Self.height)
        #expect(frames.count == m.tables.count)
        let list = Array(frames.values)
        for i in list.indices {
            for j in list.indices where j > i {
                #expect(!list[i].insetBy(dx: -10, dy: -10).intersects(list[j]), "\(list[i]) \(list[j])")
            }
        }
        for t in m.tables { #expect(frames[t.id]!.height == Self.height(t)) }
        for r in m.relations { #expect(frames[r.parent]!.maxX < frames[r.child]!.minX) }
        // 관계 없는 테이블은 관계 그림 아래
        let graphBottom = [a, b, c, d].map { frames[$0]!.maxY }.max()!
        for t in m.tables where ![a, b, c, d].contains(t.id) { #expect(frames[t.id]!.minY > graphBottom) }
    }

    @Test func cycleAndSelfRelationStillLayOut() {
        var m = DataModel(name: "m")
        let a = m.addTable(logicalName: "A"), b = m.addTable(logicalName: "B")
        m.addRelation(parent: a, child: b)
        m.addRelation(parent: b, child: a)
        m.addRelation(parent: a, child: a)
        let frames = ModelLayout.frames(m, cardHeight: Self.height)
        #expect(frames.count == 2)
        #expect(!frames[a]!.intersects(frames[b]!))
    }
}
