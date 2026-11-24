// 화면 자동 테스트 드라이버 (macOS 손쉬운 사용 API). scripts/ui-test.sh 가 컴파일해서 실행한다.
//   uitest <pid> [시나리오 이름 …]   — 이름이 없으면 전부
// 실제 앱을 마우스 · 키보드로 조작하고, 화면 요소(글자 · 버튼 · 편집기 내용)를 읽어 확인한다.
import AppKit
import ApplicationServices

// MARK: - 화면 요소

struct Node {
    let el: AXUIElement
    let role: String
    let label: String
    let value: String
    let frame: CGRect
    /// 알림 · 시트 · 대화상자 안에 있는 요소
    var modal = false
    var text: String { label + " " + value }
}

func attr(_ el: AXUIElement, _ name: String) -> AnyObject? {
    var v: AnyObject?
    return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
}

func frameOf(_ el: AXUIElement) -> CGRect {
    var p = CGPoint.zero, s = CGSize.zero
    if let v = attr(el, kAXPositionAttribute) { AXValueGetValue(v as! AXValue, .cgPoint, &p) }
    if let v = attr(el, kAXSizeAttribute) { AXValueGetValue(v as! AXValue, .cgSize, &s) }
    return CGRect(origin: p, size: s)
}

func node(_ el: AXUIElement) -> Node {
    let role = attr(el, kAXRoleAttribute) as? String ?? ""
    let parts = [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute, kAXPlaceholderValueAttribute]
        .compactMap { attr(el, $0) as? String }.filter { !$0.isEmpty }
    var value = ""
    if let v = attr(el, kAXValueAttribute) {
        if let s = v as? String { value = s } else if let n = v as? NSNumber { value = n.stringValue }
    }
    return Node(el: el, role: role, label: parts.joined(separator: " | "), value: value, frame: frameOf(el))
}

final class App {
    let pid: pid_t
    let ax: AXUIElement

    init(pid: pid_t) {
        self.pid = pid
        ax = AXUIElementCreateApplication(pid)
    }

    /// 모든 창(시트 · 알림 포함)의 요소
    func snapshot(limit: Int = 6000) -> [Node] {
        var out: [Node] = []
        let windows = (attr(ax, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        var queue: [(AXUIElement, Bool)] = windows.map { w in
            let sub = attr(w, kAXSubroleAttribute) as? String ?? ""
            return (w, sub == "AXDialog" || sub == "AXSystemDialog")
        }
        while !queue.isEmpty, out.count < limit {
            let (el, inModal) = queue.removeFirst()
            var n = node(el)
            let modal = inModal || n.role == "AXSheet"
            n.modal = modal
            out.append(n)
            if let kids = attr(el, kAXChildrenAttribute) as? [AXUIElement] { queue.append(contentsOf: kids.map { ($0, modal) }) }
        }
        return out
    }

    func find(_ timeout: Double = 5, _ pred: (Node) -> Bool) -> Node? {
        let end = Date().addingTimeInterval(timeout)
        repeat {
            if let hit = snapshot().first(where: pred) { return hit }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < end
        return nil
    }

    func gone(_ timeout: Double = 5, _ pred: (Node) -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        repeat {
            if !snapshot().contains(where: pred) { return true }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < end
        return false
    }

    func activate() {
        NSRunningApplication(processIdentifier: pid)?.activate()
        Thread.sleep(forTimeInterval: 0.3)
    }
}

// MARK: - 마우스 · 키보드

func post(_ e: CGEvent?) { e?.post(tap: .cghidEventTap) }

func click(_ n: Node, right: Bool = false, double: Bool = false) {
    let p = CGPoint(x: n.frame.midX, y: n.frame.midY)
    clickAt(p, right: right, double: double)
}

func clickAt(_ p: CGPoint, right: Bool = false, double: Bool = false, flags: CGEventFlags = []) {
    let down: CGEventType = right ? .rightMouseDown : .leftMouseDown
    let up: CGEventType = right ? .rightMouseUp : .leftMouseUp
    let button: CGMouseButton = right ? .right : .left
    post(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: button))
    for i in 1...(double ? 2 : 1) {
        let d = CGEvent(mouseEventSource: nil, mouseType: down, mouseCursorPosition: p, mouseButton: button)
        d?.setIntegerValueField(.mouseEventClickState, value: Int64(i))
        if !flags.isEmpty { d?.flags = flags }
        post(d)
        let u = CGEvent(mouseEventSource: nil, mouseType: up, mouseCursorPosition: p, mouseButton: button)
        u?.setIntegerValueField(.mouseEventClickState, value: Int64(i))
        if !flags.isEmpty { u?.flags = flags }
        post(u)
    }
    Thread.sleep(forTimeInterval: 0.4)
}

/// ⌘ 를 실제로 누른 채 클릭
func cmdClick(_ n: Node) {
    let down = CGEvent(keyboardEventSource: nil, virtualKey: 55, keyDown: true)
    down?.flags = .maskCommand
    post(down)
    Thread.sleep(forTimeInterval: 0.05)
    clickAt(CGPoint(x: n.frame.midX, y: n.frame.midY), flags: .maskCommand)
    post(CGEvent(keyboardEventSource: nil, virtualKey: 55, keyDown: false))
    Thread.sleep(forTimeInterval: 0.2)
}

func press(_ n: Node) {
    AXUIElementPerformAction(n.el, kAXPressAction as CFString)
    Thread.sleep(forTimeInterval: 0.4)
}

/// 물리 키 번호 (US 배열 기준 — 입력 방식이 한글이어도 ⌘ 단축키는 같은 키)
let keyCodes: [String: CGKeyCode] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
    "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26,
    "8": 28, "0": 29, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
    "/": 44, ".": 47, ",": 43, "return": 36, "tab": 48, "space": 49, "delete": 51, "escape": 53,
    "left": 123, "right": 124, "down": 125, "up": 126,
]

/// 수정 키(⌘ ⌥ ⇧)를 실제로 누른 채 키를 누른다 — 한글 입력 상태에서도 글자가 새어 들어가지 않게
func key(_ k: String, _ mods: CGEventFlags = []) {
    guard let code = keyCodes[k] else { fatalError("키 없음: \(k)") }
    let modKeys: [(CGEventFlags, CGKeyCode)] = [(.maskCommand, 55), (.maskAlternate, 58), (.maskShift, 56)]
    var held: CGEventFlags = []
    for (flag, mcode) in modKeys where mods.contains(flag) {
        held.insert(flag)
        let e = CGEvent(keyboardEventSource: nil, virtualKey: mcode, keyDown: true)
        e?.flags = held
        post(e)
    }
    Thread.sleep(forTimeInterval: 0.05)
    let d = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)
    d?.flags = mods
    post(d)
    let u = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)
    u?.flags = mods
    post(u)
    for (flag, mcode) in modKeys.reversed() where mods.contains(flag) {
        held.remove(flag)
        let e = CGEvent(keyboardEventSource: nil, virtualKey: mcode, keyDown: false)
        e?.flags = held
        post(e)
    }
    Thread.sleep(forTimeInterval: 0.45)
}

let cmd = CGEventFlags.maskCommand, shift = CGEventFlags.maskShift, opt = CGEventFlags.maskAlternate

func setClipboard(_ s: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
}

func clipboard() -> String { NSPasteboard.general.string(forType: .string) ?? "" }

/// 입력 방식(한/영)과 상관없이 글자를 넣는다: 클립보드에 넣고 ⌘V
func paste(_ s: String) {
    setClipboard(s)
    key("v", cmd)
}

// MARK: - 보고

var report: [String] = []
var failures = 0

func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    if !ok { failures += 1 }
    let line = (ok ? "PASS " : "FAIL ") + name + (detail.isEmpty ? "" : " — " + detail)
    report.append(line)
    print(line)
    fflush(stdout)
}

struct Abort: Error { let message: String }

// MARK: - 앱 전용 도우미

let app = App(pid: pid_t(CommandLine.arguments[1]) ?? 0)

func hasText(_ s: String) -> (Node) -> Bool { { $0.text.contains(s) } }
func role(_ r: String, _ s: String? = nil) -> (Node) -> Bool { { $0.role == r && (s == nil || $0.text.contains(s!)) } }
func button(_ title: String) -> (Node) -> Bool {
    { $0.role == "AXButton" && $0.label.components(separatedBy: " | ").contains(title) }
}

func editor() -> Node? { app.find(3, role("AXTextArea")) }

func editorText() -> String {
    guard let ed = editor(), let v = attr(ed.el, kAXValueAttribute) as? String else { return "" }
    return v
}

/// 편집기 내용을 바꾸고 커서를 원하는 곳에 둔다 (cursorAtEnd = false 면 맨 앞)
func setEditor(_ sql: String, cursorAtEnd: Bool = true) throws {
    guard let ed = editor() else { throw Abort(message: "편집기가 없어요") }
    click(ed)
    key("a", cmd)
    paste(sql)
    if !cursorAtEnd { key("up", cmd) }
    Thread.sleep(forTimeInterval: 0.3)
}

func runQuery() { key("return", cmd) }

/// 실행하고 결과가 보일 때까지 기다린다 (막 연결된 직후 등 한 번 안 먹으면 다시)
func runAndWait(_ timeout: Double = 8, _ pred: @escaping (Node) -> Bool) -> Node? {
    runQuery()
    if let hit = app.find(timeout, pred) { return hit }
    if let ed = editor() { click(ed) }
    runQuery()
    return app.find(timeout, pred)
}

func cell(_ v: String) -> (Node) -> Bool { { $0.role == "AXStaticText" && $0.value == v } }

/// 열린 알림의 버튼을 누른다 (없으면 false)
@discardableResult
func answer(_ title: String, timeout: Double = 3) -> Bool {
    // 알림 · 시트 안의 버튼만 (탭 닫기 × 아이콘도 "닫기" 로 읽히므로)
    guard let b = app.find(timeout, { $0.modal && button(title)($0) }) else { return false }
    press(b)
    return true
}

/// 결과 표의 셀 글자들
func gridTexts() -> [String] {
    app.snapshot().filter { $0.role == "AXStaticText" || $0.role == "AXTextField" }.map(\.value)
}

func tabCount() -> Int {
    app.snapshot().filter { $0.role == "AXStaticText" && $0.value.hasPrefix("쿼리 ") }.count
}

/// 아래 상태창(로그)이 열려 있으면 닫는다 (결과 표가 작아져 행이 안 보이므로)
func hideLog() {
    guard app.find(0.3, { $0.role == "AXCheckBox" && $0.label == "오류만" }) != nil,
          let b = app.find(0.5, { $0.role == "AXButton" && $0.label.hasPrefix("상태창") }) else { return }
    press(b)
}

/// 남은 알림 · 시트를 닫는다
func closeLeftovers() {
    defer { hideLog() }
    for _ in 0..<3 {
        guard app.snapshot().contains(where: { $0.modal }) else { return }
        if answer("취소", timeout: 0.3) || answer("닫기", timeout: 0.3) { continue }
        key("escape")
    }
}

// MARK: - 시나리오

var scenarios: [(String, () throws -> Void)] = []
func scenario(_ name: String, _ body: @escaping () throws -> Void) { scenarios.append((name, body)) }

scenario("connect") {
    guard let row = app.find(5, role("AXStaticText", "UI MySQL")) else { throw Abort(message: "테스트 접속이 사이드바에 없어요") }
    click(row)
    // 사이드바에 DB(shop)와 테이블 목록이 나올 때까지 = 연결 · 스키마 준비 끝
    let ready = app.find(15, { $0.role == "AXPopUpButton" && $0.value == "shop" }) != nil
    check("접속 연결 · 쿼리 탭 열림", ready && app.find(10, role("AXTextArea")) != nil)
}

scenario("lint") {
    func help() -> String { editor().flatMap { attr($0.el, "AXHelp") as? String } ?? "" }
    try setEditor("SELECT a.id, a.custmer, a.amount FROM ui_orders a")
    Thread.sleep(forTimeInterval: 0.8)
    check("없는 컬럼 빨간 밑줄 (custmer, 비슷한 컬럼 customer)", help().contains("custmer") && help().contains("customer"))
    try setEditor("SELECT id, amount, FROM ui_orders")
    Thread.sleep(forTimeInterval: 0.8)
    check("콤마 뒤 항목 없음 표시", help().contains("콤마 뒤에 항목이 없어요"))
    // GodDB 검사로는 모르는 경우 (JOIN + 이름만 쓴 컬럼) → DB 검사
    try setEditor("SELECT custmer FROM ui_orders a JOIN ui_orders b ON a.id = b.id")
    Thread.sleep(forTimeInterval: 2.5)
    check("DB 검사 결과 표시 (실행하지 않음)", help().contains("DB 검사") && help().contains("custmer"))
    try setEditor("SELECT id, customer FROM ui_orders ORDER BY id")
    Thread.sleep(forTimeInterval: 2.5)
    check("올바른 쿼리는 밑줄 없음", help().isEmpty)
}

scenario("run") {
    try setEditor("SELECT id, customer, amount FROM ui_orders ORDER BY id")
    let ok = runAndWait(8, cell("park")) != nil
    check("SELECT 실행 · 결과 표에 행 표시", ok)
    check("결과 행 수 표시 (5행)", app.find(3, hasText("5행")) != nil)
}

scenario("danger") {
    try setEditor("DELETE FROM ui_orders")
    runQuery()
    let shown = app.find(4, hasText("되돌리기 어려운 문장이 있어요")) != nil
    check("WHERE 없는 DELETE 는 실행 전 확인", shown)
    answer("취소")
    try setEditor("SELECT COUNT(*) AS n FROM ui_orders")
    runQuery()
    check("확인에서 취소하면 실행 안 됨 (행 그대로 5개)", app.find(6, { $0.value == "5" }) != nil)
}

