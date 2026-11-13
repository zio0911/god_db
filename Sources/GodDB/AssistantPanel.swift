import GodDBCore
import Observation
import SwiftUI

/// 메인 창 오른쪽 AI 어시스턴트 상태: 범위(접속·DB / 모델)별 대화, 테이블 통계 캐시
@MainActor
@Observable
final class AssistantState {
    var visible: Bool = UserDefaults.standard.bool(forKey: "GodDB.assistant.visible") {
        didSet { UserDefaults.standard.set(visible, forKey: "GodDB.assistant.visible") }
    }
    var width: CGFloat = 400
    var includeSQL = true
    private var chats: [String: DiagramChat] = [:]
    /// "접속ID|DB" → 테이블 통계
    var stats: [String: [String: TableStats]] = [:]

    func chat(_ scope: String) -> DiagramChat {
        if let c = chats[scope] { return c }
        let c = DiagramChat(scope: scope)
        chats[scope] = c
        return c
    }
}

extension AppState {
    /// 지금 화면의 대화 범위
    var assistantScope: String {
        if mode == .modeling, let id = modeling.selectedID { return "assistant|model|\(id.uuidString)" }
        if let p = selectedProfileID, state == .connected { return "assistant|\(p.uuidString)|\(currentDatabase)" }
        return "assistant|general"
    }

    var assistantTitle: String {
        if mode == .modeling, let m = modeling.selected { return tr("모델 · %@", m.name) }
        if let p = selectedProfile, state == .connected {
            return p.kind == .redis ? p.name : "\(p.name) / \(currentDatabase)"
        }
        return tr("접속 안 됨")
    }

    /// 자세히 볼 테이블: 질문에 나온 것 + 사이드바에서 고른 것 + 지금 탭의 테이블
    func assistantFocus(question: String) -> [TableMeta] {
        var out = AssistantAI.mentionedTables(question, in: tables)
        var names = Set(out.map(\.name))
        var extra = Array(selectedTables)
        if case .table(let t)? = selectedTab?.source { extra.append(t) }
        if let sql = assistantIncludesSQL ? selectedTab?.text : nil {
            extra += AssistantAI.mentionedTables(sql, in: tables, limit: 8).map(\.name)
        }
        for n in extra where !names.contains(n) {
            if let t = tables.first(where: { $0.name == n }) { out.append(t); names.insert(n) }
        }
        return Array(out.prefix(12))
    }

    var assistantIncludesSQL: Bool { assistant.includeSQL }

    /// 테이블 통계 (DB 마다 한 번 가져와 둔다; 실패하면 없이 진행)
    func assistantStats() async -> [String: TableStats] {
        guard let p = selectedProfile, let session, state == .connected else { return [:] }
        let key = "\(p.id.uuidString)|\(currentDatabase)"
        if let s = assistant.stats[key] { return s }
        guard let sql = AssistantAI.statsSQL(p.kind, schema: currentDatabase) else { return [:] }
        do {
            let r = try await session.raw(sql)
            let s = AssistantAI.parseStats(r.rows)
            assistant.stats[key] = s
            return s
        } catch {
            log(.warning, .schema, tr("AI 어시스턴트: 테이블 통계를 못 가져와서 구조만 보내요."), detail: ErrorText.describe(error).message)
            assistant.stats[key] = [:]
            return [:]
        }
    }

    /// 앱 사용법 (앱 안의 FEATURES.md, 개발 실행이면 소스 폴더의 docs)
    static let appGuide: AppGuide? = {
        let urls = [Bundle.main.url(forResource: "FEATURES", withExtension: "md"),
                    URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("docs/FEATURES.md")]
        for case let u? in urls { if let t = try? String(contentsOf: u, encoding: .utf8) { return AppGuide(markdown: t) } }
        return nil
    }()

