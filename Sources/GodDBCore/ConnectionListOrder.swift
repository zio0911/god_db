import Foundation

/// 사이드바 접속 목록 정렬
public enum ConnectionSort: String, CaseIterable, Identifiable, Sendable {
    /// 직접 정한 순 (접속 목록에 저장된 순서 — 새 접속은 맨 아래, 끌거나 메뉴로 옮긴다)
    case manual
    case name
    /// 최근 연결순 (연결한 적 없는 접속은 뒤로, 그 안에서는 이름순)
    case recent
    /// DB 종류순 (MySQL · PostgreSQL · Redshift · SQL Server · Redis), 같은 종류는 이름순
    case type

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .manual: return tr("직접 정한 순")
        case .name: return tr("이름순")
        case .recent: return tr("최근 연결순")
        case .type: return tr("DB 종류순")
        }
    }
}

/// 사이드바 접속 목록: 찾기 · 정렬
public enum ConnectionListOrder {
    /// 찾기: 이름 · 주소 · DB 이름 · 그룹 · DB 종류 · SSH 호스트에 낱말이 모두 들어 있으면 (대소문자 무시)
    public static func matches(_ p: ConnectionProfile, query: String) -> Bool {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        let hay = [p.name, p.host, p.database, p.group, p.typeTitle, p.kind.title, p.kind.rawValue, p.ssh?.host ?? "",
                   p.environment == .none ? "" : p.environment.title]
            .joined(separator: "\n").lowercased()
        return words.allSatisfy { hay.contains($0) }
    }

    /// 정렬한 접속 목록. connectedFirst 면 연결된 접속을 먼저 (그 안의 순서는 sort 를 따른다)
    public static func sorted(_ profiles: [ConnectionProfile], by sort: ConnectionSort,
                              connectedFirst: Bool = false, isConnected: (UUID) -> Bool = { _ in false }) -> [ConnectionProfile] {
        let index = Dictionary(uniqueKeysWithValues: profiles.enumerated().map { ($1.id, $0) })
        func byName(_ a: ConnectionProfile, _ b: ConnectionProfile) -> Bool {
            let r = a.name.localizedStandardCompare(b.name)
            return r == .orderedSame ? index[a.id]! < index[b.id]! : r == .orderedAscending
        }
        func before(_ a: ConnectionProfile, _ b: ConnectionProfile) -> Bool {
            if connectedFirst {
                let ca = isConnected(a.id), cb = isConnected(b.id)
                if ca != cb { return ca }
            }
            switch sort {
            case .manual:
                return index[a.id]! < index[b.id]!
            case .name:
                return byName(a, b)
            case .recent:
                switch (a.lastConnectedAt, b.lastConnectedAt) {
                case let (x?, y?) where x != y: return x > y
                case (_?, nil): return true
                case (nil, _?): return false
                default: return byName(a, b)
                }
            case .type:
                let ka = typeOrder(a), kb = typeOrder(b)
                return ka == kb ? byName(a, b) : ka < kb
            }
        }
        return profiles.sorted(by: before)
    }

    /// 그룹 순서: 이름순 · DB 종류순은 그룹 이름순, 직접 정한 순은 그룹이 처음 나온 순서, 최근 연결순은 가장 최근 연결한 접속 순
    public static func sortedGroups(_ profiles: [ConnectionProfile], by sort: ConnectionSort) -> [String] {
        var first: [String: Int] = [:]
        var latest: [String: Date] = [:]
        for (i, p) in profiles.enumerated() where !p.group.isEmpty {
            if first[p.group] == nil { first[p.group] = i }
            if let d = p.lastConnectedAt, d > (latest[p.group] ?? .distantPast) { latest[p.group] = d }
        }
        func byName(_ a: String, _ b: String) -> Bool { a.localizedStandardCompare(b) == .orderedAscending }
        return first.keys.sorted { a, b in
            switch sort {
            case .name, .type: return byName(a, b)
            case .manual: return first[a]! < first[b]!
            case .recent:
                let x = latest[a] ?? .distantPast, y = latest[b] ?? .distantPast
                return x == y ? byName(a, b) : x > y
            }
        }
    }

    /// 화면에 보이는 순서 그대로 (그룹 없는 접속 → 그룹별). 직접 옮기기 전에 이 순서를 저장 순서로 굳힌다
    public static func visibleOrder(_ profiles: [ConnectionProfile], by sort: ConnectionSort,
                                    connectedFirst: Bool = false, isConnected: (UUID) -> Bool = { _ in false }) -> [ConnectionProfile] {
        let s = sorted(profiles, by: sort, connectedFirst: connectedFirst, isConnected: isConnected)
        return s.filter { $0.group.isEmpty } + sortedGroups(profiles, by: sort).flatMap { g in s.filter { $0.group == g } }
    }

    public enum Move: Sendable { case up, down, top, bottom }

    /// 같은 그룹 안에서 위 · 아래 · 맨 위 · 맨 아래로 (저장 순서 기준). 못 옮기면 그대로
    public static func moved(_ profiles: [ConnectionProfile], _ id: UUID, _ move: Move) -> [ConnectionProfile] {
        guard let i = profiles.firstIndex(where: { $0.id == id }) else { return profiles }
        let group = profiles[i].group
        let same = profiles.indices.filter { profiles[$0].group == group }
        guard let k = same.firstIndex(of: i) else { return profiles }
        let target: Int
        switch move {
        case .up: guard k > 0 else { return profiles }; target = same[k - 1]
        case .down: guard k < same.count - 1 else { return profiles }; target = same[k + 1]
        case .top: guard k > 0 else { return profiles }; target = same[0]
        case .bottom: guard k < same.count - 1 else { return profiles }; target = same[same.count - 1]
        }
        var out = profiles
        let p = out.remove(at: i)
        out.insert(p, at: target)
        return out
    }

    /// 끌어다 놓기: id 를 target 바로 앞으로 옮기고 target 의 그룹으로 넣는다
    public static func moved(_ profiles: [ConnectionProfile], _ id: UUID, before target: UUID) -> [ConnectionProfile] {
        guard id != target, let i = profiles.firstIndex(where: { $0.id == id }) else { return profiles }
        var out = profiles
        var p = out.remove(at: i)
        guard let t = out.firstIndex(where: { $0.id == target }) else { return profiles }
        p.group = out[t].group
        out.insert(p, at: t)
        return out
    }

    /// DB 종류 순서: 새 접속 화면과 같은 MySQL · PostgreSQL · Redshift · SQL Server · Redis
    static func typeOrder(_ p: ConnectionProfile) -> Int { ConnectionType.allCases.firstIndex(of: p.type) ?? 0 }
}
