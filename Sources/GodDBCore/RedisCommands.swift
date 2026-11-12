import Foundation

/// Redis 명령 분류와 자동완성용 목록
public enum RedisCommands {
    /// 데이터를 바꾸지 않는 명령 (읽기전용 접속에서 허용)
    static let readOnly: Set<String> = [
        "GET", "MGET", "STRLEN", "GETRANGE", "SUBSTR", "LCS", "EXISTS", "TYPE", "TTL", "PTTL", "EXPIRETIME", "PEXPIRETIME",
        "KEYS", "SCAN", "RANDOMKEY", "DUMP", "TOUCH",
        "HGET", "HMGET", "HGETALL", "HKEYS", "HVALS", "HLEN", "HEXISTS", "HSCAN", "HSTRLEN", "HRANDFIELD", "HTTL", "HPTTL",
        "LRANGE", "LLEN", "LINDEX", "LPOS",
        "SMEMBERS", "SISMEMBER", "SMISMEMBER", "SCARD", "SSCAN", "SRANDMEMBER", "SINTER", "SUNION", "SDIFF", "SINTERCARD",
        "ZRANGE", "ZRANGEBYSCORE", "ZREVRANGE", "ZREVRANGEBYSCORE", "ZRANGEBYLEX", "ZREVRANGEBYLEX", "ZSCORE", "ZMSCORE",
        "ZCARD", "ZCOUNT", "ZLEXCOUNT", "ZRANK", "ZREVRANK", "ZSCAN", "ZRANDMEMBER", "ZINTER", "ZUNION", "ZDIFF", "ZINTERCARD",
        "XRANGE", "XREVRANGE", "XLEN", "XINFO", "XPENDING", "XREAD",
        "GETBIT", "BITCOUNT", "BITPOS", "BITFIELD_RO", "PFCOUNT",
        "GEOPOS", "GEODIST", "GEOHASH", "GEORADIUS_RO", "GEORADIUSBYMEMBER_RO", "GEOSEARCH",
        "OBJECT", "MEMORY", "INFO", "DBSIZE", "PING", "ECHO", "TIME", "SELECT", "LASTSAVE", "ROLE", "COMMAND", "LOLWUT",
        "PUBSUB", "JSON.GET", "JSON.MGET", "JSON.TYPE", "JSON.STRLEN", "JSON.ARRLEN", "JSON.OBJKEYS", "JSON.OBJLEN",
        "FT.SEARCH", "FT.INFO", "FT._LIST", "FT.AGGREGATE",
    ]

    /// 하위 명령까지 봐야 하는 것: 허용하는 하위 명령
    static let readOnlySub: [String: Set<String>] = [
        "CONFIG": ["GET"],
        "CLIENT": ["LIST", "INFO", "GETNAME", "ID"],
        "SLOWLOG": ["GET", "LEN"],
        "CLUSTER": ["INFO", "NODES", "SLOTS", "SHARDS", "KEYSLOT", "COUNTKEYSINSLOT", "MYID"],
        "ACL": ["WHOAMI", "LIST", "USERS", "CAT", "GETUSER"],
        "LATENCY": ["LATEST", "HISTORY", "DOCTOR"],
        "FUNCTION": ["LIST", "STATS"],
        "SCRIPT": ["EXISTS"],
    ]

    public static func isReadOnly(_ args: [String]) -> Bool {
        guard let name = args.first?.uppercased() else { return true }
        if let subs = readOnlySub[name] {
            return args.count > 1 && subs.contains(args[1].uppercased())
        }
        // XREADGROUP 은 읽지만 소비 그룹 상태를 바꾼다
        return readOnly.contains(name)
    }

    public static let subscribeCommands: Set<String> = ["SUBSCRIBE", "PSUBSCRIBE", "SSUBSCRIBE", "MONITOR"]

    /// 실행 전에 한 번 더 확인할 명령 (전부 지우기, 서버 멈춤, 무거운 KEYS)
    public static func isDangerous(_ args: [String]) -> Bool {
        guard let name = args.first?.uppercased() else { return false }
        if ["FLUSHALL", "FLUSHDB", "SHUTDOWN", "DEBUG", "SWAPDB", "MIGRATE", "REPLICAOF", "SLAVEOF", "FAILOVER"].contains(name) {
            return true
        }
        if name == "KEYS" { return true }
        if name == "CONFIG", args.count > 1, ["SET", "RESETSTAT", "REWRITE"].contains(args[1].uppercased()) { return true }
        if name == "SCRIPT" || name == "FUNCTION", args.count > 1, args[1].uppercased() == "FLUSH" { return true }
        return false
    }