    /// 지금 앱 상태 (질문 "지금 어디 붙어있어?" 같은 것에 답하도록)
    func assistantAppState() -> String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        var s = "  GodDB version: \(version)\n  Mode: \(mode.rawValue)\n"
        s += "  Saved connections: \(profiles.count)"
        let groups = Set(profiles.map(\.group).filter { !$0.isEmpty })
        if !groups.isEmpty { s += " in groups \(groups.sorted().joined(separator: ", "))" }
        s += "\n"
        if let p = selectedProfile {
            s += "  Selected connection: \(p.name) (\(p.kind.title))\(p.readOnly ? ", read-only" : ""), "
            s += state == .connected ? "connected, database/schema \(currentDatabase), \(tables.count) tables\n" : "not connected\n"
        } else {
            s += "  No connection selected\n"
        }
        if !selectedTables.isEmpty { s += "  Tables selected in the sidebar: \(selectedTables.sorted().prefix(10).joined(separator: ", "))\n" }
        s += "  Open query tabs: \(tabs.count)\n"
        if mode == .modeling, let m = modeling.selected { s += "  Open model: \(m.name) (\(m.tables.count) tables, \(m.relations.count) relations)\n" }
        return s
    }

    func assistantGuideText(_ question: String) -> String {
        guard let g = Self.appGuide else {
            return "About this app:\n" + AppGuide.about + "\nCurrent app state:\n" + assistantAppState()
        }
        return g.contextText(question: question, appState: assistantAppState())
    }

    /// 질문 하나에 보낼 메시지 (문맥은 질문할 때마다 새로 모은다)
    func assistantMessages(history: [(role: String, content: String)]) async -> [OllamaClient.Message] {
        let english = L10n.isEnglish
        let question = history.last?.content ?? ""
        let guide = assistantGuideText(question)
        if mode == .modeling, let m = modeling.selected {
            var out: [OllamaClient.Message] = [.init(role: "system", content: ModelAI.systemPrompt(m.kind, english: english))]
            out += history.dropLast().map { .init(role: $0.role, content: $0.content) }
            out.append(.init(role: "user", content: guide + "\nCurrent model:\n" + ModelAI.modelText(m)))
            out.append(.init(role: "assistant", content: english ? "Got the model." : "모델을 확인했어요."))
            out.append(.init(role: "user", content: question))
            return out
        }
        guard let p = selectedProfile, state == .connected else {
            return AssistantAI.messages(kind: selectedProfile?.kind ?? .mysql, context: guide, history: history, english: english)
        }
        if p.kind == .redis {
            let ctx = guide + "\nConnection: \(p.name) (Redis, \(p.redisMode.title)). Key values are not shared with you.\n"
            return AssistantAI.messages(kind: .redis, context: ctx, history: history, english: english)
        }
        let stats = await assistantStats()
        let tab = selectedTab
        let ctx = AssistantAI.Context(kind: p.kind, connection: p.name, database: currentDatabase, tables: tables,
                                      focus: assistantFocus(question: question), stats: stats,
                                      sql: assistant.includeSQL ? tab?.text : nil,
                                      lastError: assistant.includeSQL ? tab?.error : nil)
        return AssistantAI.messages(kind: p.kind, context: guide + "\n" + AssistantAI.contextText(ctx), history: history, english: english)
    }

    func askAssistant(_ question: String) {
        let chat = assistant.chat(assistantScope)
        let scopeTitle = assistantTitle
        chat.ask(question, app: self, logMessage: { model, first in
            first ? tr("AI 어시스턴트 · %@ · %@", model, scopeTitle) : nil
        }, failureContext: tr("AI 어시스턴트 실패")) { [weak self] history in
            guard let self else { return [] }
            return await self.assistantMessages(history: history)
        }
    }
}

/// 메인 창 오른쪽 AI 어시스턴트 패널
struct AssistantPanel: View {
    @Environment(AppState.self) private var app
    @State private var input = ""
    @FocusState private var inputFocused: Bool

    private var unavailable: String? {
        TuningSettings.enabled ? nil : tr("설정 > 쿼리 튜닝에서 Ollama 를 켜 주세요. (같은 모델을 써요)")
    }

    private var isModeling: Bool { app.mode == .modeling && app.modeling.selected != nil }
    private var isSQL: Bool { app.state == .connected && app.selectedProfile?.kind.isSQL == true }