scenario("comment") {
    try setEditor("SELECT 1;\nSELECT 2;", cursorAtEnd: false)
    key("/", cmd)
    check("⌘/ 주석 달기", editorText().hasPrefix("-- SELECT 1;"), editorText().prefix(30).description)
    key("/", cmd)
    check("⌘/ 다시 누르면 주석 풀기", editorText().hasPrefix("SELECT 1;"), editorText().prefix(30).description)
}

scenario("format") {
    try setEditor("select id, customer from ui_orders where amount > 100 and customer like 'k%' order by id")
    key("l", [cmd, opt])
    let t = editorText()
    check("⌥⌘L SQL 정렬", t.contains("SELECT id, customer\nFROM ui_orders\nWHERE amount > 100\n    AND customer LIKE"), t)
    key("z", cmd)
    check("정렬은 ⌘Z 로 되돌리기", editorText().hasPrefix("select id"), editorText().prefix(30).description)
}

scenario("cancel") {
    try setEditor("SELECT SLEEP(15)")
    runQuery()
    let running = app.find(4, hasText("실행 중…"))
    check("실행 중 표시 · [취소] 버튼", running != nil && app.find(2, button("취소")) != nil,
          app.snapshot().filter { $0.role == "AXButton" }.map(\.label).filter { !$0.isEmpty }.prefix(12).joined(separator: ", "))
    Thread.sleep(forTimeInterval: 1)
    let started = Date()
    key(".", cmd)
    let done = app.find(8, { $0.role == "AXButton" && $0.label.contains("선택 영역만 실행") }) != nil
        || app.gone(8, button("취소"))
    check("⌘. 로 취소 → \"쿼리를 취소했어요\"", app.find(5, hasText("쿼리를 취소했어요")) != nil)
    check("⌘. 로 취소 (15초 쿼리가 몇 초 안에 끝남)", done && Date().timeIntervalSince(started) < 8,
          String(format: "%.1f초", Date().timeIntervalSince(started)))
}

/// 결과 빠른 필터 비우기 (× 버튼)
/// 사이드바 테이블 줄 (목록은 보이는 줄만 손쉬운 사용에 나오므로 '테이블 검색' 으로 좁혀서 찾는다)
func sidebarTable(_ name: String) -> Node? {
    // 라벨 뒤에 도움말(테이블 코멘트)이 " | …" 로 붙으므로 앞부분 · 값만 본다
    let isRow: (Node) -> Bool = { !$0.modal && ["AXStaticText", "AXHeading"].contains($0.role)
        && ($0.value == name || $0.label.components(separatedBy: " | ").first == name) }
    if let f = app.find(2, { !$0.modal && $0.role == "AXTextField" && $0.label.contains("테이블 검색") }) {
        click(f)
        key("a", [cmd])
        paste(name)
    }
    return app.find(5, isRow)
}

/// 사이드바 '테이블 검색' 비우기
func clearSidebarSearch() {
    if let f = app.find(1, { !$0.modal && $0.role == "AXTextField" && $0.label.contains("테이블 검색") }), !f.value.isEmpty {
        click(f); key("a", [cmd]); key("delete")
    }
}

/// 그 자리에서 마우스 휠을 굴린다 (음수 = 아래로)
func scrollAt(_ n: Node, lines: Int32) {
    post(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: n.frame.midX, y: n.frame.midY), mouseButton: .left))
    post(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0))
    Thread.sleep(forTimeInterval: 0.4)
}

func clearFilter() {
    if let x = app.find(0.5, { $0.role == "AXButton" && $0.label.contains("필터 지우기") }) { press(x) }
}

scenario("grid") {
    clearFilter()
    try setEditor("SELECT id, customer, note FROM ui_orders ORDER BY id")
    // 결과 표의 칸 (오른쪽 상세 패널의 입력란이 아니라)
    guard let lee = runAndWait(8, cell("lee")) else { throw Abort(message: "결과가 없어요") }
    click(lee)
    setClipboard("")
    key("c", cmd)
    let copied = clipboard()
    check("결과 표 ⌘C 복사 (머리글 포함 TSV)", copied.hasPrefix("id\tcustomer\tnote") && copied.contains("2\tlee\tapple, pie"), copied)
    guard let filter = app.find(3, { $0.role == "AXTextField" && $0.label.contains("결과 안에서 찾기") }) else {
        check("빠른 필터 입력란", false); return
    }
    click(filter)
    paste("park")
    check("빠른 필터: 1 / 5행", app.find(3, hasText("1 / 5행")) != nil)
    check("빠른 필터: 다른 행 숨김", app.gone(3, { $0.role == "AXStaticText" && $0.value == "kim" }))
    clearFilter()
    check("필터 지우기(×) 로 모든 행 다시 보임", app.find(3, { $0.role == "AXStaticText" && $0.value == "kim" }) != nil)
}

scenario("history") {
    key("y", cmd)
    let shown = app.find(4, hasText("SQL · DB 검색")) != nil
    check("⌘Y 쿼리 히스토리 열기", shown)
    check("히스토리에 실행한 SQL 이 있음", app.find(3, hasText("SELECT id, customer, note FROM ui_orders")) != nil)
    key("escape")
    check("esc 로 닫기", app.gone(3, hasText("SQL · DB 검색")))
}

scenario("quickopen") {
    key("o", cmd)
    guard app.find(4, hasText("테이블 · 뷰 · 프로시저")) != nil else { check("⌘O 객체 빠른 찾기 열기", false); return }
    check("⌘O 객체 빠른 찾기 열기", true)
    paste("ui_ord")
    check("ui_ord → ui_orders 찾음", app.find(3, { $0.value == "ui_orders" }) != nil)
    key("return")
    check("↩ 로 열면 테이블 데이터 조회", app.find(10, cell("choi")) != nil)
}

scenario("closeTab") {
    let before = tabCount()
    key("t", cmd)
    let opened = tabCount()
    key("w", cmd)
    let after = tabCount()
    check("⌘T 새 탭 · ⌘W 탭 닫기 (창은 그대로)", opened == before + 1 && after == before && !app.snapshot().isEmpty,
          "\(before) → \(opened) → \(after)")
}

scenario("production") {
    guard let row = app.find(3, role("AXStaticText", "UI MySQL Prod")) else { throw Abort(message: "운영 테스트 접속이 없어요") }
    click(row)
    _ = app.find(10, hasText("운영 접속 ·"))
    check("운영 접속 빨간 띠 표시", app.find(3, hasText("운영 접속 · UI MySQL Prod")) != nil)
    try setEditor("UPDATE ui_orders SET amount = amount WHERE id = 1")
    runQuery()
    check("운영에서 데이터 변경 전 확인", app.find(4, hasText("운영 접속에서 데이터를 바꿔요")) != nil)
    answer("취소")
}

scenario("compareLayout") {
    guard let seg = app.find(3, { $0.role == "AXRadioButton" && $0.label == "스키마 비교" }) else { throw Abort(message: "모드 버튼 없음") }
    click(seg)
    let pops = app.snapshot().filter { $0.role == "AXPopUpButton" }
    let win = app.snapshot().first { $0.role == "AXWindow" }?.frame ?? .zero
    check("스키마 비교: 기준 · 대상 선택이 창 안에 있음", pops.count >= 2 && pops.allSatisfy { $0.frame.maxX <= win.maxX + 1 },
          "\(pops.count)개")
    // 접속 선택에 환경이 붙는지 (테스트 접속: UI MySQL · 개발)
    if let pop = pops.first { press(pop); Thread.sleep(forTimeInterval: 0.5) }
    check("스키마 비교: 접속 목록에 환경 표시 (UI MySQL · 개발)", app.find(2, hasText("UI MySQL · 개발")) != nil)
    key("escape")
    if let q = app.find(2, { $0.role == "AXRadioButton" && $0.label == "쿼리" }) { click(q) }
}

/// 스키마 비교 창의 기준 · 대상 선택 상자 (위 → 아래)
func comparePickers() -> [Node] {
    app.snapshot().filter { $0.role == "AXPopUpButton" && ($0.value == "선택" || $0.value.hasPrefix("UI ")) }
        .sorted { $0.frame.minY < $1.frame.minY }
}

/// 선택 상자를 열고 항목을 고른다
func pick(_ popup: Node, _ title: String) -> Bool {
    press(popup)
    guard let item = app.find(3, { $0.role == "AXMenuItem" && $0.label.contains(title) }) else { key("escape"); return false }
    press(item)
    return true
}

/// 비교 결과 표에서 테이블 이름과 내용이 함께 있는 줄
func diffRow(_ table: String, _ detail: String) -> (Node) -> Bool {
    { n in
        guard n.role == "AXRow" else { return false }
        let t = texts(under: n.el)
        return t.contains(table) && t.contains(detail)
    }
}

/// 기준 · 대상 접속과 DB 를 고르고 [비교]
func startCompare(source: String = "UI MySQL · 개발", target: String, sourceDB: String, targetDB: String) throws {
    let pops = comparePickers()
    guard pops.count >= 2 else { throw Abort(message: "기준 · 대상 선택 상자가 없어요 (\(pops.count)개)") }
    guard pick(pops[0], source) else { throw Abort(message: "기준 접속 \(source) 을 고를 수 없어요") }
    guard pick(comparePickers()[1], target) else { throw Abort(message: "대상 접속 \(target) 을 고를 수 없어요") }
    let fields = app.snapshot().filter { $0.role == "AXTextField" && $0.label.contains("DB/스키마") }
        .sorted { $0.frame.minY < $1.frame.minY }
    guard fields.count >= 2 else { throw Abort(message: "DB 입력란이 없어요") }
    for (field, db) in zip(fields, [sourceDB, targetDB]) {
        click(field)
        key("a", cmd)
        paste(db)
    }
    guard let go = app.find(2, button("비교")) else { throw Abort(message: "[비교] 버튼이 없어요") }
    press(go)
}

/// 열린 우클릭 메뉴에서 항목 찾기 (SwiftUI 우클릭 메뉴는 누른 뷰 안쪽에 AXMenu 로 붙는다)
func openMenuItem(_ timeout: Double, _ pred: (Node) -> Bool) -> Node? {
    let end = Date().addingTimeInterval(timeout)
    repeat {
        var queue: [(AXUIElement, Int)] = [(app.ax, 0)]
        while !queue.isEmpty {
            let (el, d) = queue.removeFirst()
            let role = (attr(el, kAXRoleAttribute) as? String) ?? ""
            if role == "AXMenuBar" { continue }
            if role == "AXMenuItem" { let n = node(el); if pred(n) { return n } }
            if d < 40, let kids = attr(el, kAXChildrenAttribute) as? [AXUIElement] { queue += kids.map { ($0, d + 1) } }
        }
        Thread.sleep(forTimeInterval: 0.25)
    } while Date() < end
    return nil
}

scenario("schemaCompare") {
    guard let seg = app.find(3, { $0.role == "AXRadioButton" && $0.label == "스키마 비교" }) else { throw Abort(message: "모드 버튼 없음") }
    click(seg)
    defer { if let q = app.find(2, { $0.role == "AXRadioButton" && $0.label == "쿼리" }) { click(q) } }

    // shop → shop_cmp: shop_cmp 는 shop 을 복사하고 ui_orders.note 를 지우고 ui_customers.name 코멘트만 바꿨다
    try startCompare(target: "UI MySQL · 개발", sourceDB: "shop", targetDB: "shop_cmp")
    // 사이드바에도 같은 테이블 이름이 있으므로 차이 내용이 함께 있는 결과 줄을 찾는다
    let orders = app.find(20, diffRow("ui_orders", "컬럼 없음"))
    let customers = app.find(2, diffRow("ui_customers", "코멘트 변경"))
    check("스키마 비교: 다른 테이블 두 개가 차이 내용과 함께 나옴 (ui_customers 코멘트 변경, ui_orders 컬럼 없음)",
          orders != nil && customers != nil)
    check("스키마 비교: 복사한 나머지 테이블은 일치 (다름 1 · 누락 1)",
          app.find(2, hasText("다름 1")) != nil && app.find(2, hasText("누락 1")) != nil)
    guard let first = customers, let second = orders else { return }

    // ⇧클릭으로 두 줄을 골라 ⌘C → 두 테이블의 보정 SQL 이 목록 순서대로
    let wantCustomers = "ALTER TABLE `ui_customers` MODIFY COLUMN `name` varchar(50) NULL COMMENT '고객 이름';"
    let wantOrders = "ALTER TABLE `ui_orders` ADD COLUMN `note` varchar(100) NULL AFTER `amount`;"
    click(first)
    clickAt(CGPoint(x: second.frame.midX, y: second.frame.midY), flags: shift)
    check("스키마 비교: ⇧클릭으로 두 개 선택 (보정 SQL · 2개 선택)", app.find(3, hasText("보정 SQL · 2개 선택")) != nil)
    setClipboard("")
    key("c", cmd)
    var copied = clipboard()
    check("스키마 비교: ⌘C 로 두 테이블 SQL 복사 (목록 순서)",
          copied == "-- ui_customers\n" + wantCustomers + "\n\n-- ui_orders\n" + wantOrders, copied)

    // 우클릭 '모두 선택' 후 ⌘C (보이는 항목이 두 개뿐)
    click(second)
    click(second, right: true)
    if let all = openMenuItem(3, { $0.label.contains("모두 선택") }) { press(all) } else { key("escape") }
    setClipboard("")
    key("c", cmd)
    copied = clipboard()
    check("스키마 비교: 우클릭 '모두 선택' · ⌘C 로 전체 복사", copied.contains(wantCustomers) && copied.contains(wantOrders), copied)

    // 대상이 닫힌 포트면 계속 돌지 않고 오류와 [다시 시도]
    try startCompare(target: "UI 닫힌 포트 · 개발", sourceDB: "shop", targetDB: "shop")
    let failed = app.find(20, hasText("대상 접속 UI 닫힌 포트 연결 실패"))
    check("스키마 비교: 연결 안 되는 대상은 오류 표시", failed != nil)
    check("스키마 비교: 오류 화면에 [다시 시도]", app.find(2, button("다시 시도")) != nil)
    check("스키마 비교: 읽는 중 표시가 남지 않음", app.gone(2, hasText("두 DB 스키마를 읽는 중")))
}

