import GodDBCore
import Observation
import SwiftUI

/// 다이어그램 창의 AI 대화 상태
@MainActor
@Observable
final class DiagramChat {
    struct Message: Identifiable, Equatable {
        let id = UUID()
        let role: String   // "user" / "assistant"
        var text: String
        var failed = false
    }

    var messages: [Message] = []
    var running = false
    var thinkingChars = 0
    var task: Task<Void, Never>?

    /// 대화 기록 (다이어그램마다, 90일 보관)
    let scope: String
    let store: DiagramChatStore
    private(set) var conversationID = UUID()
    private var created = Date()
    var history: [DiagramConversation] = []

    init(scope: String, store: DiagramChatStore = .shared) {
        self.scope = scope
        self.store = store
        history = store.load(scope)
        // 열 때 마지막 대화를 이어서 보여준다
        if let last = history.first { show(last) }
    }

    func cancel() {
        task?.cancel()
        task = nil
        running = false
    }

    private func show(_ c: DiagramConversation) {
        conversationID = c.id
        created = c.created
        messages = c.messages.map { Message(role: $0.role, text: $0.text, failed: $0.failed) }
    }

    /// 지금 대화를 저장 (답이 끝났을 때)
    func persist() {
        guard !messages.isEmpty else { return }
        var c = DiagramConversation(id: conversationID, created: created,
                                    messages: messages.map { .init(role: $0.role, text: $0.text, failed: $0.failed) })
        c.updated = Date()
        store.save(c, scope: scope)
        history = store.load(scope)
    }

    /// 새 대화 시작 (이전 대화는 기록에 남는다)
    func startNew() {
        cancel()
        persist()
        messages = []
        conversationID = UUID()
        created = Date()
    }

    func open(_ c: DiagramConversation) {
        guard c.id != conversationID else { return }
        cancel()
        persist()
        show(c)
    }

    func delete(_ id: UUID) {
        if id == conversationID { cancel() }
        store.delete(id, scope: scope)
        history = store.load(scope)
        if id == conversationID {
            messages = []
            conversationID = UUID()
            created = Date()
        }
    }

    func deleteAll() {
        cancel()
        store.deleteAll(scope: scope)
        history = []
        messages = []
        conversationID = UUID()
        created = Date()
    }

    /// 질문을 보내고 답을 스트리밍으로 받는다.
    func ask(_ question: String, doc: DiagramDoc, app: AppState) {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !running else { return }
        messages.append(.init(role: "user", text: q))
        messages.append(.init(role: "assistant", text: ""))
        let answerIndex = messages.count - 1
        running = true
        thinkingChars = 0
        let history = messages.dropLast().filter { !$0.failed }.map { (role: $0.role, content: $0.text) }
        task = Task { [weak self] in
            guard let self else { return }
            let client = TuningSettings.client
            do {
                guard case .running(let models) = await client.status() else { throw OllamaError.notRunning }
                let model = TuningSettings.model.isEmpty ? (models.first?.name ?? "") : TuningSettings.model
                guard !model.isEmpty else { throw OllamaError.noModel }
                let schema = DiagramAI.schemaText(doc.tables, inferred: doc.inferred)
                let msgs = DiagramAI.messages(kind: doc.kind, schema: schema, history: Array(history),
                                              english: L10n.isEnglish)
                if history.count == 1 {
                    app.log(.info, .schema, tr("다이어그램 AI 분석 · %@ · 테이블 %@개", model, "\(doc.tables.count)"),
                            detail: q)
                }
                var raw = ""
                for try await chunk in client.chat(model: model, messages: msgs, temperature: 0.3) {
                    try Task.checkCancellation()
                    switch chunk {
                    case .thinking(let t): thinkingChars += t.count
                    case .content(let c):
                        raw += c
                        messages[answerIndex].text = DiagramAI.clean(raw)
                    }
                }
                if messages[answerIndex].text.isEmpty { messages[answerIndex].text = tr("(답변 없음)") }
            } catch is CancellationError {
                messages[answerIndex].text += (messages[answerIndex].text.isEmpty ? "" : "\n\n") + tr("(취소했어요)")
            } catch {
                messages[answerIndex].failed = true
                messages[answerIndex].text = app.logError(error, .schema, context: tr("다이어그램 AI 분석 실패"))
            }
            running = false
            task = nil
            persist()
        }
    }
}