    var body: some View {
        let chat = app.assistant.chat(app.assistantScope)
        VStack(spacing: 0) {
            header(chat)
            Divider()
            contextStrip
            Divider()
            AIChatTranscript(chat: chat, sqlLabel: tr("AI 어시스턴트")) {
                intro(chat)
            } extra: { m in
                if isModeling, m.text.contains("\"tables\""), let id = app.modeling.selectedID {
                    Button {
                        var n = 0
                        app.modeling.edit(id) { n = ModelAI.applyPhysicalNames(m.text, to: &$0) }
                        app.log(n > 0 ? .info : .warning, .schema, n > 0 ? tr("AI 물리명 %@개를 모델에 넣었어요.", "\(n)")
                                                                        : tr("넣을 물리명이 없어요. (비어 있는 칸만 채워요)"))
                    } label: { Label(tr("물리명 적용 (빈 칸만)"), systemImage: "wand.and.stars") }
                        .buttonStyle(.hover)
                }
            }
            .id(app.assistantScope)
            Divider()
            inputBar(chat)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func header(_ chat: DiagramChat) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles").foregroundStyle(.purple)
            VStack(alignment: .leading, spacing: 0) {
                Text(tr("AI 어시스턴트")).font(.headline)
                Text(app.assistantTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button { chat.startNew() } label: { Image(systemName: "plus.bubble") }
                .help(tr("새 대화 (지금 대화는 기록에 남아요)"))
                .disabled(chat.messages.isEmpty)
            Menu {
                if chat.history.isEmpty { Text(tr("저장된 대화가 없어요.")) }
                ForEach(chat.history) { c in
                    Menu {
                        Button(tr("열기")) { chat.open(c) }
                        Button(tr("삭제"), role: .destructive) { chat.delete(c.id) }
                    } label: {
                        Text((c.id == chat.conversationID ? "● " : "") + c.updated.formatted(date: .abbreviated, time: .shortened)
                             + " · " + (c.title.isEmpty ? tr("(제목 없음)") : c.title))
                    }
                }
                if !chat.history.isEmpty {
                    Divider()
                    Button(tr("이 범위의 대화 모두 삭제"), role: .destructive) { chat.deleteAll() }
                }
            } label: { Image(systemName: "clock.arrow.circlepath") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help(tr("이전 대화 (90일 보관)"))
            Button { withAnimation(.easeInOut(duration: 0.2)) { app.assistant.visible = false } } label: {
                Image(systemName: "sidebar.trailing")
            }
            .help(tr("패널 닫기"))
        }
        .buttonStyle(.hover)
        .padding(10)
    }

    /// 이번 질문에 함께 보낼 것
    private var contextStrip: some View {
        @Bindable var assistant = app.assistant
        let focus = isSQL ? app.assistantFocus(question: input) : []
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(tr("함께 보낼 정보")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if isSQL {
                    Toggle(tr("편집기 SQL"), isOn: $assistant.includeSQL).toggleStyle(.checkbox).font(.caption)
                        .help(tr("지금 쿼리 탭의 SQL 과 마지막 오류를 함께 보내요"))
                }
            }
            FlowChips(items: chips(focus: focus))
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    private func chips(focus: [TableMeta]) -> [(String, String)] {
        if isModeling, let m = app.modeling.selected {
            return [("square.3.layers.3d", tr("모델 %@ · 테이블 %@개", m.name, "\(m.tables.count)"))]
        }
        guard app.state == .connected, let p = app.selectedProfile else {
            return [("bolt.slash", tr("접속이 없어서 일반 질문만 할 수 있어요"))]
        }
        if p.kind == .redis { return [("key", tr("Redis 접속 정보 (키 값은 안 보내요)"))] }
        var out: [(String, String)] = [("list.bullet", tr("테이블 목록 %@개", "\(app.tables.count)"))]
        if focus.isEmpty {
            out.append(("questionmark.circle", tr("질문에 테이블 이름(또는 논리명)을 쓰거나 사이드바에서 고르면 구조를 자세히 보내요")))
        } else {
            out.append(("tablecells", tr("자세히: %@", focus.map(\.name).joined(separator: ", "))))
            out.append(("chart.bar", tr("크기 통계 · 자동 점검")))
        }
        if app.assistant.includeSQL, let t = app.selectedTab, !t.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out.append(("terminal", tr("SQL · %@", t.title)))
        }
        return out
    }

    @ViewBuilder
    private func intro(_ chat: DiagramChat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(isModeling ? tr("지금 모델을 바탕으로 검토하거나 물리명을 추천받을 수 있어요.")
                            : tr("지금 접속의 테이블 구조, 코멘트, 인덱스, 크기 통계, 편집기 SQL 을 바탕으로 답해요. 데이터 행은 보내지 않아요."))
                .font(.callout).foregroundStyle(.secondary)
            Text(tr("자주 쓰는 질문")).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 4)
            ForEach(quickActions, id: \.self) { q in
                Button { app.askAssistant(expand(q)) } label: {
                    Label(q, systemImage: "bolt").font(.caption).multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.hover)
                .disabled(unavailable != nil || chat.running)
            }
        }
    }

    private var quickActions: [String] {
        if isModeling {
            return [ModelAI.physicalNameQuestion(english: L10n.isEnglish, kind: app.modeling.selected?.kind ?? .mysql)
                        .split(separator: "\n").first.map(String.init) ?? "",
                    tr("이 모델의 정규화와 키 설계를 검토해 줘"),
                    tr("빠진 관계나 필요한 테이블·컬럼을 제안해 줘"),
                    tr("공통 컬럼(등록일시, 수정일시, 등록자 등) 규칙을 제안해 줘")]
        }
        if isSQL {
            let selected = app.selectedTables.sorted().prefix(3).joined(separator: ", ")
            return [selected.isEmpty ? tr("이 DB 의 핵심 테이블과 업무 도메인을 요약해 줘")
                                     : tr("%@ 테이블을 설명하고 특이사항을 정리해 줘", selected),
                    tr("지금 편집기 SQL 을 설명하고 성능 문제를 점검해 줘"),
                    tr("마지막 오류 원인과 고치는 방법을 알려 줘"),
                    tr("인덱스가 빠졌거나 중복된 테이블을 찾아 줘"),
                    tr("코멘트(논리명)가 없는 테이블·컬럼을 정리해 줘")]
        }
        return [tr("MySQL 과 PostgreSQL 의 트랜잭션 격리 수준 차이를 알려 줘")]
    }

    /// 모델링에서 첫 번째 빠른 질문은 물리명 추천 (JSON 형식 지시 포함 전체 문장을 보낸다)
    private func expand(_ q: String) -> String {
        if isModeling, q == quickActions.first {
            return ModelAI.physicalNameQuestion(english: L10n.isEnglish, kind: app.modeling.selected?.kind ?? .mysql)
        }
        return q
    }

    private func inputBar(_ chat: DiagramChat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let unavailable {
                Text(unavailable).font(.caption).foregroundStyle(.orange)
            }
            HStack(alignment: .bottom, spacing: 6) {
                Menu {
                    ForEach(quickActions, id: \.self) { q in Button(q) { app.askAssistant(expand(q)) } }
                } label: { Image(systemName: "bolt.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help(tr("자주 쓰는 질문"))
                .disabled(unavailable != nil || chat.running)
                TextField(tr("질문을 입력하고 Enter"), text: $input, axis: .vertical)
                    .lineLimit(1...6)
                    .textFieldStyle(.roundedBorder)
                    .focused($inputFocused)
                    .onSubmit(send)
                    .disabled(unavailable != nil)
                if chat.running {
                    Button { chat.cancel() } label: { Image(systemName: "stop.circle.fill") }
                        .help(tr("취소"))
                } else {
                    Button(action: send) { Image(systemName: "arrow.up.circle.fill") }
                        .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || unavailable != nil)
                        .help(tr("보내기"))
                }
            }
            .buttonStyle(.hover)
            .font(.title3)
            Text(tr("구조·코멘트·통계·SQL 만 로컬 Ollama 에 보내요. 데이터 행은 보내지 않아요."))
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(10)
    }

    private func send() {
        let q = input
        guard !q.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        input = ""
        app.askAssistant(q)
        inputFocused = true
    }
}

/// 작은 정보 칩 (줄바꿈되며 나열)
struct FlowChips: View {
    let items: [(String, String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Label(item.1, systemImage: item.0)
                    .font(.caption2)
                    .lineLimit(2)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.purple.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
            }
        }
    }
}