/// 테스트 앱 창을 PNG 로 저장 (GODDB_UI_SHOT_DIR 이 있을 때만, 눈으로 확인용)
func shot(_ name: String) {
    guard let dir = ProcessInfo.processInfo.environment["GODDB_UI_SHOT_DIR"] else { return }
    let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
    let mine = list.filter { ($0[kCGWindowOwnerPID as String] as? pid_t) == app.pid && ($0[kCGWindowLayer as String] as? Int) == 0 }
    guard let wid = mine.max(by: {
        let a = ($0[kCGWindowBounds as String] as? [String: CGFloat]) ?? [:], b = ($1[kCGWindowBounds as String] as? [String: CGFloat]) ?? [:]
        return (a["Width"] ?? 0) * (a["Height"] ?? 0) < (b["Width"] ?? 0) * (b["Height"] ?? 0)
    })?[kCGWindowNumber as String] as? Int else { return }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    p.arguments = ["-x", "-o", "-l", "\(wid)", "\(dir)/\(name).png"]
    try? p.run(); p.waitUntilExit()
}

/// 글자를 다 보여 주려면 필요한 폭
func textWidth(_ s: String, _ font: NSFont) -> CGFloat {
    (s as NSString).size(withAttributes: [.font: font]).width
}

scenario("queryLayout") {
    // 좁은 창 + AI 어시스턴트 패널: 페이지 크기 선택(500)과 결과 아래 행 범위가 잘리지 않아야 한다
    guard let w = app.find(3, role("AXWindow")) else { throw Abort(message: "창 없음") }
    var original = w.frame.size
    var size = CGSize(width: 1000, height: 720)
    AXUIElementSetAttributeValue(w.el, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &size)!)
    guard let ai = app.find(3, { $0.role == "AXButton" && $0.label.contains("AI 어시스턴트") }) else { throw Abort(message: "AI 버튼 없음") }
    click(ai)
    defer {
        click(ai)
        AXUIElementSetAttributeValue(w.el, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &original)!)
    }
    try setEditor("SELECT id, customer, amount FROM ui_orders ORDER BY id")
    _ = runAndWait(8, cell("park"))
    usleep(400_000)
    shot("queryLayout")
    let nodes = app.snapshot()
    let win = nodes.first { $0.role == "AXWindow" }?.frame ?? .zero
    let limit = nodes.first { $0.role == "AXPopUpButton" && $0.value == "500" }
    let needLimit = textWidth("500", .systemFont(ofSize: NSFont.systemFontSize)) + 20
    check("좁은 창 + AI 패널: 페이지 크기 '500' 이 보임", limit.map { $0.frame.width >= needLimit && $0.frame.maxX <= win.maxX + 1 } ?? false,
          limit.map { "폭 \(Int($0.frame.width)) / 필요 \(Int(needLimit))" } ?? "선택 상자 없음")
    let range = nodes.first { $0.role == "AXStaticText" && $0.value == "1–5행" }
    let needRange = textWidth("1–5행", .preferredFont(forTextStyle: .callout))
    // 결과 아래 버튼 글자가 두 줄로 깨지지 않음 (한 줄 높이 ≈ 20pt)
    for title in ["전체 행 수", "내보내기"] {
        let b = nodes.first { $0.role == "AXButton" && $0.text.contains(title) }
        check("좁은 창 + AI 패널: '\(title)' 버튼이 한 줄", b.map { $0.frame.height < 30 } ?? false,
              b.map { "높이 \(Int($0.frame.height))" } ?? "버튼 없음")
    }
    check("좁은 창 + AI 패널: 결과 아래 '1–5행' 이 잘리지 않음", range.map { $0.frame.width + 1 >= needRange } ?? false,
          range.map { "폭 \(Int($0.frame.width)) / 필요 \(Int(needRange))" } ?? "행 범위 없음")
}

/// 요소 아래 글자를 모두 모은다 (깊이 제한)
func texts(under el: AXUIElement, depth: Int = 5) -> [String] {
    var out: [String] = []
    let n = node(el)
    if !n.value.isEmpty { out.append(n.value) }
    if depth > 0, let kids = attr(el, kAXChildrenAttribute) as? [AXUIElement] {
        for k in kids { out += texts(under: k, depth: depth - 1) }
    }
    return out
}

/// 편집기(스크롤 영역) 높이
func editorHeight() -> CGFloat? {
    guard let ed = editor(), let parent = attr(ed.el, kAXParentAttribute) else { return nil }
    return frameOf(parent as! AXUIElement).height
}

func drag(from a: CGPoint, to b: CGPoint) {
    post(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: a, mouseButton: .left))
    post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: a, mouseButton: .left))
    for i in 1...10 {
        let p = CGPoint(x: a.x + (b.x - a.x) * CGFloat(i) / 10, y: a.y + (b.y - a.y) * CGFloat(i) / 10)
        post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: p, mouseButton: .left))
        usleep(30_000)
    }
    post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: b, mouseButton: .left))
    Thread.sleep(forTimeInterval: 0.4)
}

scenario("runCurrent") {
    // 문장이 둘일 때 ⌘↩ 는 커서가 있는 문장만, ⌥⌘↩ 는 전체
    try setEditor("SELECT 'first1' AS v;\nSELECT 'second2' AS v;", cursorAtEnd: false)
    runQuery()
    let first = app.find(6, cell("first1")) != nil
    check("⌘↩: 커서가 있는 첫 문장만 실행", first && app.find(1, cell("second2")) == nil)
    key("return", [.maskCommand, .maskAlternate])
    check("⌥⌘↩: 전체 실행 (두 번째 문장 결과도 나옴)", app.find(6, cell("second2")) != nil)
}

scenario("editorHeight") {
    // 편집기 / 결과 경계를 내리면 새 탭에서도 그 높이를 기억
    guard let ed = editor(), let parent = attr(ed.el, kAXParentAttribute) else { throw Abort(message: "편집기 없음") }
    let f = frameOf(parent as! AXUIElement)
    let before = f.height
    drag(from: CGPoint(x: f.midX, y: f.maxY + 3), to: CGPoint(x: f.midX, y: f.maxY + 123))
    let after = editorHeight() ?? 0
    check("경계를 끌면 편집기가 커짐", after > before + 60, "\(Int(before)) → \(Int(after))")
    key("t", cmd)
    Thread.sleep(forTimeInterval: 0.8)
    let newTab = editorHeight() ?? 0
    check("새 탭에서도 같은 편집기 높이", abs(newTab - after) < 12, "\(Int(after)) / 새 탭 \(Int(newTab))")
    key("w", cmd)
    Thread.sleep(forTimeInterval: 0.5)
    // 메뉴 보기 > 레이아웃 초기화 → 처음 높이로
    check("메뉴에 '레이아웃 초기화' 가 있음", menuPress("레이아웃 초기화"))
    Thread.sleep(forTimeInterval: 0.6)
    let reset = editorHeight() ?? 0
    check("레이아웃 초기화 후 편집기가 처음 높이로", abs(reset - before) < 12, "\(Int(before)) / 초기화 후 \(Int(reset))")
}

/// 메뉴 막대에서 제목으로 메뉴 항목을 찾아 누른다 (메뉴를 열지 않고 접근성 동작으로)
func menuPress(_ title: String) -> Bool {
    guard let bar = attr(app.ax, kAXMenuBarAttribute) else { return false }
    var queue: [(AXUIElement, Int)] = [(bar as! AXUIElement, 0)]
    while !queue.isEmpty {
        let (el, d) = queue.removeFirst()
        if (attr(el, kAXRoleAttribute) as? String) == "AXMenuItem", (attr(el, kAXTitleAttribute) as? String) == title {
            return AXUIElementPerformAction(el, kAXPressAction as CFString) == .success
        }
        if d < 4, let kids = attr(el, kAXChildrenAttribute) as? [AXUIElement] { queue += kids.map { ($0, d + 1) } }
    }
    return false
}

scenario("groupSelect") {
    // 그룹 안 접속을 눌러도 그룹 줄이 선택(강조)되지 않음
    guard let child = app.find(3, role("AXStaticText", "UI MySQL Prod")) else { throw Abort(message: "그룹 안 접속 없음") }
    click(child)
    Thread.sleep(forTimeInterval: 0.6)
    let selectedRows = app.snapshot().filter { n in
        n.role == "AXRow" && ((attr(n.el, kAXSelectedAttribute) as? Bool) ?? false)
    }
    let groupSelected = selectedRows.contains { texts(under: $0.el).contains("UI 그룹") }
    check("그룹 안 접속을 눌러도 그룹 전체가 선택되지 않음", !groupSelected, "선택된 줄 \(selectedRows.count)개")
    check("선택한 테이블 목록에 그룹이 섞이지 않음", app.find(1, hasText("개 선택")) == nil)
    if let dev = app.find(3, role("AXStaticText", "UI MySQL")) , dev.value == "UI MySQL" { click(dev) }
}

/// 테스트 앱 설정 값 바꾸기 (번들 ID 를 바꾼 복사본이라 실제 GodDB 설정은 건드리지 않는다)
func testDefaults(_ args: [String]) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
    p.arguments = args
    try? p.run(); p.waitUntilExit()
    Thread.sleep(forTimeInterval: 0.5)
}

scenario("dangerSetting") {
    // 개발 접속에서 (운영 접속은 설정과 관계없이 항상 확인)
    if let dev = app.find(3, { $0.role == "AXStaticText" && $0.value == "UI MySQL" }) { click(dev) }
    _ = app.gone(5, hasText("운영 접속 ·"))
    let key = "GodDB.safety.confirmDangerous"
    testDefaults(["write", "local.goddb.app.uitest", key, "-bool", "false"])
    try setEditor("DROP TABLE IF EXISTS ui_tmp_never_exists")
    runQuery()
    let asked = app.find(2, hasText("되돌리기 어려운 문장이 있어요")) != nil
    if asked { answer("취소") }
    check("설정에서 끄면 DROP 이 확인 없이 실행", !asked)
    testDefaults(["delete", "local.goddb.app.uitest", key])
    runQuery()
    check("다시 켜면 (기본값) DROP 전에 확인", app.find(4, hasText("되돌리기 어려운 문장이 있어요")) != nil)
    answer("취소")
}

scenario("noTuning") {
    // 1.4.0: 쿼리 튜닝 제거 — 도구 막대에 'AI 튜닝' 버튼이 없어야 한다
    let found = app.snapshot().contains { $0.role == "AXButton" && $0.text.contains("AI 튜닝") }
    check("쿼리 튜닝 버튼 없음", !found)
}

scenario("prodIdle") {
    // 운영 접속 자동 끊기: 운영 접속에서 쿼리를 실행한 뒤 테스트용 5초로 줄이고 기다리면 끊긴다.
    // (앞 시나리오에서 열어 둔 운영 접속은 이미 오래 쉬었으므로, 먼저 줄이면 누르기 전에 바로 끊긴다 — 그래서 실행 뒤에 줄인다)
    guard let prod = app.find(3, { $0.role == "AXStaticText" && $0.value == "UI MySQL Prod" }) else { throw Abort(message: "운영 테스트 접속이 없어요") }
    click(prod)
    _ = app.find(10, hasText("운영 접속 ·"))
    try setEditor("SELECT 1 AS v")
    _ = runAndWait(8, cell("1"))
    hideLog()
    testDefaults(["write", "local.goddb.app.uitest", "GodDB.safety.prodIdleSecondsForTest", "-int", "5"])
    let cut = app.find(15, hasText("동안 쓰지 않아 끊었어요")) != nil
    testDefaults(["delete", "local.goddb.app.uitest", "GodDB.safety.prodIdleSecondsForTest"])
    check("운영 접속을 쓰지 않으면 자동으로 끊김 (테스트 5초)", cut)
    if let dev = app.find(3, { $0.role == "AXStaticText" && $0.value == "UI MySQL" }) { click(dev) }
}

scenario("idSearch") {
    // ID 로 찾기: 사이드바에서 ui_orders 를 고르고 ⌥⌘F → 로그 3줄 붙여넣기 → 3개 추출 → 조회 → 없는 ID 1개
    if let dev = app.find(3, { $0.role == "AXStaticText" && $0.value == "UI MySQL" }) { click(dev) }
    guard let table = sidebarTable("ui_orders") else {
        throw Abort(message: "사이드바에 ui_orders 가 없어요")
    }
    defer { clearSidebarSearch() }
    click(table)
    key("f", [cmd, opt])
    guard let area = app.find(4, { $0.modal && $0.role == "AXTextArea" }) else { check("⌥⌘F ID 로 찾기 열기", false); return }
    check("⌥⌘F ID 로 찾기 열기 · 고른 테이블이 미리 선택됨",
          app.find(2, { $0.modal && $0.role == "AXPopUpButton" && $0.value == "ui_orders" }) != nil)
    check("컬럼 기본값은 기본 키 (이름 (타입))", app.find(2, { $0.modal && $0.role == "AXPopUpButton" && $0.value.hasPrefix("id (int") }) != nil)
    click(area)
    paste("""
    2026-11-20 10:01:02 ERROR orderId=2 payment failed
    2026-11-20 10:01:03 WARN orderId=4 retry orderId=2
    2026-11-20 10:01:04 INFO orderId=99 done
    """)
    check("로그 3줄에서 숫자 ID 3개 추출 (날짜 · 시각 · 중복 제외)",
          app.find(3, { $0.modal && $0.text.contains("찾은 값 3개 (중복 1개 제외) : 2, 4, 99") }) != nil,
          app.snapshot().filter { $0.modal && $0.text.contains("찾은 값") }.map(\.value).joined(separator: " / "))
    guard let run = app.find(2, { $0.modal && button("조회")($0) }) else { check("[조회] 버튼", false); return }
    press(run)
    check("새 탭 'ID: ui_orders.id (3)' 에서 조회", app.find(10, hasText("ID: ui_orders.id (3)")) != nil)
    check("찾은 행 표시 (lee · choi)", app.find(8, cell("lee")) != nil && app.find(2, cell("choi")) != nil)
    check("없는 ID 표시 (요청 3 · 찾음 2 · 없음 1)", app.find(5, hasText("요청 3 · 찾음 2 · 없음 1")) != nil)
    setClipboard("")
    if let copy = app.find(2, button("없는 ID 복사")) { press(copy) }
    check("[없는 ID 복사] → 99", clipboard() == "99", clipboard())
}