/// 다이어그램 오른쪽 AI 패널: 관계 분석 + 채팅
struct DiagramAIPanel: View {
    @Environment(AppState.self) private var app
    let doc: DiagramDoc
    @Bindable var chat: DiagramChat
    @State private var input = ""
    @FocusState private var inputFocused: Bool

    private var unavailable: String? {
        TuningSettings.enabled ? nil : tr("설정 > 쿼리 튜닝에서 Ollama 를 켜 주세요. (같은 모델을 써요)")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").foregroundStyle(.purple)
                Text(tr("AI 관계 분석")).font(.headline)
                Spacer()
                Button { chat.startNew() } label: { Image(systemName: "plus.bubble") }
                    .help(tr("새 대화 (지금 대화는 기록에 남아요)"))
                    .disabled(chat.messages.isEmpty)
                Menu {
                    if chat.history.isEmpty {
                        Text(tr("저장된 대화가 없어요."))
                    }
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
                        Button(tr("이 다이어그램의 대화 모두 삭제"), role: .destructive) { chat.deleteAll() }
                    }
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(tr("이전 대화 (90일 보관)"))
                if !chat.messages.isEmpty {
                    Button { chat.delete(chat.conversationID) } label: { Image(systemName: "trash") }
                        .help(tr("지금 대화 삭제"))
                        .disabled(chat.running)
                }
            }
            .buttonStyle(.hover)
            .padding(10)
            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if chat.messages.isEmpty {
                            intro
                        }
                        ForEach(chat.messages) { m in
                            bubble(m).id(m.id)
                        }
                        if chat.running {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text(chat.thinkingChars > 0 && chat.messages.last?.text.isEmpty == true
                                     ? tr("모델이 생각하는 중… (%@자)", "\(chat.thinkingChars)")
                                     : tr("답변을 쓰는 중…"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .id("progress")
                        }
                    }
                    .padding(10)
                }
                .onChange(of: chat.messages.last?.text) {
                    if let id = chat.messages.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                }
            }

            Divider()
            VStack(alignment: .leading, spacing: 6) {
                if let unavailable {
                    Text(unavailable).font(.caption).foregroundStyle(.orange)
                }
                HStack(alignment: .bottom, spacing: 6) {
                    TextField(tr("질문을 입력하고 Enter"), text: $input, axis: .vertical)
                        .lineLimit(1...5)
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
                Text(tr("테이블 구조와 관계만 로컬 Ollama 에 보내요. 데이터 행은 보내지 않아요."))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(10)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(tr("다이어그램의 테이블 %@개 구조와 관계를 바탕으로 분석하고, 궁금한 점을 물어볼 수 있어요.", "\(doc.tables.count)"))
                .font(.callout).foregroundStyle(.secondary)
            Button {
                chat.ask(DiagramAI.analysisQuestion(english: L10n.isEnglish), doc: doc, app: app)
            } label: {
                Label(tr("관계 분석 시작"), systemImage: "sparkles")
            }
            .buttonStyle(.borderedProminent)
            .tint(.purple)
            .disabled(unavailable != nil)
            Text(tr("예시 질문")).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 4)
            ForEach(examples, id: \.self) { q in
                Button { chat.ask(q, doc: doc, app: app) } label: {
                    Text(q).font(.caption).multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.hover)
                .disabled(unavailable != nil)
            }
        }
    }

    private var examples: [String] {
        [tr("핵심 테이블과 데이터 흐름을 설명해 줘"),
         tr("FK 가 빠진 것 같은 관계를 찾아 줘"),
         tr("이 테이블들을 JOIN 하는 대표 쿼리를 만들어 줘"),
         tr("인덱스가 더 필요한 컬럼이 있어?")]
    }

    private func send() {
        let q = input
        guard !q.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        input = ""
        chat.ask(q, doc: doc, app: app)
        inputFocused = true
    }

    @ViewBuilder
    private func bubble(_ m: DiagramChat.Message) -> some View {
        let isUser = m.role == "user"
        VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
            Group {
                if isUser {
                    Text(m.text)
                } else if !m.failed {
                    MarkdownBlocks(text: m.text)
                } else {
                    Text(m.text)
                }
            }
            .font(.callout)
            .textSelection(.enabled)
            .foregroundStyle(m.failed ? .red : .primary)
            .padding(8)
            .background(isUser ? Color.accentColor.opacity(0.15) : Color.purple.opacity(0.07),
                        in: RoundedRectangle(cornerRadius: 8))
            if !isUser, !m.text.isEmpty, !(chat.running && chat.messages.last?.id == m.id) {
                HStack(spacing: 8) {
                    CopyButton(title: tr("복사")) { m.text }
                    if let sql = firstSQL(m.text) {
                        Button {
                            if let tabID = app.selectedTab?.id ?? app.tabs.last?.id {
                                app.insertIntoTab(tabID, sql: sql, label: tr("AI 관계 분석"))
                            }
                        } label: { Label(tr("SQL 편집기에 넣기"), systemImage: "text.insert") }
                            .buttonStyle(.hover)
                            .disabled(app.tabs.isEmpty)
                    }
                }
                .font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }

    private func firstSQL(_ text: String) -> String? {
        guard let r = text.range(of: "```(?:sql|SQL)\\s*\\n([\\s\\S]*?)```", options: .regularExpression) else { return nil }
        var block = String(text[r])
        block = block.replacingOccurrences(of: "^```(?:sql|SQL)\\s*\\n", with: "", options: .regularExpression)
        block = block.replacingOccurrences(of: "```$", with: "", options: .regularExpression)
        let s = block.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }
}

