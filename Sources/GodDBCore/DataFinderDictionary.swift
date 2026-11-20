import Foundation

/// AI 데이터 찾기에 쓰는 한국어 ↔ 영어 DB 약어 사전 (명세 docs/specs/1.4.0.md · F7).
/// 공공 · 기업 DB 에서 흔한 이름 짓기(예: 학년 → grade · grd · schyr)를 데이터로 둔다.
/// AI 가 없어도 "학년" 으로 `schyr` 를 찾고, AI 에게 보낼 테이블을 미리 고르는 데 쓴다.
public struct AbbreviationEntry: Sendable, Equatable {
    /// 한국어 말 (질문 · 코멘트에서 찾는다)
    public let korean: [String]
    /// 영어 이름 · 약어 (이름 조각과 똑같으면 일치)
    public let english: [String]
    /// 흔해서 다른 뜻과 겹치기 쉬운 약어 (일치해도 점수 절반)
    public let weak: [String]
    /// 번호 · 코드 · 이름처럼 어디에나 붙는 말이면 가중치를 낮춘다
    public let generic: Bool
    /// 값 모양 (정규식, 대소문자 무시). 샘플 값 대부분이 맞으면 그 컬럼을 더 믿는다.
    public let valuePattern: String?

    public init(_ korean: [String], _ english: [String], weak: [String] = [], generic: Bool = false,
                values valuePattern: String? = nil) {
        self.korean = korean
        self.english = english
        self.weak = weak
        self.generic = generic
        self.valuePattern = valuePattern
    }

    /// 점수 가중치
    public var weight: Double { generic ? 0.5 : 1 }
}

public enum AbbreviationDictionary {
    static let gradeValues = #"^(0?[1-9]|1[0-2])\s*(학년)?$"#
    static let dateValues = #"^\d{4}[-./]?\d{2}[-./]?\d{2}"#
    static let ynValues = #"^(y|n|0|1|true|false|t|f)$"#