scenario("savedQuery") {
    // 저장 쿼리: :id 쿼리를 ⌥⌘S 로 저장 → 편집기 비우기 → ⇧⌘K 목록에서 더블클릭 → 값 2 입력 → 실행 → 다시 열면 2 가 남아 있음
    if let dev = app.find(3, { $0.role == "AXStaticText" && $0.value == "UI MySQL" }) { click(dev) }
    try setEditor("SELECT id, customer FROM ui_orders WHERE id = :id")
    // 편집기 우클릭에도 '쿼리 저장…' 이 있다
    if let editor = app.find(2, { !$0.modal && $0.role == "AXTextArea" }) {
        click(editor, right: true)
        check("편집기 우클릭 '쿼리 저장…'", findMenuItem(3, { $0.label.contains("쿼리 저장…") }) != nil)
        key("escape")
    }
    key("s", [cmd, opt])
    guard let nameField = app.find(4, { $0.modal && $0.role == "AXTextField" && $0.value.hasPrefix("SELECT id, customer") }) else {
        check("⌥⌘S 쿼리 저장 창 열기 (이름 기본값 = 첫 줄 앞 40자)", false); return
    }
    check("⌥⌘S 쿼리 저장 창 열기 (이름 기본값 = 첫 줄 앞 40자)", nameField.value == "SELECT id, customer FROM ui_orders WHERE", nameField.value)   // 끝 공백은 뗀다
    check("찾은 빈칸 표시 (빈칸: :id)", app.find(2, { $0.modal && $0.text.contains("빈칸: :id") }) != nil)
    click(nameField)
    key("a", cmd)
    paste("UI 주문 조회")
    guard let save = app.find(2, { $0.modal && button("저장")($0) }) else { check("[저장] 버튼", false); return }
    press(save)
    check("저장하면 창이 닫힘", app.gone(3, { $0.modal && $0.role == "AXTextField" }))

    // 지금 탭을 비워 두면 그 탭에 넣고 실행한다
    if let ed = editor() { click(ed) }
    key("a", cmd)
    key("delete")
    key("k", [cmd, shift])
    guard let row = app.find(4, { $0.modal && $0.role == "AXStaticText" && $0.value == "UI 주문 조회" }) else {
        check("⇧⌘K 저장 쿼리 목록에 보임", false); return
    }
    check("⇧⌘K 저장 쿼리 목록에 보임", true)
    click(row, double: true)
    guard let field = app.find(4, { $0.modal && $0.role == "AXTextField" && $0.label.contains(":id") }) else {
        check("빈칸이 있으면 입력 창 (:id)", false); return
    }
    check("빈칸이 있으면 입력 창 (:id)", true)
    click(field)
    paste("2")
    guard let run = app.find(2, { $0.modal && button("실행")($0) }) else { check("[실행] 버튼", false); return }
    press(run)
    check("값을 채워 지금 탭에 넣음 (WHERE id = 2)", editorText().contains("WHERE id = 2"), editorText())
    check("실행 결과 (lee)", app.find(8, cell("lee")) != nil)

    // 다시 열면 마지막 값이 채워져 있다
    key("k", [cmd, shift])
    if let again = app.find(4, { $0.modal && $0.role == "AXStaticText" && $0.value == "UI 주문 조회" }) { click(again, double: true) }
    let remembered = app.find(4, { $0.modal && $0.role == "AXTextField" && $0.label.contains(":id") })
    check("다음에 열면 마지막 값 기억 (2)", remembered?.value == "2", remembered?.value ?? "입력 창 없음")
    answer("취소")
}

/// 열린 우클릭 메뉴의 항목. SwiftUI 우클릭 메뉴는 앱 바로 아래가 아니라 누른 뷰(표 · 목록) 안쪽에 AXMenu 로 붙는다
func contextMenuItems() -> [Node] {
    var out: [Node] = []
    var queue: [(AXUIElement, Int)] = [(app.ax, 0)]
    while !queue.isEmpty {
        let (el, d) = queue.removeFirst()
        let role = (attr(el, kAXRoleAttribute) as? String) ?? ""
        if role == "AXMenuBar" { continue }
        if role == "AXMenuItem" { out.append(node(el)) }
        if d < 40, let kids = attr(el, kAXChildrenAttribute) as? [AXUIElement] { queue += kids.map { ($0, d + 1) } }
    }
    return out
}

func findMenuItem(_ timeout: Double = 3, _ pred: (Node) -> Bool) -> Node? {
    let end = Date().addingTimeInterval(timeout)
    repeat {
        if let hit = contextMenuItems().first(where: pred) { return hit }
        Thread.sleep(forTimeInterval: 0.25)
    } while Date() < end
    return nil
}

scenario("fkFollow") {
    // 외래 키 따라가기: ui_orders.customer_id 칸 ⌘ 클릭 → '↗ ui_customers' 탭 → 행 상세 '참조하는 테이블' → '↙ ui_orders'
    if let dev = app.find(3, { $0.role == "AXStaticText" && $0.value == "UI MySQL" }) { click(dev) }
    clearFilter()
    try setEditor("SELECT id, customer, customer_id FROM ui_orders ORDER BY id")
    guard let fkCell = runAndWait(8, cell("20")) else { throw Abort(message: "결과가 없어요") }
    check("외래 키 컬럼 머리글에 ↗", app.find(2, { $0.text.contains("customer_id ↗") }) != nil)
    cmdClick(fkCell)
    check("⌘ 클릭 → 새 탭 '↗ ui_customers'", app.find(8, hasText("↗ ui_customers")) != nil)
    check("참조하는 행 조회 (id 20 · lee · silver)", app.find(8, cell("silver")) != nil && app.find(1, cell("gold")) == nil)

    // 결과가 1행이라 행 상세가 열려 있다 → 맨 아래 '참조하는 테이블'
    guard let back = app.find(5, { $0.role == "AXButton" && $0.label.contains("↙ ui_orders (customer_id)") }) else {
        check("행 상세 '참조하는 테이블' 에 ↙ ui_orders (customer_id)", false); return
    }
    check("행 상세 '참조하는 테이블' 에 ↙ ui_orders (customer_id)", true)
    press(back)
    check("새 탭 '↙ ui_orders'", app.find(8, hasText("↙ ui_orders")) != nil)
    check("이 고객을 참조하는 주문 (apple, pie)", app.find(8, cell("apple, pie")) != nil && app.find(1, cell("first")) == nil)

    // 우클릭 > 참조 따라가기 → ui_customers (customer_id)
    try setEditor("SELECT id, customer, customer_id FROM ui_orders ORDER BY id")
    guard let park = runAndWait(8, cell("30")) else { throw Abort(message: "결과가 없어요") }
    click(park, right: true)
    if let item = findMenuItem(3, { $0.label.contains("참조 따라가기 → ui_customers (customer_id)") }) {
        check("우클릭 '참조 따라가기 → ui_customers (customer_id)'", true)
        press(item)
        check("우클릭으로 따라가기 (bronze)", app.find(8, cell("bronze")) != nil)
    } else {
        check("우클릭 '참조 따라가기 → ui_customers (customer_id)'", false)
        key("escape")
    }

    // 추정 관계: ui_points.member_no → ui_members (외래 키 제약 없음)
    try setEditor("SELECT id, member_no, point FROM ui_points ORDER BY id")
    guard let member = runAndWait(8, cell("1002")) else { throw Abort(message: "ui_points 결과가 없어요") }
    cmdClick(member)
    check("추정 관계 ⌘ 클릭 → '↗ ui_members' (trinity)", app.find(8, hasText("↗ ui_members")) != nil && app.find(8, cell("trinity")) != nil)

    // 조인 결과에는 메뉴가 없다
    try setEditor("SELECT o.id, c.grade FROM ui_orders o JOIN ui_customers c ON c.id = o.customer_id ORDER BY o.id")
    guard let gold = runAndWait(8, cell("silver")) else { throw Abort(message: "조인 결과가 없어요") }
    click(gold, right: true)
    let opened = findMenuItem(2, { $0.label.contains("복사") }) != nil
    check("조인 결과 우클릭에는 '참조 따라가기' 가 없음",
          opened && !contextMenuItems().contains { $0.label.contains("참조 따라가기") || $0.label.contains("이 행을 참조하는 행") })
    key("escape")
}

scenario("jsonView") {
    // JSON 보기: ui_orders.meta 가 든 한 행 → 행 상세에 원문 · 정렬 · 트리 (기본 트리, 2단계까지 펼침) → 우클릭 경로 복사
    testDefaults(["delete", "local.goddb.app.uitest", "GodDB.json.viewMode"])
    if let dev = app.find(3, { $0.role == "AXStaticText" && $0.value == "UI MySQL" }) { click(dev) }
    clearFilter()
    try setEditor("SELECT id, meta FROM ui_orders WHERE id = 1")
    // 결과 표의 JSON 칸은 원문 한 줄 그대로
    guard runAndWait(8, { $0.role == "AXStaticText" && $0.value.contains("\"coupon\": {") }) != nil else {
        throw Abort(message: "결과가 없어요")
    }
    // 결과가 1행이라 행 상세가 열려 있다
    check("JSON 칸 위에 보기 전환 (원문 · 정렬 · 트리)",
          app.find(5, { $0.role == "AXRadioButton" && $0.text.contains("트리") }) != nil
          && app.find(1, { $0.role == "AXRadioButton" && $0.text.contains("정렬") }) != nil)
    // 창이 작아 행 상세에는 tags 까지만 보인다 → 배열 항목부터 보고, 휠로 내려 coupon 을 본다
    guard let first = app.find(5, { $0.role == "AXStaticText" && $0.value == "\"new\"" }) else {
        check("트리가 펼쳐짐 (tags[0] = \"new\")", false); return
    }
    check("트리가 펼쳐짐 (tags[0] = \"new\")", true)
    setClipboard("")
    if let tag = app.find(3, { $0.role == "AXStaticText" && $0.value == "\"gift\"" }) {
        click(tag, right: true)
        if let item = findMenuItem(3, { $0.label.contains("경로 복사") }) { press(item) } else { key("escape") }
        check("배열 항목 경로 복사 → $.tags[1]", clipboard() == "$.tags[1]", clipboard())
    } else {
        check("트리에 tags[1] = \"gift\"", false)
    }
    scrollAt(first, lines: -6)
    check("2단계까지 펼쳐짐 (coupon.code = \"A-77\")", app.find(5, { $0.role == "AXStaticText" && $0.value == "\"A-77\"" }) != nil)
    if let code = app.find(3, { $0.role == "AXStaticText" && $0.value == "code" }) {
        setClipboard("")
        click(code, right: true)
        if let item = findMenuItem(3, { $0.label.contains("경로 복사") }) {
            press(item)
            check("우클릭 > 경로 복사 → $.coupon.code", clipboard() == "$.coupon.code", clipboard())
        } else {
            check("우클릭 > 경로 복사", false)
            key("escape")
        }
    } else {
        check("트리에 coupon 아래 code 항목", false)
    }
    // 정렬 보기: 들여쓰기 2칸, 원래 키 순서
    if let pretty = app.find(2, { $0.role == "AXRadioButton" && $0.text.contains("정렬") }) {
        click(pretty)
        // MySQL 은 JSON 키를 (길이 → 글자) 순으로 저장해 돌려준다: tags → coupon → channel. 그 순서를 그대로 유지
        check("정렬 보기 (들여쓰기 2칸, 받은 키 순서 그대로)",
              app.find(4, { $0.role == "AXStaticText" && $0.value.hasPrefix("{\n  \"tags\": [\n    \"new\",") }) != nil)
    }
    testDefaults(["delete", "local.goddb.app.uitest", "GodDB.json.viewMode"])
}

/// 결과 표 칸을 더블클릭해 그 자리 입력란을 연다 (먼저 한 번 눌러 행을 고른다 — 오른쪽 패널이 열리며 칸 위치가 바뀌므로)
func openInlineEditor(_ value: String) -> Node? {
    // 고르지 않은 행을 바로 더블클릭 (실제로 쓰는 방식 — 첫 클릭에 행 편집 패널이 열리며 표가 다시 배치된다)
    // 적용 직후 표를 다시 그리는 중이면 더블클릭이 빗나갈 수 있어 한 번 더 (칸 위치를 다시 찾는다)
    for attempt in 0..<3 {
        if attempt > 0 { Thread.sleep(forTimeInterval: 0.7) }  // 다시 그리기가 끝나길 기다린다
        guard let c = app.find(5, cell(value)) else { return nil }
        click(c, double: true)
        if let f = app.find(3, { $0.role == "AXTextField" && $0.label.contains("칸 편집") }) { return f }
    }
    return nil
}

/// 편집 막대 [적용…] → 확인 창 [적용]
func applyEdits() -> Bool {
    guard let apply = app.find(3, button("적용…")) else { return false }
    press(apply)
    return answer("적용", timeout: 4)
}

