import Foundation

/// Redis 키를 구분자(기본 ":") 로 나눠 폴더 트리로 만든다. user:1001:name → user › 1001 › name
public struct RedisKeyNode: Identifiable, Equatable, Sendable {
    /// 폴더는 "f:" + 접두어, 키는 "k:" + 키 이름
    public let id: String
    /// 화면에 보일 마지막 조각
    public let name: String
    /// 폴더면 접두어 (구분자 포함 전까지, 예: "user:1001"), 키면 키 전체
    public let path: String
    /// 키면 키 이름, 폴더면 nil
    public let key: String?
    /// 폴더면 하위 노드 (폴더 먼저, 이름순), 키면 nil
    public let children: [RedisKeyNode]?
    /// 폴더 아래 키 개수 (키는 1)
    public let count: Int

    public var isFolder: Bool { key == nil }
}

public enum RedisKeyTree {
    /// 화면에 보이는 한 줄 (펼친 폴더의 하위만 포함). 중첩 DisclosureGroup 대신 평평한 목록으로 그려
    /// SwiftUI(NSOutlineView) 의 펼치기/접기 diff 가 키 목록 갱신과 겹쳐 종료되던 문제를 피한다.
    public struct VisibleRow: Identifiable, Equatable, Sendable {
        public let node: RedisKeyNode
        public let depth: Int
        public var id: String { node.id }
    }

    public static func visibleRows(_ nodes: [RedisKeyNode], expanded: Set<String>, depth: Int = 0) -> [VisibleRow] {
        var out: [VisibleRow] = []
        func walk(_ nodes: [RedisKeyNode], _ depth: Int) {
            for n in nodes {
                out.append(VisibleRow(node: n, depth: depth))
                if let c = n.children, expanded.contains(n.id) { walk(c, depth + 1) }
            }
        }
        walk(nodes, depth)
        return out
    }

    private final class Builder {
        var folders: [String: Builder] = [:]
        var keys: [(name: String, key: String)] = []
        var count = 0
    }

    public static func build(_ keys: [String], delimiter: String = ":") -> [RedisKeyNode] {
        let root = Builder()
        for key in keys {
            let parts = delimiter.isEmpty ? [key] : key.components(separatedBy: delimiter)
            var node = root
            node.count += 1
            // 마지막 조각 전까지는 폴더 (빈 조각도 이름 "" 인 폴더로 둔다: a::b)
            for part in parts.dropLast() {
                let next = node.folders[part] ?? Builder()
                node.folders[part] = next
                node = next
                node.count += 1
            }
            node.keys.append((parts.last ?? key, key))
        }
        return nodes(root, prefix: nil, delimiter: delimiter)
    }

    private static func nodes(_ b: Builder, prefix: String?, delimiter: String) -> [RedisKeyNode] {
        let folders = b.folders.keys.sorted(by: natural).map { name -> RedisKeyNode in
            let path = prefix.map { $0 + delimiter + name } ?? name
            let child = b.folders[name]!
            return RedisKeyNode(id: "f:" + path, name: name, path: path, key: nil,
                                children: nodes(child, prefix: path, delimiter: delimiter), count: child.count)
        }
        let leaves = b.keys.sorted { natural($0.name, $1.name) }.map {
            RedisKeyNode(id: "k:" + $0.key, name: $0.name, path: $0.key, key: $0.key, children: nil, count: 1)
        }
        return folders + leaves
    }

    /// 숫자는 숫자 크기로 (user:2 가 user:10 보다 먼저)
    static func natural(_ a: String, _ b: String) -> Bool {
        a.compare(b, options: [.numeric, .caseInsensitive]) == .orderedAscending
    }

    /// 폴더 아래 키 전체를 찾는 SCAN 패턴 (glob 특수문자는 이스케이프)
    public static func pattern(forFolder path: String, delimiter: String = ":") -> String {
        var out = ""
        for c in path + delimiter {
            if "*?[]\\".contains(c) { out.append("\\") }
            out.append(c)
        }
        return out + "*"
    }
}
