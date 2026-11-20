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
    let isRow: (Node) -> Bool = { !$0.modal && ["AXStaticText", "AXHeading"].contains($0.role) && $0.text.trimmingCharacters(in: .whitespaces) == name }
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
    // 운영 접속 자동 끊기: 테스트용 5초로 줄이고 운영 접속에 붙은 뒤 기다리면 끊긴다
    testDefaults(["write", "local.goddb.app.uitest", "GodDB.safety.prodIdleSecondsForTest", "-int", "5"])
    guard let prod = app.find(3, { $0.role == "AXStaticText" && $0.value == "UI MySQL Prod" }) else { throw Abort(message: "운영 테스트 접속이 없어요") }
    click(prod)
    _ = app.find(10, hasText("운영 접속 ·"))
    try setEditor("SELECT 1 AS v")
    _ = runAndWait(8, cell("1"))
    hideLog()
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