scenario("inlineEdit") {
    // 칸 그 자리 편집: ui_orders id 5 의 note('last') 더블클릭 → 입력 → ↩ → 변경 1건 → 적용 → 다시 읽은 값 확인
    // → Esc 는 아무것도 안 바꿈 → 원래 값('last')으로 되돌려 둔다 (다른 시나리오는 'last' 를 쓰지 않지만 시드 그대로 유지)
    if let dev = app.find(3, { $0.role == "AXStaticText" && $0.value == "UI MySQL" }) { click(dev) }
    clearFilter()
    try setEditor("SELECT id, customer, note FROM ui_orders ORDER BY id")
    guard runAndWait(8, cell("last")) != nil else { throw Abort(message: "결과가 없어요") }
    guard let field = openInlineEditor("last") else { check("칸 더블클릭 → 그 자리 입력란", false); return }
    check("칸 더블클릭 → 그 자리 입력란 (지금 값 'last')", field.value == "last", field.value)
    paste("inline ok")
    key("return")
    check("↩ → 입력란 닫힘", app.gone(3, { $0.role == "AXTextField" && $0.label.contains("칸 편집") }))
    check("↩ → 변경 1건", app.find(3, hasText("변경 1건")) != nil)
    check("표에 새 값 표시", app.find(3, cell("inline ok")) != nil)
    check("[적용…] → 확인 창 → 적용", applyEdits())
    check("적용 후 다시 읽은 값 'inline ok' · 변경 없음",
          app.find(8, cell("inline ok")) != nil && app.gone(3, hasText("변경 1건")) && app.find(1, cell("last")) == nil)

    // Esc: 입력해도 바뀌지 않는다
    if let f = openInlineEditor("inline ok") {
        paste("zzz")
        key("escape")
        check("Esc → 입력란 닫힘", app.gone(3, { $0.role == "AXTextField" && $0.label.contains("칸 편집") }))
        check("Esc → 값 그대로 · 변경 없음",
              app.find(2, cell("inline ok")) != nil && app.find(1, cell("zzz")) == nil && app.find(1, hasText("변경 1건")) == nil,
              f.value)
    } else {
        check("다시 더블클릭 → 입력란", false)
    }

    // 원래 값으로 되돌려 둔다
    guard openInlineEditor("inline ok") != nil else { check("되돌리기용 입력란", false); return }
    paste("last")
    key("return")
    check("원래 값 'last' 로 되돌림", applyEdits() && app.find(8, cell("last")) != nil && app.find(1, cell("inline ok")) == nil)
}

scenario("dataFinder") {
    // AI 데이터 찾기 (로컬 Ollama 필요): 코멘트 없는 약어 컬럼을 한글 질문으로 찾는다
    if let dev = app.find(3, { $0.role == "AXStaticText" && $0.value == "UI MySQL" }) { click(dev) }
    guard let ai = app.find(3, { $0.role == "AXButton" && $0.label.contains("AI 어시스턴트") }) else { throw Abort(message: "AI 버튼 없음") }
    click(ai)
    defer { click(ai) }
    func ask(_ question: String, expect: [String], timeout: Double = 150) -> Bool {
        // 첫 질문은 🔎 버튼으로 데이터 찾기 모드, 그 뒤(버튼이 메뉴 안으로 들어감)는 "…어디 있어?" 자동 판단으로
        if let finder = app.find(3, { $0.role == "AXButton" && $0.text.contains("데이터 위치 찾기") }) { press(finder) }
        guard let field = app.find(3, { ["AXTextField", "AXTextArea"].contains($0.role)
            && ($0.label.contains("찾을 데이터") || $0.label.contains("질문을 입력")) }) else { return false }
        click(field)
        paste(question)
        key("return")
        let hit = app.find(timeout, { n in expect.contains { n.text.contains($0) } && (n.role == "AXStaticText") && n.text.contains(".") })
        return hit != nil
    }
    check("AI 데이터 찾기: '회원 전화번호 어디 있어?' → tb_mbr_info.mbr_tel_no",
          ask("회원 전화번호 어디 있어?", expect: ["tb_mbr_info.mbr_tel_no"]))
    check("AI 데이터 찾기: 값을 로컬 AI 에 보낸 표시 (후보 컬럼 샘플 … (로컬))",
          app.find(3, hasText("(로컬)")) != nil)
    check("AI 데이터 찾기: '학년 정보는 어디 있어?' → schyr 또는 grade_level",
          ask("학년 정보는 어디 있어?", expect: ["tb_stdnt_info.schyr", "ui_students.grade_level"]))
    check("AI 데이터 찾기: 모델 오류 안내가 없음", app.find(1, hasText("응답하지 않아요")) == nil)
}

// MARK: - 실행

guard AXIsProcessTrusted() else {
    print("FAIL 손쉬운 사용 권한이 없어요 — 시스템 설정 > 개인정보 보호 및 보안 > 손쉬운 사용 에서 실행하는 앱(터미널 등)을 허용하세요")
    exit(2)
}
app.activate()
// 디버그: uitest <pid> --click <글자>  → 그 글자가 보이는 요소를 누르고 포커스 출력
if CommandLine.arguments.dropFirst(2).first == "--click", let t = CommandLine.arguments.dropFirst(3).first {
    if let n = app.find(3, { $0.role == "AXStaticText" && $0.value == t }) { click(n) }
    if let f = attr(app.ax, kAXFocusedUIElementAttribute) { let n = node(f as! AXUIElement); print("focused:", n.role, n.value.prefix(40)) }
    exit(0)
}
/// 열기 창에서 파일 고르기 (⌘⇧G 로 경로)
func chooseInOpenPanel(_ path: String) {
    Thread.sleep(forTimeInterval: 1.2)
    key("g", [cmd, shift])
    Thread.sleep(forTimeInterval: 0.6)
    paste(path)
    key("return")
    Thread.sleep(forTimeInterval: 0.8)
    key("return")
    Thread.sleep(forTimeInterval: 0.8)
}

/// 저장 창에서 폴더 · 이름을 넣고 저장
func saveInPanel(_ path: String) {
    let url = URL(fileURLWithPath: path)
    try? FileManager.default.removeItem(at: url)
    Thread.sleep(forTimeInterval: 1.2)
    key("g", [cmd, shift])
    Thread.sleep(forTimeInterval: 0.6)
    paste(url.deletingLastPathComponent().path)
    key("return")
    Thread.sleep(forTimeInterval: 0.8)
    key("a", cmd)
    paste(url.lastPathComponent)
    key("return")
    Thread.sleep(forTimeInterval: 1.0)
}

func fileText(_ path: String, wait: Double = 4) -> String {
    let end = Date().addingTimeInterval(wait)
    repeat {
        if let t = try? String(contentsOfFile: path, encoding: .utf8) { return t }
        Thread.sleep(forTimeInterval: 0.3)
    } while Date() < end
    return ""
}

let uiWork = ProcessInfo.processInfo.environment["GODDB_UI_WORK"] ?? NSTemporaryDirectory()

/// 사이드바 머리 줄 (DB 글자 · DB 고르기 · 테이블 수 · 말풍선 · 다이어그램 · 새로고침) — 접근성에는 팝업 버튼 하나로 뭉쳐 보이고,
/// 라벨에 말풍선 도움말("테이블 설명 (AI 참고) — …")이 들어 있다 (#185)
func descriptionsIcon() -> Node? {
    app.find(10, { !$0.modal && $0.role == "AXPopUpButton" && $0.label.contains("테이블 설명 (AI 참고)") })
}

/// 말풍선 아이콘 → 테이블 설명 창. 아이콘은 머리 줄 오른쪽 끝에서 50pt 왼쪽 (새로고침 · 다이어그램 앞)
@discardableResult
func openDescriptions() -> Bool {
    guard let header = descriptionsIcon() else { return false }
    clickAt(CGPoint(x: header.frame.maxX - 50, y: header.frame.midY))
    return app.find(4, { $0.modal && $0.text.contains("AI 에이전트로 채우기") }) != nil
}

func sheetButton(_ title: String) -> Node? {
    app.find(3, { $0.modal && $0.role == "AXButton" && $0.label.components(separatedBy: " | ").contains(title) })
}

scenario("tableDescriptions") {
    // 테이블 설명 (#178, AI 없이): 사이드바 DB 머리 우클릭 > 테이블 설명 (AI 참고)… → JSON 가져오기 → 맞춰 보기
    // → AI 어시스턴트 데이터 찾기가 설명의 찾는 말로 바로 답 (AI 호출 없음)
    if let dev = app.find(3, { $0.role == "AXStaticText" && $0.value == "UI MySQL" }) { click(dev) }
    check("사이드바 말풍선 아이콘 (설명 없음 → '아직 없어요')", descriptionsIcon()?.label.contains("아직 없어요") == true,
          descriptionsIcon()?.label ?? "")
    // DB 글자 우클릭 메뉴도 그대로 (글자는 접근성에 안 보여서 DB 고르기 팝업 왼쪽을 누른다)
    if let picker = app.find(10, { !$0.modal && $0.role == "AXPopUpButton" && $0.value == "shop" }) {
        clickAt(CGPoint(x: picker.frame.minX - 14, y: picker.frame.midY), right: true)
        check("DB 글자 우클릭 > '테이블 설명 (AI 참고)…'", findMenuItem(3, { $0.label.contains("테이블 설명 (AI 참고)") }) != nil)
        key("escape")
    }
    guard openDescriptions() else { check("말풍선 아이콘 → 테이블 설명 창", false); return }
    check("테이블 설명 창 열기 (설명 없음)", app.find(4, { $0.modal && $0.text.contains("아직 테이블 설명이 없어요") }) != nil)
    guard let importButton = app.find(2, { $0.modal && $0.role == "AXButton" && $0.text.contains("JSON 가져오기") }) else {
        check("[JSON 가져오기…] 버튼", false); closeLeftovers(); return
    }
    press(importButton)
    chooseInOpenPanel(uiWork + "/table-descriptions.json")
    check("JSON 가져오기 → 테이블 2개 · 코드 값 2개",
          app.find(5, { $0.modal && $0.text.contains("테이블 2개 · 컬럼 2개 · 코드 값 2개") }) != nil)
    check("DB 와 맞춰 보기: 없는 테이블 표시",
          app.find(2, { $0.modal && $0.text.contains("DB 에 없는 테이블 1개 (no_such_table)") }) != nil)
    check("목록에 title", app.find(2, { $0.modal && $0.role == "AXStaticText" && $0.value.contains("회원 정보") }) != nil)
    // 상세 (#189): 처음엔 첫 테이블 tb_mbr_info — 찾는 말 칩 · 코드 값 칩 · 컬럼 title
    check("상세: 컬럼 title '회원 전화번호'", app.find(3, { $0.modal && $0.text.contains("회원 전화번호") }) != nil)
    check("상세: 찾는 말 칩 '연락처'", app.find(2, { $0.modal && $0.text.contains("연락처") }) != nil)
    check("상세: 코드 값 칩 'kim = 김'", app.find(2, { $0.modal && $0.text.contains("kim = 김") }) != nil)
    // 목록에서 DB 에 없는 테이블을 고르면 상세에 안내
    if let row = app.snapshot().filter({ $0.modal && $0.role == "AXStaticText" && $0.value == "no_such_table" })
        .min(by: { $0.frame.minX < $1.frame.minX }) {
        click(row)
        check("목록에서 no_such_table 고르기 → '지금 DB 에 없는 테이블이에요'",
              app.find(3, { $0.modal && $0.text.contains("지금 DB 에 없는 테이블이에요") }) != nil)
    } else { check("목록에 no_such_table", false) }
    if !answer("닫기") { key("escape") }
    check("창 닫힘", app.gone(3, { $0.modal && $0.text.contains("AI 에이전트로 채우기") }))
    check("말풍선 아이콘 (설명 있음 → '테이블 2개')", app.find(3, { !$0.modal && $0.role == "AXPopUpButton" && $0.label.contains("테이블 설명 (AI 참고) — 테이블 2개") }) != nil,
          descriptionsIcon()?.label ?? "")

    guard let ai = app.find(3, { $0.role == "AXButton" && $0.label.contains("AI 어시스턴트") }) else { throw Abort(message: "AI 버튼 없음") }
    click(ai)
    defer { click(ai) }
    check("AI 패널 칩 '테이블 설명 · 테이블 2개'", app.find(3, hasText("테이블 설명 · 테이블 2개")) != nil)
    if let finder = app.find(3, { $0.role == "AXButton" && $0.text.contains("데이터 위치 찾기") }) { press(finder) }
    guard let field = app.find(3, { ["AXTextField", "AXTextArea"].contains($0.role)
        && ($0.label.contains("찾을 데이터") || $0.label.contains("질문을 입력")) }) else { check("입력칸", false); return }
    click(field)
    paste("연락처 어디 있어?")
    key("return")
    check("데이터 찾기: 설명의 찾는 말 '연락처' → tb_mbr_info.mbr_tel_no (AI 없이)",
          app.find(8, { $0.role == "AXStaticText" && $0.text.contains("tb_mbr_info.mbr_tel_no") }) != nil)
    check("데이터 찾기: '테이블 설명에서 찾음' 칩", app.find(3, hasText("테이블 설명에서 찾음")) != nil)
}

