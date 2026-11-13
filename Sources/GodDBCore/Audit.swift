import Foundation

/// 감사 로그 한 줄. 로그 파일에는 이것이 있는 항목만 남는다 (상태창에는 모든 항목이 보인다).
/// 파일 형식(탭 구분): 시각 · 사용자@PC · 구분 · 대상 · 결과 · 내용
public struct AuditRecord: Sendable, Hashable {
    public enum Action: String, Sendable, CaseIterable {
        case appStart = "앱시작"
        case connect = "접속"
        case disconnect = "접속해제"
        case read = "조회"
        case insert = "추가"
        case update = "수정"
        case delete = "삭제"
        case ddl = "구조변경"
        case grant = "권한"
        case execute = "실행"
        case export = "내보내기"
        case compare = "비교"
        case ai = "AI"
        case settings = "설정"
    }

    public var action: Action
    /// 접속 이름과 DB (예: "m5s_prd/m5s_db", Redis 는 "redis_dev db0")
    public var target: String
    /// 결과 요약 (예: "1행 · 3ms", "3건", "실패: …")
    public var result: String
    /// 실행한 SQL·명령 (한 줄로 펴서 기록)
    public var statement: String

    public init(_ action: Action, target: String = "", result: String = "", statement: String = "") {
        self.action = action
        self.target = target
        self.result = result
        self.statement = statement
    }

    /// 파일 열 머리글
    public static let header = ["시각", "사용자@PC", "구분", "대상", "결과", "내용"]

    /// SQL 의 구분. 여러 문장이면 첫 문장 기준 (스크립트는 문장마다 따로 기록한다).
    public static func classify(sql: String) -> Action {
        let body = SQLText.stripComments(sql)
        let kw = SQLText.firstKeyword(body)
        switch kw {
        case "SELECT", "SHOW", "DESC", "DESCRIBE", "EXPLAIN", "VALUES", "TABLE": return .read
        case "WITH":
            // WITH … INSERT/UPDATE/DELETE (PostgreSQL 등)
            let upper = body.uppercased()
            if upper.range(of: "\\)\\s*DELETE\\b", options: .regularExpression) != nil { return .delete }
            if upper.range(of: "\\)\\s*UPDATE\\b", options: .regularExpression) != nil { return .update }
            if upper.range(of: "\\)\\s*INSERT\\b", options: .regularExpression) != nil { return .insert }
            return .read
        case "INSERT": return .insert
        case "UPDATE", "REPLACE", "MERGE", "UPSERT": return .update
        case "DELETE", "TRUNCATE": return .delete
        case "CREATE", "ALTER", "DROP", "RENAME", "COMMENT": return .ddl
        case "GRANT", "REVOKE": return .grant
        default: return .execute
        }
    }

    private static let redisRead: Set<String> = [
        "GET", "MGET", "GETRANGE", "STRLEN", "EXISTS", "TYPE", "TTL", "PTTL", "SCAN", "KEYS", "HGET", "HMGET", "HGETALL",
        "HKEYS", "HVALS", "HLEN", "HSCAN", "HEXISTS", "LRANGE", "LLEN", "LINDEX", "SMEMBERS", "SCARD", "SISMEMBER", "SSCAN",
        "ZRANGE", "ZREVRANGE", "ZRANGEBYSCORE", "ZCARD", "ZSCORE", "ZRANK", "ZSCAN", "XRANGE", "XREVRANGE", "XLEN", "XINFO",
        "XPENDING", "XREAD", "INFO", "DBSIZE", "MEMORY", "OBJECT", "DUMP", "RANDOMKEY", "PING", "SELECT", "CLIENT", "CONFIG GET",
        "SLOWLOG", "LASTSAVE", "ROLE", "CLUSTER", "COMMAND", "PUBSUB", "SUBSCRIBE", "PSUBSCRIBE",
    ]
    private static let redisDelete: Set<String> = [
        "DEL", "UNLINK", "HDEL", "LREM", "LPOP", "RPOP", "SREM", "SPOP", "ZREM", "ZREMRANGEBYSCORE", "ZREMRANGEBYRANK",
        "XDEL", "XTRIM", "FLUSHDB", "FLUSHALL", "GETDEL", "PERSIST",
    ]

    /// Redis 명령의 구분
    public static func classify(redis args: [String]) -> Action {
        guard let first = args.first?.uppercased() else { return .execute }
        if first == "CONFIG", let sub = args.dropFirst().first?.uppercased() { return sub == "GET" ? .read : .settings }
        if redisRead.contains(first) { return .read }
        if redisDelete.contains(first) { return .delete }
        if ["PUBLISH", "EVAL", "EVALSHA", "FUNCTION", "SCRIPT", "SAVE", "BGSAVE", "SHUTDOWN"].contains(first) { return .execute }
        return .update   // SET, HSET, EXPIRE, RENAME, LPUSH, ZADD, XADD …
    }

    /// 한 칸에 들어가도록: 탭·줄바꿈을 공백으로, 연속 공백 하나로, 너무 길면 자른다
    public static func cell(_ s: String, limit: Int = 20_000) -> String {
        var out = ""
        out.reserveCapacity(min(s.count, limit))
        var lastSpace = false
        for ch in s {
            let space = ch.isWhitespace
            if space {
                if !lastSpace && !out.isEmpty { out.append(" ") }
                lastSpace = true
            } else {
                out.append(ch)
                lastSpace = false
            }
            if out.count >= limit { return out + " …(\(s.count)자 중 일부)" }
        }
        return out.hasSuffix(" ") ? String(out.dropLast()) : out
    }
}