    /// 사전 (약 70개). 새 말은 여기에만 더하면 된다.
    public static let entries: [AbbreviationEntry] = [
        // 학교 · 교육
        .init(["학년"], ["grade", "grd", "schyr", "schlyr", "grde"], weak: ["gr", "yr"], values: gradeValues),
        .init(["학교"], ["school", "sch", "schl"]),
        .init(["학생"], ["student", "std", "stdnt", "stu", "pupil"]),
        .init(["교사", "선생님", "선생", "강사"], ["teacher", "tchr", "tch", "instructor", "inst"]),
        .init(["반", "학급"], ["class", "cls", "ban", "clss", "classroom"]),
        .init(["과목", "교과"], ["subject", "subj", "sbj", "course", "crs"]),
        .init(["학기"], ["semester", "sem", "term", "smstr"]),
        .init(["성적", "점수"], ["score", "scr", "point", "pnt", "mark"]),
        .init(["출석", "출결"], ["attend", "attendance", "atnd", "att"]),
        .init(["학부모", "보호자", "부모"], ["parent", "guardian", "prnt", "grdn"]),
        .init(["입학"], ["admission", "enter", "entr", "adm"]),
        .init(["졸업"], ["graduate", "graduation", "grad", "grdt"]),
        // 사람 · 회원
        .init(["회원", "고객", "사용자"], ["member", "mbr", "mem", "user", "usr", "cust", "customer", "client"]),
        .init(["직원", "사원"], ["employee", "emp", "staff", "empl"]),
        .init(["이름", "성명", "명칭", "명"], ["name", "nm"], generic: true),
        .init(["아이디", "계정"], ["id", "login", "account", "acct", "userid", "loginid"], generic: true),
        .init(["비밀번호", "암호"], ["pwd", "passwd", "password", "pw", "pass"]),
        .init(["생년월일", "생일"], ["birth", "brth", "bday", "birthday", "birthdt", "bir"], values: dateValues),
        .init(["나이", "연령"], ["age"]),
        .init(["성별"], ["gender", "sex", "gndr"], values: #"^(m|f|male|female|남|여|남자|여자|1|2)$"#),
        .init(["전화", "연락처", "휴대폰", "핸드폰", "전화번호"], ["phone", "tel", "mobile", "hp", "cell", "telno", "phn", "mbl"],
              values: #"^\+?\d{2,3}[- ]?\d{3,4}[- ]?\d{4}$"#),
        .init(["주소"], ["addr", "address", "adr"]),
        .init(["우편번호"], ["zip", "zipcode", "post", "postcode", "zipcd"], values: #"^\d{3}-?\d{2,3}$"#),
        .init(["이메일", "메일"], ["email", "mail", "eml"], values: #"^[^@\s]+@[^@\s]+$"#),
        .init(["국적", "국가", "나라"], ["nation", "country", "ntn", "cntry"]),
        .init(["직업"], ["job", "occupation", "occp"]),
        .init(["부서"], ["dept", "department", "dpt"]),
        .init(["직급", "직위", "직책"], ["position", "rank", "pos", "title", "jbgd"]),
        // 조직 · 지역
        .init(["지역"], ["region", "area", "rgn", "zone"]),
        .init(["지점", "센터", "영업소"], ["branch", "center", "brnc", "brch", "cntr", "office", "ofc"]),
        .init(["회사", "업체", "거래처"], ["company", "comp", "corp", "vendor", "vndr", "partner", "cmpy"]),
        .init(["본부", "사업부"], ["division", "div", "hq"]),
        // 일반 속성
        .init(["번호", "순번", "일련번호"], ["no", "num", "seq", "sn", "number", "nbr"], generic: true),
        .init(["코드"], ["cd", "code"], generic: true),
        .init(["유형", "종류", "구분"], ["type", "typ", "kind", "gb", "div", "cls"], generic: true),
        .init(["일자", "날짜", "날"], ["date", "dt", "ymd", "day"], generic: true, values: dateValues),
        .init(["일시", "시각", "시간"], ["dtm", "datetime", "ts", "time", "tm", "dttm"], generic: true),
        .init(["년도", "연도"], ["year", "yr", "yy", "yyyy"], values: #"^(19|20)\d{2}$"#),
        .init(["월"], ["month", "mon", "mm", "mth"]),
        .init(["상태"], ["status", "stat", "sts", "state", "stt"]),
        .init(["여부"], ["yn", "flag", "fl", "flg", "is"], generic: true, values: ynValues),
        .init(["사용"], ["use", "used", "usg"]),
        .init(["등록"], ["reg", "regist", "register", "registered", "rgst", "create", "created", "crt"]),
        .init(["수정", "변경"], ["upd", "mod", "update", "updated", "modify", "chg", "change"]),
        .init(["삭제"], ["del", "delete", "deleted"]),
        .init(["시작"], ["start", "strt", "begin", "bgn", "from", "st"]),
        .init(["종료", "끝"], ["end", "fin", "finish", "to", "ed", "close"]),
        .init(["내용", "설명", "비고"], ["content", "cont", "desc", "description", "remark", "rmk", "note", "memo", "cn"],
              generic: true),
        .init(["제목"], ["title", "ttl", "subject", "subj", "sj"]),
        .init(["메모"], ["memo", "note", "remark", "rmk"]),
        .init(["순서", "정렬"], ["order", "ord", "sort", "srt", "seq"], generic: true),
        .init(["개수", "건수", "횟수"], ["count", "cnt"]),
        .init(["합계", "총"], ["total", "tot", "sum"]),
        .init(["비율", "율"], ["rate", "ratio", "rt", "pct", "percent"]),
        .init(["이미지", "사진"], ["image", "img", "photo", "pic"]),
        .init(["파일", "첨부"], ["file", "attach", "atch"]),
        .init(["로그", "이력", "기록"], ["log", "hist", "history", "his"]),
        .init(["권한", "역할"], ["auth", "role", "perm", "permission", "grant"]),
        .init(["설정"], ["config", "conf", "setting", "set", "cfg"]),
        // 상거래 · 돈
        .init(["주문"], ["order", "ord", "orders"]),
        .init(["상품", "제품", "물품"], ["product", "prod", "item", "goods", "gds", "prdt", "prd"]),
        .init(["결제"], ["pay", "payment", "pymt", "stl", "settle"]),
        .init(["금액", "가격", "단가", "요금"], ["amt", "amount", "price", "prc", "cost", "fee"]),
        .init(["수량"], ["qty", "quantity", "cnt"]),
        .init(["배송", "배달"], ["delivery", "dlvr", "ship", "shipping", "dlv"]),
        .init(["장바구니"], ["cart", "basket"]),
        .init(["쿠폰"], ["coupon", "cpn"]),
        .init(["포인트", "적립금"], ["point", "pnt", "pt", "mileage", "reward"]),
        .init(["환불"], ["refund", "rfnd"]),
        .init(["계좌", "은행"], ["account", "acct", "bank", "bnk"]),
        .init(["카드"], ["card", "crd"]),
        .init(["계약"], ["contract", "cntrc", "ctrt"]),
        .init(["매출", "판매"], ["sales", "sale", "sell", "sls"]),
        .init(["재고"], ["stock", "inventory", "inv", "stk"]),
        .init(["게시판", "게시글", "글"], ["board", "bbs", "post", "article", "brd"]),
        .init(["댓글"], ["comment", "reply", "cmt", "rply"]),
        .init(["공지"], ["notice", "ntc", "announce"]),
        .init(["문의"], ["inquiry", "inq", "qna", "question"]),
        .init(["알림"], ["alarm", "notify", "noti", "notification", "push", "alrm"]),
    ]

    // MARK: - 이름 조각

    /// 이름을 조각으로: `_` · `-` · `.` · 공백 · 숫자 경계 · camelCase 로 나누고 소문자로.
    /// `tb_stdnt_info` → [tb, stdnt, info], `StdntNm` → [stdnt, nm], `schyr` → [schyr]
    public static func tokens(_ name: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var prev: Character?
        func flush() {
            if !cur.isEmpty { out.append(cur.lowercased()) }
            cur = ""
        }
        let chars = Array(name)
        for (i, ch) in chars.enumerated() {
            if !(ch.isLetter || ch.isNumber) || ch == "_" {
                flush(); prev = nil; continue
            }
            if let p = prev {
                let next = i + 1 < chars.count ? chars[i + 1] : nil
                let lowerToUpper = p.isLowercase && ch.isUppercase
                // "HTTPServer" → HTTP | Server
                let acronymEnd = p.isUppercase && ch.isUppercase && (next?.isLowercase ?? false)
                let digitEdge = p.isNumber != ch.isNumber
                if lowerToUpper || acronymEnd || digitEdge { flush() }
            }
            cur.append(ch)
            prev = ch
        }
        flush()
        return out
    }

    // MARK: - 질문 말 → 사전 항목

    /// 질문 핵심어 하나에 맞는 사전 항목. 사전 말과 똑같으면 그것만, 아니면 핵심어 안에 든 사전 말들
    /// (긴 것부터, 겹치지 않게): "전화번호" → 전화 (사전에 그대로), "학생이름" → 학생 + 이름.
    /// 영어 핵심어는 영어 약어와 같으면 그 항목.
    public static func concepts(for term: String) -> [AbbreviationEntry] {
        let t = term.lowercased()
        if let exact = entries.first(where: { $0.korean.contains(t) }) { return [exact] }
        if !DataFinder.isHangul(t) {
            return entries.filter { $0.english.contains(t) }
        }
        // 핵심어 안의 사전 말 (긴 것부터, 이미 덮인 글자는 빼고)
        var covered = Array(repeating: false, count: t.count)
        var found: [(pos: Int, entry: AbbreviationEntry)] = []
        let words = entries.flatMap { e in e.korean.filter { $0.count >= 2 }.map { (word: $0, entry: e) } }
            .sorted { $0.word.count > $1.word.count }
        let chars = Array(t)
        for w in words {
            let wc = Array(w.word)
            guard wc.count <= chars.count else { continue }
            for start in 0...(chars.count - wc.count) where Array(chars[start..<start + wc.count]) == wc {
                guard !covered[start..<start + wc.count].contains(true) else { continue }
                for i in start..<start + wc.count { covered[i] = true }
                if !found.contains(where: { $0.entry == w.entry }) { found.append((start, w.entry)) }
            }
        }
        return found.sorted { $0.pos < $1.pos }.map(\.entry)
    }

    /// 질문 핵심어를 영어 이름으로 넓힌 글 (AI 에게 함께 보낸다): `학년 → grade, grd, schyr, schlyr, grde, gr, yr`
    public static func expansionText(terms: [String]) -> String {
        terms.compactMap { term -> String? in
            let words = concepts(for: term).flatMap { $0.english + $0.weak }
            guard !words.isEmpty else { return nil }
            var seen = Set<String>()
            return "\(term) → " + words.filter { seen.insert($0).inserted }.joined(separator: ", ")
        }.joined(separator: "\n")
    }

    // MARK: - 일치

    /// 이름 조각이 이 항목과 맞는 정도: 1 (같음) · 0.5 (약한 약어, 또는 4글자 이상 영어 말로 시작하는 붙은 조각) · 0
    static func match(_ entry: AbbreviationEntry, tokens: [String]) -> Double {
        var best = 0.0
        for tok in tokens {
            if entry.english.contains(tok) { return 1 }
            if entry.weak.contains(tok) { best = max(best, 0.5) }
            // 붙여 쓴 이름: "gradecd", "telno" … 4글자 이상 영어 말만 (짧은 약어는 잘못 맞기 쉽다)
            if tok.count > 4, entry.english.contains(where: { $0.count >= 4 && tok.hasPrefix($0) }) { best = max(best, 0.5) }
        }
        return best
    }

    /// 코멘트에 이 항목의 한국어 말 또는 영어 말이 있는지
    static func matchComment(_ entry: AbbreviationEntry, comment: String) -> Bool {
        let c = comment.lowercased()
        guard !c.isEmpty else { return false }
        if entry.korean.contains(where: { $0.count >= 2 && c.contains($0) }) { return true }
        let words = Set(tokens(c))
        return entry.english.contains(where: { $0.count >= 3 && words.contains($0) })
    }

    // MARK: - 값 모양

    /// 샘플 값이 질문 말의 값 모양과 맞는 정도 (-1…1). 모양이 없거나 값이 적으면 0.
    /// 대부분(80% 이상) 맞으면 1, 하나도 안 맞으면 -1.
    public static func valueFit(terms: [String], samples: [String]) -> Double {
        let patterns = terms.flatMap(concepts(for:)).compactMap(\.valuePattern)
        guard !patterns.isEmpty, samples.count >= 2 else { return 0 }
        var best = -1.0
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p, options: [.caseInsensitive]) else { continue }
            let hits = samples.filter { s in
                let v = s.trimmingCharacters(in: .whitespaces)
                return re.firstMatch(in: v, range: NSRange(location: 0, length: (v as NSString).length)) != nil
            }.count
            let ratio = Double(hits) / Double(samples.count)
            best = max(best, ratio >= 0.8 ? 1 : ratio > 0 ? 0 : -1)
        }
        return best
    }

    /// 값 모양 안내 (AI 판단 글에 함께): 맞으면 "values look like 학년", 안 맞으면 "values do not look like 학년"
    public static func valueHintText(terms: [String], samples: [String]) -> String? {
        let named = terms.filter { t in concepts(for: t).contains { $0.valuePattern != nil } }
        guard !named.isEmpty else { return nil }
        switch valueFit(terms: terms, samples: samples) {
        case 1: return "values look like \(named.joined(separator: ", "))"
        case -1: return "values do not look like \(named.joined(separator: ", "))"
        default: return nil
        }
    }
}

// MARK: - 점수 (AI 없이 후보 만들기 · AI 에 보낼 테이블 미리 고르기)

extension DataFinder {
    /// 컬럼 하나의 점수와 맞은 이유
    public struct ColumnScore: Equatable, Sendable {
        public var table: String
        public var column: String
        public var score: Double
    }

    /// 질문 핵심어로 테이블 · 컬럼 점수 매기기. 핵심어마다:
    /// - 컬럼: 핵심어가 코멘트에 그대로 4 · 이름 조각과 같음(영어 질문) 3, 사전 항목이 이름 조각 · 코멘트와 맞음 3 × 가중치
    ///   (약한 약어 · 붙여 쓴 이름은 절반). 둘 중 큰 값.
    /// - 테이블 이름 · 코멘트가 핵심어(또는 그 사전 항목)와 맞으면 2 × 가중치 더한다.
    /// 컬럼 자체가 하나도 안 맞으면 후보가 아니다. 이름 조각 중 맞은 조각 비율 × 0.5 를 더해
    /// 같은 점수면 군더더기 없는 이름(`schyr`)이 `mbr_grd_cd` 보다 앞선다.
    public static func scoreColumns(terms: [String], tables: [TableMeta]) -> [ColumnScore] {
        let qs = terms.map { $0.lowercased() }.filter { !$0.isEmpty }
        guard !qs.isEmpty else { return [] }
        let conceptsByTerm = qs.map { AbbreviationDictionary.concepts(for: $0) }
        var out: [ColumnScore] = []
        for t in tables {
            let tTokens = AbbreviationDictionary.tokens(t.name)
            let tComment = t.comment.lowercased()
            // 핵심어마다 테이블 자체가 맞는 점수
            let tableScores: [Double] = qs.enumerated().map { i, q in
                if (!tComment.isEmpty && tComment.contains(q)) || tTokens.contains(q) { return 2 }
                return conceptsByTerm[i].map { e in
                    2 * e.weight * max(AbbreviationDictionary.match(e, tokens: tTokens),
                                       AbbreviationDictionary.matchComment(e, comment: tComment) ? 1 : 0)
                }.max() ?? 0
            }
            for col in t.columns {
                let cTokens = AbbreviationDictionary.tokens(col.name)
                let cComment = col.comment.lowercased()
                var own = 0.0
                var total = 0.0
                for (i, q) in qs.enumerated() {
                    var direct = 0.0
                    if !cComment.isEmpty, cComment.contains(q) {
                        direct = 4
                    } else if !DataFinder.isHangul(q), cTokens.contains(q) || (q.count >= 4 && normalize(col.name).contains(q)) {
                        direct = 3
                    }
                    var concept = 0.0
                    for e in conceptsByTerm[i] {
                        let m = max(AbbreviationDictionary.match(e, tokens: cTokens),
                                    AbbreviationDictionary.matchComment(e, comment: cComment) ? 1 : 0)
                        concept += 3 * e.weight * m
                    }
                    let termOwn = max(direct, concept)
                    own += termOwn
                    total += termOwn + tableScores[i]
                }
                guard own > 0 else { continue }
                let allConcepts = conceptsByTerm.flatMap { $0 }
                let matched = cTokens.filter { tok in
                    qs.contains(tok) || allConcepts.contains { AbbreviationDictionary.match($0, tokens: [tok]) > 0 }
                }.count
                let tidy = cTokens.isEmpty ? 0 : 0.5 * Double(matched) / Double(cTokens.count)
                out.append(ColumnScore(table: t.name, column: col.name, score: total + tidy))
            }
        }
        return out
    }

    /// 테이블별 최고 점수 (높은 순, 같으면 원래 순서)
    public static func rankTables(terms: [String], tables: [TableMeta]) -> [(table: String, score: Double, columns: [String])] {
        let scores = scoreColumns(terms: terms, tables: tables)
        var byTable: [String: [ColumnScore]] = [:]
        for s in scores { byTable[s.table, default: []].append(s) }
        let order = Dictionary(uniqueKeysWithValues: tables.enumerated().map { ($0.element.name, $0.offset) })
        return byTable.map { name, cols in
            let sorted = cols.sorted { $0.score > $1.score }
            return (name, sorted[0].score, sorted.map(\.column))
        }
        .sorted { $0.score != $1.score ? $0.score > $1.score : (order[$0.table] ?? 0) < (order[$1.table] ?? 0) }
    }
}