scenario("assistantInterrupt") {
    // #203 (로컬 Ollama 필요): Shift+Enter 줄바꿈 · 답하는 중 Enter 는 대기열 · 대기 글 ↑ 는 지금 답을 멈추고 바로 보내기
    //                         · 멈추기는 대기 글을 입력칸으로 돌려놓음
    if let dev = app.find(3, { $0.role == "AXStaticText" && $0.value == "UI MySQL" }) { click(dev) }
    guard let ai = app.find(3, { $0.role == "AXButton" && $0.label.contains("AI 어시스턴트") }) else { throw Abort(message: "AI 버튼 없음") }
    click(ai)
    defer { click(ai) }
    if let newChat = app.find(2, { $0.role == "AXButton" && $0.label.contains("새 대화") }) { press(newChat) }
    let isField = { (n: Node) in ["AXTextField", "AXTextArea"].contains(n.role) && n.label.contains("질문을 입력") }
    guard let field = app.find(3, isField) else { check("입력칸", false); return }
    func inputValue() -> String { app.find(2, isField)?.value ?? "?" }
    let stop = { (n: Node) in n.role == "AXButton" && n.label.contains("멈추기") && !n.modal }

    click(field)
    paste("줄 하나")
    key("return", shift)
    paste("줄 둘")
    let typed = inputValue()
    check("Shift+Enter → 줄바꿈 (보내지 않음)", typed.contains("줄 하나\n줄 둘") && app.find(1, stop) == nil, typed)
    key("a", cmd); key("delete")

    paste("이 DB 의 테이블을 하나씩 아주 자세히 설명하고, 각 테이블마다 예시 SQL 을 세 개씩 써 줘")
    key("return")
    check("첫 질문: 답하는 중 (멈춤 버튼)", app.find(15, stop) != nil)
    click(field)
    paste("두 번째 질문: 각 테이블의 인덱스와 쓰임을 아주 자세히 설명해 줘")
    key("return")
    check("답하는 중 Enter → '대기 · 두 번째 질문' 칩", app.find(5, hasText("대기 · 두 번째 질문")) != nil)
    check("대기만 하고 첫 답은 계속 (취소 없음)", app.find(1, hasText("(취소했어요)")) == nil && app.find(1, stop) != nil)
    check("입력칸이 비워짐", inputValue().isEmpty, inputValue())
    if let now = app.find(3, { $0.role == "AXButton" && $0.label.contains("지금 답을 멈추고 바로 보내기") }) {
        press(now)
    } else { check("대기 글의 ↑ 버튼", false) }
    check("↑ → 첫 답은 '(취소했어요)'", app.find(8, hasText("(취소했어요)")) != nil)
    check("↑ → 대기 글이 대화로 들어가고 대기열은 빔",
          app.find(5, { $0.role == "AXStaticText" && $0.value.hasPrefix("두 번째 질문: 각 테이블의 인덱스") }) != nil
            && app.find(1, hasText("대기 · 두 번째")) == nil)
    check("↑ → 새 글 답하는 중 (멈춤 버튼)", app.find(5, stop) != nil)

    click(field)
    paste("세 번째 질문")
    key("return")
    check("답하는 중 Enter → '대기 · 세 번째 질문'", app.find(5, hasText("대기 · 세 번째 질문")) != nil)
    if let s = app.find(2, stop) { press(s) }
    check("멈추기 → 대기 글은 입력칸으로 돌아옴", inputValue().contains("세 번째 질문"), inputValue())
    check("멈추기 → 대기열 빔 · 자동으로 보내지 않음",
          app.find(1, hasText("대기 · 세 번째")) == nil && app.find(3, stop) == nil)
    click(field)
    key("a", cmd); key("delete")
}

scenario("assistantInterruptMore") {
    // #179: 답하는 중 [새 대화] 를 눌러도 앱이 꺼지지 않음 · 답하는 중 데이터 찾기를 ⌘Enter 로 보내면 지금 답은 멈추고 찾기가 먼저 (#203)
    if let dev = app.find(3, { $0.role == "AXStaticText" && $0.value == "UI MySQL" }) { click(dev) }
    guard let ai = app.find(3, { $0.role == "AXButton" && $0.label.contains("AI 어시스턴트") }) else { throw Abort(message: "AI 버튼 없음") }
    click(ai)
    defer { click(ai) }
    let stop = { (n: Node) in n.role == "AXButton" && n.label.contains("멈추기") && !n.modal }
    func field() -> Node? { app.find(3, { ["AXTextField", "AXTextArea"].contains($0.role) && $0.label.contains("질문을 입력") }) }
    func newChat() { if let b = app.find(2, { $0.role == "AXButton" && $0.label.contains("새 대화") }) { press(b) } }
    newChat()
    guard let f = field() else { check("입력칸", false); return }
    click(f)
    paste("이 DB 의 테이블을 하나씩 아주 자세히 설명하고, 각 테이블마다 예시 SQL 을 세 개씩 써 줘")
    key("return")
    check("[새 대화] 전: 답하는 중", app.find(15, stop) != nil)
    newChat()
    Thread.sleep(forTimeInterval: 4)
    check("답하는 중 [새 대화] → 앱이 꺼지지 않음", kill(app.pid, 0) == 0)
    check("새 대화는 비어 있고 멈춤 버튼 없음", app.find(1, stop) == nil && app.find(1, hasText("이 DB 의 테이블을 하나씩")) == nil)

    guard let f2 = field() else { check("입력칸 (새 대화)", false); return }
    click(f2)
    paste("이 DB 의 핵심 테이블과 업무 도메인을 아주 자세히 요약해 줘")
    key("return")
    check("데이터 찾기 전: 답하는 중", app.find(15, stop) != nil)
    click(f2)
    paste("회원 전화번호 어디 있어?")
    key("return", cmd)
    check("답하는 중 데이터 찾기 → 첫 답 '(취소했어요)'", app.find(8, hasText("(취소했어요)")) != nil)
    check("답하는 중 데이터 찾기 → 찾기 결과 tb_mbr_info.mbr_tel_no",
          app.find(150, { $0.role == "AXStaticText" && $0.text.contains("tb_mbr_info.mbr_tel_no") }) != nil)
    if let s = app.find(1, stop) { press(s) }
}

scenario("tableDescriptionsMore") {
    // #181: 테이블 메모 메뉴 없음 · 요청문 복사 · 빈 양식 저장 · 내보내기 · 깨진 JSON · 다른 DB 확인 · [아니에요] · [맞아요] · 지우기 · 예전 메모 옮기기
    if let dev = app.find(3, { $0.role == "AXStaticText" && $0.value == "UI MySQL" }) { click(dev) }
    clearFilter()
    if let t = sidebarTable("ui_schools") {
        click(t, right: true)
        Thread.sleep(forTimeInterval: 0.5)
        let items = contextMenuItems()
        check("테이블 우클릭에 '테이블 메모…' 없음", !items.isEmpty && !items.contains { $0.label.contains("테이블 메모") },
              items.map(\.label).joined(separator: ", "))
        key("escape")
    } else { check("사이드바 ui_schools", false) }
    clearSidebarSearch()

    guard openDescriptions() else { check("테이블 설명 창 열기", false); return }
    check("앞 시나리오에서 가져온 설명 (테이블 2개)", app.find(3, { $0.modal && $0.text.contains("테이블 2개 · 컬럼 2개") }) != nil)

    // 요청문 샘플 복사 (양식 안 instructions 와 같은 글)
    setClipboard("")
    if let copy = sheetButton("요청문 샘플 복사") { press(copy) } else { check("[요청문 샘플 복사] 버튼", false) }
    let prompt = clipboard()
    check("요청문 샘플 복사: 양식 이름 · DB 이름", prompt.contains("goddb-table-descriptions") && prompt.contains("`shop`"), String(prompt.prefix(60)))

    // 빈 양식: 이름 · 코멘트 · 지금 설명은 들어가고 데이터 값은 없음
    let skeletonPath = uiWork + "/ui-skeleton.json"
    if let b = sheetButton("빈 양식 내려받기…") { press(b); saveInPanel(skeletonPath) } else { check("[빈 양식 내려받기…] 버튼", false) }
    let skeleton = fileText(skeletonPath)
    check("빈 양식 안에 에이전트가 할 일 (instructions · DB 이름)",
          skeleton.contains("\"instructions\"") && skeleton.contains("`shop`") && skeleton.contains("instructions 칸은 지우기"))
    check("빈 양식 저장: 테이블 · 코멘트(고객 이름) · 기존 title(회원 정보)",
          skeleton.contains("\"ui_customers\"") && skeleton.contains("고객 이름") && skeleton.contains("회원 정보"), String(skeleton.prefix(80)))
    check("빈 양식에 데이터 값 없음 (silver · bronze · 한빛초등학교)",
          !skeleton.isEmpty && !skeleton.contains("silver") && !skeleton.contains("bronze") && !skeleton.contains("한빛초등학교"))

    // 내보내기
    let exportPath = uiWork + "/ui-export.json"
    if let b = sheetButton("내보내기…") { press(b); saveInPanel(exportPath) }
    let exported = fileText(exportPath)
    check("내보내기: 가져온 설명 그대로 (회원 정보 · 연락처 · 코드 값)",
          exported.contains("회원 정보") && exported.contains("연락처") && exported.contains("\"kim\""), String(exported.prefix(80)))

    // 깨진 JSON: 어디가 틀렸는지
    if let b = sheetButton("JSON 가져오기…") { press(b); chooseInOpenPanel(uiWork + "/ui-bad.json") }
    check("깨진 양식 → 'tables[0].columns[0].values' 위치 안내",
          app.find(4, { $0.modal && $0.text.contains("양식이 맞지 않아요: tables[0].columns[0].values") }) != nil)
    check("깨진 양식은 넣지 않음 (그대로 테이블 2개)", app.find(2, { $0.modal && $0.text.contains("테이블 2개 · 컬럼 2개") }) != nil)

    // 다른 DB 이름 → 확인 창 → 취소
    if let b = sheetButton("JSON 가져오기…") { press(b); chooseInOpenPanel(uiWork + "/ui-other-db.json") }
    check("다른 DB 의 JSON → 넣을지 확인", app.find(4, hasText("‘other_db’ DB 용이에요")) != nil)
    answer("취소")
    check("취소하면 그대로 (테이블 2개)", app.find(3, { $0.modal && $0.text.contains("테이블 2개 · 컬럼 2개") }) != nil)
    if !answer("닫기") { key("escape") }

    // [아니에요] (설명에서 찾은 답) → 설명에서 그 말이 빠짐
    guard let ai = app.find(3, { $0.role == "AXButton" && $0.label.contains("AI 어시스턴트") }) else { throw Abort(message: "AI 버튼 없음") }
    click(ai)
    func find(_ q: String, expect: [String], timeout: Double) -> Bool {
        if let finder = app.find(2, { $0.role == "AXButton" && $0.text.contains("데이터 위치 찾기") }) { press(finder) }
        guard let f = app.find(3, { ["AXTextField", "AXTextArea"].contains($0.role)
            && ($0.label.contains("찾을 데이터") || $0.label.contains("질문을 입력")) }) else { return false }
        click(f)
        paste(q)
        key("return")
        return app.find(timeout, { n in n.role == "AXStaticText" && expect.contains { n.text.contains($0) } }) != nil
    }
    // 같은 대화에 앞 카드가 남아 있을 수 있어 가장 아래(최신) 카드의 버튼을 누른다
    func cardButton(_ title: String) -> Node? {
        _ = app.find(3, { $0.role == "AXButton" && $0.label.components(separatedBy: " | ").contains(title) })
        return app.snapshot().filter { $0.role == "AXButton" && $0.label.components(separatedBy: " | ").contains(title) }
            .max { $0.frame.minY < $1.frame.minY }
    }
    if let b = app.find(2, { $0.role == "AXButton" && $0.label.contains("새 대화") }) { press(b) }
    check("데이터 찾기 '연락처' → 설명에서 바로", find("연락처 어디 있어?", expect: ["tb_mbr_info.mbr_tel_no"], timeout: 8))
    if let no = cardButton("아니에요") { press(no) } else { check("[아니에요] 버튼", false) }
    // [맞아요] (AI 답) → 설명에 찾는 말이 더해짐
    check("데이터 찾기 '학년' → AI 답",
          find("학년 정보는 어디 있어?", expect: ["tb_stdnt_info.schyr", "ui_students.grade_level"], timeout: 150))
    if let yes = cardButton("맞아요") { press(yes) } else { check("[맞아요] 버튼", false) }
    click(ai)

    guard openDescriptions() else { check("테이블 설명 창 다시 열기", false); return }
    let export2 = uiWork + "/ui-export2.json"
    if let b = sheetButton("내보내기…") { press(b); saveInPanel(export2) }
    let after = fileText(export2)
    check("[아니에요] → 설명에서 '연락처' 빠짐 (title 은 그대로)", !after.isEmpty && !after.contains("연락처") && after.contains("회원 전화번호"))
    check("[맞아요] → 설명에 '학년' 이 찾는 말로 들어감", after.contains("학년"), String(after.prefix(120)))

    // 지우기 (확인)
    let clearButton = sheetButton("지우기")
    if let b = clearButton { press(b) }
    check("지우기 확인 창", app.find(3, hasText("이 DB 의 테이블 설명을 지울까요?")) != nil)
    // 창 안의 [지우기] 와 이름이 같아서, 위치가 다른 (확인 창의) 버튼을 누른다
    if let confirm = app.snapshot().first(where: { $0.modal && button("지우기")($0) && $0.frame != clearButton?.frame }) {
        press(confirm)
    } else { check("확인 창의 [지우기]", false) }
    check("지운 뒤 '아직 테이블 설명이 없어요'", app.find(4, { $0.modal && $0.text.contains("아직 테이블 설명이 없어요") }) != nil)
    if !answer("닫기") { key("escape") }

    // 예전 테이블 메모(table-notes.json, 운영 접속)는 확인된 것만 옮겨져 있다
    guard let prod = app.find(3, role("AXStaticText", "UI MySQL Prod")) else { check("운영 테스트 접속", false); return }
    click(prod)
    _ = app.find(10, hasText("운영 접속 ·"))
    guard openDescriptions() else { check("운영 접속 테이블 설명 창", false); return }
    check("예전 메모 옮기기: 확인된 메모 1개 → 테이블 1개 · 컬럼 1개",
          app.find(4, { $0.modal && $0.text.contains("테이블 1개 · 컬럼 1개 · 코드 값 0개") }) != nil)
    check("옮긴 메모 테이블 ui_schools 가 목록에", app.find(2, { $0.modal && $0.role == "AXStaticText" && $0.value == "ui_schools" }) != nil)
    check("미확인(AI) 메모 ui_students 는 옮기지 않음", app.find(1, { $0.modal && $0.role == "AXStaticText" && $0.value == "ui_students" }) == nil)
    if !answer("닫기") { key("escape") }
}