/// 간단한 마크다운 표시: 제목(#), 코드 블록(```), 구분선(---), 나머지는 인라인 마크다운(굵게, `코드`)
struct MarkdownBlocks: View {
    let text: String

    enum Block: Hashable {
        case heading(String, Int)
        case code(String)
        case rule
        case paragraph(String)
    }

    static func blocks(_ text: String) -> [Block] {
        var out: [Block] = []
        var para: [String] = []
        var code: [String]? = nil
        func flush() {
            let p = para.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !p.isEmpty { out.append(.paragraph(p)) }
            para = []
        }
        for line in text.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") {
                if let c = code { out.append(.code(c.joined(separator: "\n"))); code = nil }
                else { flush(); code = [] }
                continue
            }
            if code != nil { code!.append(line); continue }
            if t.hasPrefix("#") {
                flush()
                let level = t.prefix(while: { $0 == "#" }).count
                out.append(.heading(t.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces), level))
            } else if t == "---" || t == "***" {
                flush(); out.append(.rule)
            } else if t.isEmpty {
                flush()
            } else {
                para.append(line.replacingOccurrences(of: "^(\\s*)[-*] ", with: "$1• ", options: .regularExpression))
            }
        }
        if let c = code { out.append(.code(c.joined(separator: "\n"))) }
        flush()
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(Self.blocks(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let t, let level):
                    Text(inline(t)).font(level <= 2 ? .title3.weight(.semibold) : .headline).padding(.top, 2)
                case .code(let c):
                    Text(c)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
                case .rule:
                    Divider()
                case .paragraph(let p):
                    Text(inline(p))
                }
            }
        }
    }

    private func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}