    /// 자동완성: 명령 이름 → 인자 안내
    public static let hints: [String: String] = [
        "GET": "key", "SET": "key value [EX seconds|PX ms] [NX|XX]", "MGET": "key [key …]", "MSET": "key value [key value …]",
        "DEL": "key [key …]", "UNLINK": "key [key …]", "EXISTS": "key [key …]", "TYPE": "key", "RENAME": "key newkey",
        "EXPIRE": "key seconds", "PEXPIRE": "key milliseconds", "PERSIST": "key", "TTL": "key", "PTTL": "key",
        "INCR": "key", "INCRBY": "key increment", "DECR": "key", "APPEND": "key value", "STRLEN": "key", "GETRANGE": "key start end",
        "SCAN": "cursor [MATCH pattern] [COUNT n] [TYPE type]", "KEYS": "pattern", "RANDOMKEY": "",
        "HGET": "key field", "HSET": "key field value [field value …]", "HGETALL": "key", "HDEL": "key field [field …]",
        "HKEYS": "key", "HVALS": "key", "HLEN": "key", "HEXISTS": "key field", "HINCRBY": "key field increment",
        "HSCAN": "key cursor [MATCH pattern] [COUNT n]", "HMGET": "key field [field …]",
        "LPUSH": "key element [element …]", "RPUSH": "key element [element …]", "LPOP": "key [count]", "RPOP": "key [count]",
        "LRANGE": "key start stop", "LLEN": "key", "LINDEX": "key index", "LSET": "key index element", "LREM": "key count element",
        "LTRIM": "key start stop",
        "SADD": "key member [member …]", "SREM": "key member [member …]", "SMEMBERS": "key", "SISMEMBER": "key member",
        "SCARD": "key", "SSCAN": "key cursor [MATCH pattern] [COUNT n]", "SINTER": "key [key …]", "SUNION": "key [key …]",
        "ZADD": "key score member [score member …]", "ZREM": "key member [member …]", "ZRANGE": "key start stop [BYSCORE|BYLEX] [REV] [WITHSCORES]",
        "ZSCORE": "key member", "ZCARD": "key", "ZINCRBY": "key increment member", "ZRANK": "key member", "ZCOUNT": "key min max",
        "ZRANGEBYSCORE": "key min max [WITHSCORES] [LIMIT offset count]", "ZREVRANGE": "key start stop [WITHSCORES]",
        "XADD": "key [MAXLEN ~ n] *|id field value [field value …]", "XRANGE": "key start end [COUNT n]",
        "XREVRANGE": "key end start [COUNT n]", "XLEN": "key", "XDEL": "key id [id …]", "XTRIM": "key MAXLEN [~] n",
        "XREAD": "[COUNT n] [BLOCK ms] STREAMS key [key …] id [id …]",
        "XREADGROUP": "GROUP group consumer [COUNT n] [BLOCK ms] STREAMS key [key …] > [> …]",
        "XGROUP": "CREATE key group id|$ [MKSTREAM] | DESTROY key group | SETID key group id",
        "XACK": "key group id [id …]", "XPENDING": "key group [start end count [consumer]]",
        "XCLAIM": "key group consumer min-idle-time id [id …]", "XAUTOCLAIM": "key group consumer min-idle-time start [COUNT n]",
        "XINFO": "STREAM key | GROUPS key | CONSUMERS key group",
        "PUBLISH": "channel message", "PUBSUB": "CHANNELS [pattern] | NUMSUB [channel …] | NUMPAT",
        "INFO": "[section]", "DBSIZE": "", "PING": "[message]", "SELECT": "index", "TIME": "", "CLIENT": "LIST | INFO | KILL …",
        "CONFIG": "GET parameter | SET parameter value", "SLOWLOG": "GET [n] | LEN | RESET", "MEMORY": "USAGE key | STATS",
        "OBJECT": "ENCODING key | IDLETIME key | FREQ key", "FLUSHDB": "[ASYNC]", "FLUSHALL": "[ASYNC]",
        "EVAL": "script numkeys [key …] [arg …]", "MULTI": "", "EXEC": "", "DISCARD": "", "WATCH": "key [key …]",
        "SETEX": "key seconds value", "SETNX": "key value", "GETDEL": "key", "GETEX": "key [EX seconds|PERSIST]",
        "COPY": "source destination [REPLACE]", "DUMP": "key", "TOUCH": "key [key …]",
        "PFADD": "key element [element …]", "PFCOUNT": "key [key …]",
        "GEOADD": "key longitude latitude member", "GEOSEARCH": "key FROMMEMBER member|FROMLONLAT lon lat BYRADIUS r unit",
    ]

    public static var names: [String] { hints.keys.sorted() }

    /// 입력 중인 첫 단어로 시작하는 명령
    public static func complete(_ prefix: String) -> [String] {
        let p = prefix.uppercased()
        guard !p.isEmpty else { return [] }
        return names.filter { $0.hasPrefix(p) }
    }
}