scenario("pgProcedure") {
    // #176: PostgreSQL 프로시저 정의가 본문만이 아니라 CREATE OR REPLACE PROCEDURE 전체 (함수도 그대로)
    guard let row = app.find(5, { !$0.modal && $0.role == "AXStaticText" && $0.value == "UI PostgreSQL" }) else {
        throw Abort(message: "UI PostgreSQL 접속이 없어요")
    }
    click(row)
    guard app.find(30, { $0.role == "AXPopUpButton" && $0.value == "public" }) != nil else { check("[PG] 연결", false); return }
    func open(_ name: String) -> String {
        // 테이블이 많으면 루틴 줄은 화면 밖이라 그려지지 않는다 → 사이드바 검색(루틴도 거른다)으로 찾는다
        guard let r = sidebarTable(name) else { return "(사이드바에 \(name) 없음)" }
        click(r, double: true)
        let end = Date().addingTimeInterval(6)
        repeat {
            let t = editorText()
            if t.contains(name) && t.contains("CREATE") { return t }
            Thread.sleep(forTimeInterval: 0.3)
        } while Date() < end
        return editorText()
    }
    let proc = open("ui_touch")
    check("[PG] 프로시저 정의 = CREATE OR REPLACE PROCEDURE 전체", proc.contains("CREATE OR REPLACE PROCEDURE public.ui_touch"), String(proc.prefix(80)))
    let fn = open("ui_add")
    check("[PG] 함수 정의 = CREATE OR REPLACE FUNCTION 전체", fn.contains("CREATE OR REPLACE FUNCTION public.ui_add"), String(fn.prefix(80)))
    clearSidebarSearch()
}

/// 사이드바 접속 줄 (이름 그대로)
/// 사이드바 접속 줄 (이름 그대로). 쿼리 화면에도 접속 이름이 보일 수 있어 찾기 칸과 같은 가로 범위만 본다
func connRow(_ name: String) -> Node? {
    let field = app.find(2, { !$0.modal && $0.role == "AXTextField" && $0.label.contains("접속 찾기") })?.frame
    return app.find(2, { n in !n.modal && n.role == "AXStaticText" && n.value == name
        && (field.map { n.frame.midX > $0.minX - 40 && n.frame.midX < $0.maxX + 40 } ?? true) })
}

/// 마우스로 끌어다 놓기 (조금씩 움직여 끌기로 인식되게)
func drag(_ from: Node, to: Node) {
    let a = CGPoint(x: from.frame.midX, y: from.frame.midY), b = CGPoint(x: to.frame.midX, y: to.frame.midY)
    post(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: a, mouseButton: .left))
    post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: a, mouseButton: .left))
    Thread.sleep(forTimeInterval: 0.3)
    for i in 1...20 {
        let t = CGFloat(i) / 20
        post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged,
                     mouseCursorPosition: CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t), mouseButton: .left))
        Thread.sleep(forTimeInterval: 0.03)
    }
    Thread.sleep(forTimeInterval: 0.3)
    post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: b, mouseButton: .left))
    Thread.sleep(forTimeInterval: 0.8)
}

/// 그 자리에서 마우스로 끌기 (오프셋만큼)
func drag(_ from: Node, by d: CGVector) {
    let a = CGPoint(x: from.frame.midX, y: from.frame.midY)
    post(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: a, mouseButton: .left))
    post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: a, mouseButton: .left))
    Thread.sleep(forTimeInterval: 0.2)
    for i in 1...20 {
        let t = CGFloat(i) / 20
        post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged,
                     mouseCursorPosition: CGPoint(x: a.x + d.dx * t, y: a.y + d.dy * t), mouseButton: .left))
        Thread.sleep(forTimeInterval: 0.02)
    }
    post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: CGPoint(x: a.x + d.dx, y: a.y + d.dy), mouseButton: .left))
    Thread.sleep(forTimeInterval: 0.6)
}

scenario("connList") {
    // 접속 목록 찾기 · 정렬 · 순서 바꾸기 (#173). 테스트 접속: UI MySQL(그룹 없음), UI 그룹 > UI MySQL Prod, UI 닫힌 포트
    guard let field = app.find(3, { !$0.modal && $0.role == "AXTextField" && $0.label.contains("접속 찾기") }) else {
        throw Abort(message: "접속 찾기 칸이 없어요")
    }
    click(field)
    paste("닫힌")
    let closedShown = connRow("UI 닫힌 포트") != nil
    Thread.sleep(forTimeInterval: 0.6)
    let prodHidden = connRow("UI MySQL Prod") == nil
    check("찾기: '닫힌' → UI 닫힌 포트만", closedShown && prodHidden, "닫힌 포트 \(closedShown) · Prod 숨김 \(prodHidden)")
    check("찾기: 개수 '6개 중 1개'", app.find(2, hasText("6개 중 1개")) != nil)
    key("escape")
    check("esc 로 지우면 다시 다 보임", connRow("UI MySQL Prod") != nil && connRow("UI MySQL") != nil)

    // 그룹 우클릭 > 순서 바꾸기 > 맨 위로 → 'UI 둘째 그룹' 이 'UI 그룹' 위로
    // 그룹 줄은 "그룹 이름, 접속 수" 로 읽히는 머리글
    func groupLabel(_ g: String) -> Node? { app.find(2, { !$0.modal && $0.role == "AXHeading" && $0.label.hasPrefix(g + ",") }) }
    if let g2 = groupLabel("UI 둘째 그룹"), let g1 = groupLabel("UI 그룹") {
        check("처음: UI 그룹이 UI 둘째 그룹 위", g1.frame.minY < g2.frame.minY)
        click(g2, right: true)
        if let sub = findMenuItem(3, { $0.label.contains("순서 바꾸기") }) { press(sub) }
        if let top = findMenuItem(3, { $0.label.components(separatedBy: " | ").first == "맨 위로" }) {
            press(top)
            Thread.sleep(forTimeInterval: 0.6)
            if let a = groupLabel("UI 둘째 그룹"), let b = groupLabel("UI 그룹") {
                check("그룹 맨 위로: UI 둘째 그룹이 UI 그룹 위로", a.frame.minY < b.frame.minY)
            } else { check("그룹 맨 위로 뒤 그룹 줄", false) }
        } else { check("그룹 우클릭 > 순서 바꾸기 > 맨 위로", false); key("escape"); key("escape") }
    } else { check("테스트 그룹 두 개", false) }

    // 우클릭 > 순서 바꾸기 > 맨 위로 (같은 그룹 안: 닫힌 포트가 Prod 위로)
    guard let closed = connRow("UI 닫힌 포트") else { throw Abort(message: "UI 닫힌 포트 없음") }
    click(closed, right: true)
    if let sub = findMenuItem(3, { $0.label.contains("순서 바꾸기") }) { press(sub) }
    guard let top = findMenuItem(3, { $0.label.components(separatedBy: " | ").first == "맨 위로" }) else {
        check("우클릭 > 순서 바꾸기 > 맨 위로", false); key("escape"); key("escape"); return
    }
    press(top)
    Thread.sleep(forTimeInterval: 0.6)
    if let c = connRow("UI 닫힌 포트"), let p = connRow("UI MySQL Prod") {
        check("맨 위로: 그룹 안에서 UI 닫힌 포트가 UI MySQL Prod 위로", c.frame.minY < p.frame.minY)
    } else { check("맨 위로 뒤 접속 줄", false) }

    // 정렬 메뉴 > 이름순 → 다시 Prod 가 위 (M < 닫)
    let isSortMenu: (Node) -> Bool = { !$0.modal && $0.label.contains("접속 목록 정렬") && ["AXMenuButton", "AXPopUpButton", "AXButton"].contains($0.role) }
    guard let sortButton = app.find(3, isSortMenu) else {
        check("정렬 메뉴 버튼", false); return
    }
    check("정렬 메뉴 처음 값 '직접 정한 순'", sortButton.text.contains("직접 정한 순"), sortButton.text)
    // 머리글 전체가 단추 범위로 잡혀 오른쪽 끝(보이는 글자)을 실제로 누른다
    clickAt(CGPoint(x: sortButton.frame.maxX - 15, y: sortButton.frame.midY))
    Thread.sleep(forTimeInterval: 0.6)
    // 메뉴 항목이 손쉬운 사용 목록에 잡히지 않아 위치로 누른다: 단추 바로 아래 두 번째 줄 = 이름순
    clickAt(CGPoint(x: sortButton.frame.maxX - 60, y: sortButton.frame.midY + 55))
    Thread.sleep(forTimeInterval: 0.6)
    // 이름순이면 그룹도 이름순: 앞에서 맨 위로 올린 'UI 둘째 그룹' 이 다시 'UI 그룹' 아래로
    if let a = groupLabel("UI 그룹"), let b = groupLabel("UI 둘째 그룹") {
        check("이름순: 그룹도 이름순 (UI 그룹이 UI 둘째 그룹 위)", a.frame.minY < b.frame.minY)
    } else { check("이름순 뒤 그룹 줄", false) }
    check("정렬 메뉴 글자 '이름순'", app.find(2, { isSortMenu($0) && $0.value.contains("이름순") }) != nil)

    // 끌어다 놓기: UI 둘째 그룹 접속을 UI 닫힌 포트 위에 놓으면 UI 그룹으로 → 정렬은 '직접 정한 순' 으로
    // (연결된 접속을 끄는 경우는 아직 자동 테스트에서 끌기가 시작되지 않아 따로 확인)
    if let mover = connRow("UI 둘째 그룹 접속"), let target = connRow("UI 닫힌 포트") {
        drag(mover, to: target)
        // UI 그룹: Prod · 닫힌 포트 · 둘째 그룹 접속 → 머리글 "UI 그룹, 3"
        // 머리글: "UI 그룹, [연결된 수, ]접속 수 | …" → 마지막 숫자
        let count = groupLabel("UI 그룹")?.label.components(separatedBy: " | ").first?.components(separatedBy: ", ").last
        check("끌어다 놓기: 다른 그룹 접속이 UI 그룹으로 (그룹 3개)", count == "3",
              groupLabel("UI 그룹")?.label ?? "그룹 줄 없음")
        check("끌어다 놓은 뒤 정렬이 '직접 정한 순'", app.find(2, { isSortMenu($0) && $0.value.contains("직접 정한 순") }) != nil)
    } else { check("끌어다 놓기 준비", false) }
}

// MARK: - PostgreSQL · SQL Server (#180): MySQL 과 같은 핵심 흐름을 다른 DB 에서

struct OtherDB {
    let key: String
    /// 사이드바 접속 이름
    let name: String
    /// 사이드바 DB/스키마 선택에 보이는 값 (PostgreSQL 은 스키마)
    let container: String
    /// 보정 SQL 에 나오는 테이블 이름 모양
    let quotedOrders: String
}

let otherDBs = [
    OtherDB(key: "postgres", name: "UI PostgreSQL", container: "public", quotedOrders: "\"ui_orders\""),
    OtherDB(key: "sqlServer", name: "UI SQL Server", container: "shop", quotedOrders: "[ui_orders]"),
]

