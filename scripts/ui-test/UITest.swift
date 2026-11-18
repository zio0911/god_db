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

func clickAt(_ p: CGPoint, right: Bool = false, double: Bool = false) {
    let down: CGEventType = right ? .rightMouseDown : .leftMouseDown
    let up: CGEventType = right ? .rightMouseUp : .leftMouseUp
    let button: CGMouseButton = right ? .right : .left
    post(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: button))
    for i in 1...(double ? 2 : 1) {
        let d = CGEvent(mouseEventSource: nil, mouseType: down, mouseCursorPosition: p, mouseButton: button)
        d?.setIntegerValueField(.mouseEventClickState, value: Int64(i))
        post(d)
        let u = CGEvent(mouseEventSource: nil, mouseType: up, mouseCursorPosition: p, mouseButton: button)
        u?.setIntegerValueField(.mouseEventClickState, value: Int64(i))
        post(u)
    }
    Thread.sleep(forTimeInterval: 0.4)
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
    check("좁은 창 + AI 패널: 결과 아래 '1–5행' 이 잘리지 않음", range.map { $0.frame.width + 1 >= needRange } ?? false,
          range.map { "폭 \(Int($0.frame.width)) / 필요 \(Int(needRange))" } ?? "행 범위 없음")
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