for db in otherDBs {
    scenario(db.key) {
        func label(_ s: String) -> String { "[\(db.name)] " + s }
        func help() -> String { editor().flatMap { attr($0.el, "AXHelp") as? String } ?? "" }

        // 연결: 사이드바 DB/스키마 선택에 기본 값이 보이고 쿼리 탭이 열림
        guard let row = app.find(5, { !$0.modal && $0.role == "AXStaticText" && $0.value == db.name }) else {
            throw Abort(message: "\(db.name) 접속이 사이드바에 없어요")
        }
        click(row)
        // SQL Server 테스트 컨테이너는 Apple 칩에서 에뮬레이션이라 연결 · 스키마 읽기가 느리다
        let ready = app.find(45, { $0.role == "AXPopUpButton" && $0.value == db.container }) != nil
        check(label("연결 · \(db.container) · 쿼리 탭"), ready && app.find(10, role("AXTextArea")) != nil)
        guard ready else { return }
        clearFilter()
        check(label("사이드바에 ui_orders"), sidebarTable("ui_orders") != nil)
        clearSidebarSearch()

        // SELECT · 행 수
        try setEditor("SELECT id, customer, amount FROM ui_orders ORDER BY id")
        check(label("SELECT 실행 · 결과 표"), runAndWait(10, cell("park")) != nil)
        check(label("결과 행 수 (5행)"), app.find(3, hasText("5행")) != nil)

        // 결과 ⌘C
        try setEditor("SELECT id, customer, note FROM ui_orders ORDER BY id")
        if let lee = runAndWait(10, cell("lee")) {
            click(lee)
            setClipboard("")
            key("c", cmd)
            let copied = clipboard()
            check(label("결과 표 ⌘C (머리글 포함 TSV)"), copied.hasPrefix("id\tcustomer\tnote") && copied.contains("2\tlee\tapple, pie"), copied)
        } else { check(label("결과 표 ⌘C"), false, "결과 없음") }

        // 빨간 밑줄: GodDB 검사 · DB 검사 (실행 안 함) · 올바른 쿼리
        try setEditor("SELECT a.id, a.custmer, a.amount FROM ui_orders a")
        Thread.sleep(forTimeInterval: 0.8)
        check(label("없는 컬럼 빨간 밑줄 (custmer → customer)"), help().contains("custmer") && help().contains("customer"), help())
        try setEditor("SELECT custmer FROM ui_orders a JOIN ui_orders b ON a.id = b.id")
        Thread.sleep(forTimeInterval: 3)
        check(label("DB 검사 결과 표시"), help().contains("DB 검사") && help().contains("custmer"), help())
        try setEditor("SELECT id, customer FROM ui_orders ORDER BY id")
        Thread.sleep(forTimeInterval: 3)
        check(label("올바른 쿼리는 밑줄 없음"), help().isEmpty, help())

        // 위험 문장 확인 → 취소하면 실행 안 됨
        try setEditor("DELETE FROM ui_orders")
        runQuery()
        check(label("WHERE 없는 DELETE 는 실행 전 확인"), app.find(4, hasText("되돌리기 어려운 문장이 있어요")) != nil)
        answer("취소")
        try setEditor("SELECT COUNT(*) AS n FROM ui_orders")
        runQuery()
        check(label("취소하면 그대로 5행"), app.find(8, { $0.value == "5" }) != nil)

        // 외래 키 따라가기
        try setEditor("SELECT id, customer, customer_id FROM ui_orders ORDER BY id")
        if let fk = runAndWait(10, cell("20")) {
            check(label("외래 키 컬럼 머리글에 ↗"), app.find(2, { $0.text.contains("customer_id ↗") }) != nil)
            cmdClick(fk)
            check(label("⌘ 클릭 → '↗ ui_customers' (silver)"),
                  app.find(8, hasText("↗ ui_customers")) != nil && app.find(8, cell("silver")) != nil && app.find(1, cell("gold")) == nil)
        } else { check(label("외래 키 결과"), false) }

        // 칸 그 자리 편집 → 적용 (UPDATE) → 원래 값으로
        clearFilter()
        try setEditor("SELECT id, customer, note FROM ui_orders ORDER BY id")
        if runAndWait(10, cell("last")) != nil, openInlineEditor("last") != nil {
            paste("inline ok")
            key("return")
            check(label("칸 편집 → 변경 1건"), app.find(3, hasText("변경 1건")) != nil)
            check(label("[적용…] → 다시 읽은 값 'inline ok'"),
                  applyEdits() && app.find(8, cell("inline ok")) != nil && app.find(1, cell("last")) == nil)
            Thread.sleep(forTimeInterval: 0.8)
            if openInlineEditor("inline ok") != nil {
                paste("last")
                key("return")
                check(label("원래 값 'last' 로 되돌림"), applyEdits() && app.find(8, cell("last")) != nil)
            }
        } else { check(label("칸 더블클릭 → 그 자리 입력란"), false) }

        // 스키마 비교: 기본 → shop_cmp (ui_orders.note 없음, ui_customers.name 코멘트 다름)
        guard let seg = app.find(3, { $0.role == "AXRadioButton" && $0.label == "스키마 비교" }) else { check(label("스키마 비교 모드"), false); return }
        click(seg)
        defer { if let q = app.find(2, { $0.role == "AXRadioButton" && $0.label == "쿼리" }) { click(q) } }
        Thread.sleep(forTimeInterval: 1)
        try startCompare(source: db.name + " · 개발", target: db.name + " · 개발", sourceDB: db.container, targetDB: "shop_cmp")
        let orders = app.find(25, diffRow("ui_orders", "컬럼 없음"))
        let customers = app.find(2, diffRow("ui_customers", "코멘트 변경"))
        check(label("스키마 비교: ui_orders 컬럼 없음 · ui_customers 코멘트 변경"), orders != nil && customers != nil)
        if let o = orders {
            click(o)
            setClipboard("")
            key("c", cmd)
            let copied = clipboard()
            check(label("스키마 비교: 보정 SQL 에 note 컬럼 추가"), copied.contains(db.quotedOrders) && copied.contains("note") && copied.uppercased().contains("ADD"), copied)
        }
    }
}

scenario("modeling") {
    // 모델링: 새 모델 → 테이블 추가 → 이름 수정 → 1:N 관계 → 카드 이동 → 되돌리기 → 테이블 삭제 → 모델 삭제
    guard let seg = app.find(3, { $0.role == "AXRadioButton" && $0.label == "모델링" }) else { throw Abort(message: "모델링 모드 버튼 없음") }
    click(seg)
    defer { if let q = app.find(2, { $0.role == "AXRadioButton" && $0.label == "쿼리" }) { click(q) } }
    func tool(_ name: String) -> Node? { app.find(3, { $0.role == "AXButton" && $0.label.contains(name + " —") }) }
    // 다이어그램 카드의 이름 (아래 편집기에도 같은 이름이 보일 수 있어 가장 위의 것)
    func cardText(_ name: String) -> Node? {
        let isName: (Node) -> Bool = { !$0.modal && $0.role == "AXStaticText" && $0.value == name }
        guard app.find(3, isName) != nil else { return nil }
        return app.snapshot().filter(isName).min { $0.frame.minY < $1.frame.minY }
    }
    func summary(_ t: Int, _ r: Int) -> Bool { app.find(4, hasText("테이블 \(t) · 관계 \(r)")) != nil }

    // 새 모델 (빈 화면의 [새 모델], 모델이 있으면 + 메뉴)
    if let b = app.find(2, button("새 모델")) {
        press(b)
    } else if let plus = app.find(2, { $0.role == "AXMenuButton" && $0.label.contains("새 모델 / 리버스") }) {
        press(plus)
        if let item = app.find(3, { $0.role == "AXMenuItem" && $0.label.hasPrefix("새 모델") }) { press(item) }
    }
    check("새 모델: 기본 테이블 '회원' (테이블 1 · 관계 0)", cardText("회원") != nil && summary(1, 0))
    guard let member = cardText("회원") else { return }

    // 테이블 추가: 도구 고르고 빈 곳 누르기
    guard let add = tool("테이블 추가") else { check("테이블 추가 도구", false); return }
    press(add)
    clickAt(CGPoint(x: member.frame.maxX + 260, y: member.frame.maxY + 160))
    check("테이블 추가 → 테이블 2 · 관계 0", summary(2, 0))

    // 수정: 새 테이블이 선택돼 아래 편집기 → 논리명 · 물리명
    guard let logical = app.find(4, { $0.role == "AXTextField" && $0.label.contains("논리명") }),
          let physical = app.find(2, { $0.role == "AXTextField" && $0.label.contains("물리명") }) else {
        check("새 테이블 편집기 (논리명 · 물리명)", false); return
    }
    click(logical); key("a", cmd); paste("주문"); key("tab")
    click(physical); key("a", cmd); paste("tb_order"); key("tab")
    check("논리명 수정 → 카드에 '주문'", cardText("주문") != nil)
    guard let order = cardText("주문") else { return }

    // 관계: 1:N → 부모(회원) → 자식(주문)
    if let rel = tool("1:N 비식별 관계") {
        press(rel)
        // 편집기가 열리며 다이어그램이 다시 배치되므로 누르기 직전에 카드를 다시 찾는다
        if let m = cardText("회원") { click(m) }
        Thread.sleep(forTimeInterval: 0.4)
        if let o = cardText("주문") { click(o) }
        check("1:N 관계 → 테이블 2 · 관계 1", summary(2, 1),
              app.snapshot().first { $0.text.contains("관계 ·") || $0.text.contains("테이블 2 · 관계") }?.text ?? "")
    } else { check("1:N 관계 도구", false) }

    // 이동: 선택 도구로 카드를 끌기 → 위치 바뀜 → 되돌리기로 제자리
    if let sel = tool("선택 / 이동") { press(sel) }
    guard let before = cardText("주문")?.frame else { return }
    drag(cardText("주문")!, by: CGVector(dx: 140, dy: 90))
    // 끈 만큼 옮겨진 '주문' 글자가 있어야 (아래 편집기의 같은 글자와 헷갈리지 않게 위치로 찾는다)
    let moved = app.snapshot().first { !$0.modal && $0.role == "AXStaticText" && $0.value == "주문"
        && abs($0.frame.minX - (before.minX + 140)) < 25 && abs($0.frame.minY - (before.minY + 90)) < 25 }
    check("카드 끌기 → 끈 만큼 이동 (+140, +90)", moved != nil, "\(before.origin) → \(moved?.frame.origin.debugDescription ?? "못 찾음")")
    if let undo = tool("되돌리기") {
        press(undo)
        let back = cardText("주문")?.frame ?? .zero
        check("되돌리기 → 제자리", abs(back.minX - before.minX) < 5 && abs(back.minY - before.minY) < 5, "\(back.origin)")
    } else { check("되돌리기 버튼", false) }

    // 테이블 삭제: 카드 선택 → 편집기 휴지통 → 확인
    if let o = cardText("주문") { click(o) }
    if let trash = app.find(3, { $0.role == "AXButton" && $0.label.contains("테이블 삭제") }) {
        press(trash)
        let confirmed = answer("삭제")
        check("테이블 삭제 → 테이블 1, '주문' 카드 없음", summary(1, 0) && app.gone(3, { $0.role == "AXStaticText" && $0.value == "주문" }),
              "확인 창 \(confirmed) · " + (app.snapshot().first { $0.text.contains("테이블 ") && $0.text.contains("· 관계") }?.text ?? ""))
    } else { check("테이블 삭제 버튼", false) }
    closeLeftovers()

    // 모델 삭제: 목록 우클릭 > 삭제… → 확인
    if let row = app.find(3, { !$0.modal && $0.role == "AXStaticText" && $0.value.hasPrefix("새 모델") && $0.frame.minX < 700 }) {
        click(row, right: true)
        if let del = findMenuItem(3, { $0.label.hasPrefix("삭제") }) {
            press(del)
            answer("삭제")
            check("모델 삭제 → '모델이 없어요'", app.find(4, hasText("모델이 없어요")) != nil)
        } else { check("모델 우클릭 '삭제…'", false); key("escape") }
    } else { check("모델 목록 줄", false, app.snapshot().filter { $0.value.hasPrefix("새 모델") }.map { "\($0.role) \($0.frame.origin)" }.joined(separator: ", ")) }
}

scenario("editAlias") {
    // 결과 편집: 다른 컬럼에 기본 키 이름 별칭(customer AS id)이면 편집 불가, 별칭 없는 조회는 그대로 편집 (#194)
    if let dev = app.find(3, { $0.role == "AXStaticText" && $0.value == "UI MySQL" }) { click(dev) }
    clearFilter()
    try setEditor("SELECT customer AS id, amount FROM ui_orders ORDER BY amount")
    guard runAndWait(8, cell("jung")) != nil else { throw Abort(message: "결과가 없어요") }
    check("별칭 기본 키 → '편집 불가' 표시", app.find(4, { $0.text.contains("편집 불가") && $0.text.contains("기본 키") }) != nil)
    if let c = app.find(3, cell("jung")) { click(c, double: true) }
    check("별칭 결과는 칸 더블클릭해도 그 자리 입력란이 안 열림",
          app.gone(2, { $0.role == "AXTextField" && $0.label.contains("칸 편집") }))
    key("escape")
    try setEditor("SELECT id, customer AS customer, amount FROM ui_orders ORDER BY id")
    guard runAndWait(8, cell("jung")) != nil else { throw Abort(message: "결과가 없어요") }
    check("같은 이름 별칭은 그대로 편집 가능 (편집 불가 없음)", app.gone(3, hasText("편집 불가")))
}

scenario("dbeaverPasswords") {
    // DBeaver 가져오기: 저장된 비밀번호가 있는 접속 / 없는 접속의 안내 (#195). 키체인에 쓰지 않게 [취소] 로 닫는다
    guard let dir = ProcessInfo.processInfo.environment["GODDB_UI_DBEAVER_DIR"] else { throw Abort(message: "DBeaver 테스트 파일 없음") }
    guard let menu = app.find(3, { $0.role == "AXMenuButton" && $0.label.contains("가져오기 · 내보내기") }) else {
        throw Abort(message: "가져오기 · 내보내기 메뉴 없음")
    }
    press(menu)
    guard let item = app.find(3, { $0.role == "AXMenuItem" && $0.label.hasPrefix("DBeaver 접속 정보 가져오기") }) else {
        key("escape"); throw Abort(message: "DBeaver 가져오기 메뉴 항목 없음")
    }
    press(item)
    Thread.sleep(forTimeInterval: 1.2)
    // 파일 고르기 창: ⇧⌘G → 경로 → ↩ → 열기
    key("g", [cmd, shift])
    Thread.sleep(forTimeInterval: 0.6)
    paste(dir + "/data-sources.json")
    key("return")
    Thread.sleep(forTimeInterval: 0.8)
    key("return")
    let opened = app.find(8, hasText("UI DBeaver 비밀번호 있음")) != nil
    check("DBeaver 파일 → 가져오기 창에 접속 2개", opened && app.find(2, hasText("UI DBeaver 비밀번호 없음")) != nil)
    check("비밀번호 저장된 접속: '비밀번호도 가져와 키체인에' 안내",
          app.find(3, hasText("DBeaver 에 저장된 비밀번호도 가져와 키체인에 넣어요.")) != nil)
    check("비밀번호 없는 접속: '처음 연결할 때 입력' 안내", app.find(2, hasText("비밀번호는 처음 연결할 때 입력해요.")) != nil)
    check("가져오기 창에 비밀번호 글자가 보이지 않음", !app.snapshot().contains { $0.text.contains("ui-secret") })
    if !answer("취소", timeout: 2) { key("escape") }
}

// 디버그: uitest <pid> --dump  → 지금 화면 요소 목록
if CommandLine.arguments.dropFirst(2).first == "--dump" {
    for n in app.snapshot() where !["AXRow", "AXCell", "AXColumn", "AXScrollBar", "AXValueIndicator"].contains(n.role)
        && (n.role != "AXGroup" || !n.label.isEmpty) {
        print((n.modal ? "* " : "  ") + n.role + " [" + n.label + "] " + String(n.value.prefix(70)).replacingOccurrences(of: "\n", with: "⏎"))
    }
    exit(0)
}
let wanted = Set(CommandLine.arguments.dropFirst(2))
for (name, body) in scenarios where wanted.isEmpty || wanted.contains(name) {
    app.activate()
    do { try body() } catch let e as Abort { check(name, false, e.message) } catch { check(name, false, "\(error)") }
    closeLeftovers()
}
print("")
print("결과: \(report.count - failures)/\(report.count) 통과")
exit(failures == 0 ? 0 : 1)
