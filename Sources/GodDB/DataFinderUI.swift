import GodDBCore
import SwiftUI

/// AI 데이터 찾기 답 카드에 보이는 위치 하나
struct DataFinderAnswer: Identifiable, Equatable {
    let id = UUID()
    var table: String
    var columns: [String]
    /// AI 판단의 신뢰도 (테이블 설명 · 다른 후보는 없음)
    var confidence: DataFinder.Confidence?
    var explain: String
    var sql: String
    /// 카드에 보일 값 예 (nil = 조회 안 함, 빈 배열 = 샘플 없음)
    var samples: [String]?
    /// 샘플 조회 상태 ("값 N개" / "시간 초과" / "조회 실패: …", nil = 조회 안 함)
    var sampleStatus: String? = nil
    /// 테이블 설명(#178)에서 찾음 — [아니에요] 하면 설명에서 그 찾는 말을 뺀다
    var fromDescriptions: Bool
    var confirmed: Bool
    var source: TableNote.Source

    var location: String { columns.isEmpty ? table : "\(table).\(columns.joined(separator: ", "))" }
}

/// 답 카드 상태 (어시스턴트 대화의 답 메시지 하나에 붙는다; 앱을 다시 열면 글 요약만 남는다)
struct DataFinderCard: Equatable {
    var question: String
    var terms: [String]
    var profileID: UUID
    var database: String
    var current: DataFinderAnswer?
    /// [아니에요] 하면 차례로 보여줄 다른 후보
    var others: [DataFinderAnswer]
    /// 테이블 설명에서 바로 찾음 (AI 호출 없음)
    var fromNotes: Bool
    /// 보낸 내용 칩: 테이블 목록 N개 · 후보 컬럼 샘플 M개
    var tablesSent: Int?
    var samplesSent: Int?
    /// 고른 AI 모델이 답하지 않음 (찾기를 멈추고 다른 모델을 권한다)
    var modelProblem: FinderModelProblem?
    /// AI 를 못 쓰고 이름 · 코멘트 · 값으로 찾음 (모델 오류면 그 이유)
    var withoutAI: Bool = false
    var aiError: String?

    var title: String { terms.isEmpty ? question : DataFinder.phrase(terms) }
}

/// 고른 모델이 실패했을 때 카드에 보일 내용
struct FinderModelProblem: Equatable {
    var model: String
    var reason: String
    /// 확인해 보니 답하는 다른 모델 (추천 모델 먼저)
    var alternatives: [String] = []
    /// 다른 모델을 확인하는 중
    var checking = true

    var message: String {
        tr("선택한 AI 모델 ‹%@› 이 응답하지 않아요 (Ollama: %@). 설정 > AI 에서 다른 모델을 골라 주세요.", model, reason)
    }
}

/// 샘플 조회기: 따로 연 짧은 연결로 조회하고(사용자 세션은 그대로), 연결을 못 열면 사용자 세션으로.
actor FinderSampler {
    private var side: SideConnection?
    private var tried = false
    let session: DBSession

    init(session: DBSession) { self.session = session }

    enum Route { case side, main }

    func run(_ sql: String) async throws -> (rows: [[String?]], route: Route) {
        if !tried {
            tried = true
            if let s = await session.sideConnection() {
                do { try await s.connect(); side = s } catch { side = nil }
            }
        }
        if let side {
            return (try await side.query(sql, timeout: DataFinder.sampleTimeout).rows, .side)
        }
        // 따로 연결할 수 없으면 사용자 세션으로: 시간이 넘으면 서버에 취소를 보낸다
        // (SQL Server 는 취소하면 세션이 끊기므로 DBSession 이 다시 연결하고 보던 DB 로 돌아간다)
        let session = session
        do {
            let r = try await ConnectDeadline.run(seconds: DataFinder.sampleTimeout) { try await session.raw(sql) }
            return (r.rows, .main)
        } catch is DBConnectTimeoutError {
            _ = try? await session.cancelRunning()
            throw SideConnection.TimedOut(seconds: Int(DataFinder.sampleTimeout))
        }
    }

    func close() async {
        await side?.close()
        side = nil
    }
}

/// 운영 접속 샘플 조회 확인의 답
enum ProdSampleChoice { case once, always, cancel }

/// 운영 접속에서 처음 샘플을 조회하기 전 확인 (접속마다 한 번)
struct ProdSamplePrompt: Identifiable {
    let id = UUID()
    let profileName: String
    let resolve: (ProdSampleChoice) -> Void
}

extension AppState {
    // MARK: - 찾기

    /// 데이터 위치 찾기. 테이블 설명의 찾는 말이 맞으면 바로 답, 아니면 로컬 AI 후보 → 샘플 조회 → 판단.
    func findData(_ question: String, skipNotes: Bool = false) {
        guard let p = selectedProfile, p.kind.isSQL, state == .connected, let session else { return }
        let chat = assistant.chat(assistantScope)
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        // 답하는 중이면 그 답은 멈추고 이 질문을 먼저 (#177)
        if chat.running { chat.cancel() }
        assistant.finderMode = false
        let terms = DataFinder.keyTerms(q)
        let db = currentDatabase
        let tables = describedTables
        let hints = currentDescriptions?.finderNotes(profileID: p.id, database: db) ?? []
        chat.messages.append(.init(role: "user", text: q))
        chat.messages.append(.init(role: "assistant", text: ""))
        let answerIndex = chat.messages.count - 1
        let messageID = chat.messages[answerIndex].id
        let dialect = session.dialect
        var card = DataFinderCard(question: q, terms: terms, profileID: p.id, database: db, current: nil, others: [],
                                  fromNotes: false)

        guard !terms.isEmpty else {
            chat.messages[answerIndex].text = tr("무엇을 찾을지 알아듣지 못했어요. 예: \"학년 정보는 어디 있어?\"")
            chat.persist()
            return
        }

        // 1) 테이블 설명 먼저
        if !skipNotes {
            let hits = DataFinder.matchNotes(terms: terms, in: hints)
            if !hits.isEmpty {
                let answers = hits.map { n in
                    DataFinderAnswer(table: n.table, columns: n.columns, confidence: nil, explain: n.memo,
                                     sql: DataFinder.defaultSQL(table: n.table, dialect: dialect), samples: nil,
                                     fromDescriptions: true, confirmed: true, source: .user)
                }
                card.current = answers.first
                card.others = Array(answers.dropFirst())
                card.fromNotes = true
                assistant.finderCards[messageID] = card
                chat.messages[answerIndex].text = Self.finderSummary(card)
                chat.persist()
                return
            }
        }

        let gen = chat.begin()
        let notes = hints
        let target = db.isEmpty ? p.name : "\(p.name)/\(db)"
        chat.task = Task { [weak self] in
            guard let self else { return }
            var card = card
            var sampleQueries = 0
            var candidateCount = 0
            let sampler = FinderSampler(session: session)
            do {
                let client = AISettings.client
                guard case .running(let models) = await client.status() else { throw OllamaError.notRunning }
                let installed = models.map(\.name)
                guard let model = AISettings.effectiveModel(installed: installed), !model.isEmpty else { throw OllamaError.noModel }

                // 0) 모델 확인 (앱을 켜 둔 동안 모델별로 기억). 실패하면 조용히 넘어가지 않고 알린다.
                chat.edit(messageID) { $0.text = tr("🔎 AI 모델 ‹%@› 확인 중…", model) }
                let health = await ModelProbe.check(model: model, client: client)
                try Task.checkCancellation()
                guard health.isOK else {
                    card.modelProblem = FinderModelProblem(model: model, reason: health.reason)
                    self.assistant.finderCards[messageID] = card
                    chat.edit(messageID) { $0.text = Self.finderSummary(card) }
                    self.log(.warning, .schema, tr("AI 데이터 찾기 · 모델 %@ 응답 없음 · %@", model, health.reason),
                             audit: AuditRecord(.ai, target: target, result: "실패: 데이터 찾기 · 모델 응답 없음 (\(model))"))
                    self.finishFinder(chat, gen)
                    self.probeAlternatives(messageID: messageID, failing: model, installed: installed, client: client)
                    return
                }

                let ai = DataFinderAI.ollama(client, model: model, kind: p.kind, english: L10n.isEnglish)
                let found = try await ai.find(
                    question: q, terms: terms, tables: tables, notes: notes,
                    progress: { step in
                        await MainActor.run {
                            switch step {
                            case .picking: chat.edit(messageID) { $0.text = tr("🔎 후보 테이블 · 컬럼을 고르는 중…") }
                            case .sampling: chat.edit(messageID) { $0.text = tr("🔎 후보 컬럼 값을 확인하는 중…") }
                            case .judging: chat.edit(messageID) { $0.text = tr("🔎 값을 보고 판단하는 중…") }
                            }
                        }
                    },
                    allowSamples: { await self.allowProdSamples(p) },
                    sample: { table, column in
                        let sql = DataFinder.sampleSQL(table: table, column: column, dialect: dialect)
                        return await self.runSample(sql, sampler: sampler, profileName: p.name, target: target)
                    })
                await sampler.close()
                try Task.checkCancellation()
                candidateCount = found.picked.candidates.count
                sampleQueries = found.sampleQueries
                card.tablesSent = found.picked.tablesSent
                card.withoutAI = found.usedFallback
                card.aiError = found.aiError
                guard let verdict = found.verdict else {
                    card.samplesSent = 0
                    chat.edit(messageID) { $0.text = tr("🔎 %@: 맞는 테이블 · 컬럼을 찾지 못했어요. 다른 말로 물어보세요.", card.title) }
                    if found.usedFallback { chat.edit(messageID) { $0.text += "\n\n" + Self.withoutAIText(card) } }
                    self.logFinder(target: target, model: model, title: card.title, result: nil,
                                   candidates: candidateCount, sampleQueries: sampleQueries)
                    self.finishFinder(chat, gen)
                    return
                }
                card.samplesSent = found.sampled.reduce(0) { n, s in
                    n + s.candidate.columns.filter { !((s.samples[$0] ?? nil)?.isEmpty ?? true) }.count
                }

                // 답 카드 (테이블 설명에는 [맞아요] 를 눌렀을 때만 넣는다)
                let chosen = found.sampled.first { $0.candidate.table == verdict.table }
                var current = DataFinderAnswer(table: verdict.table, columns: verdict.columns, confidence: verdict.confidence,
                                               explain: verdict.explain, sql: verdict.sql, samples: chosen?.displaySamples,
                                               sampleStatus: chosen?.sampleStatus,
                                               fromDescriptions: false, confirmed: false, source: .ai)
                card.current = current
                card.others = found.sampled.filter { $0 != chosen }.map { s in
                    DataFinderAnswer(table: s.candidate.table, columns: s.candidate.columns, confidence: nil,
                                     explain: s.candidate.reason, sql: DataFinder.defaultSQL(table: s.candidate.table, dialect: dialect),
                                     samples: s.displaySamples, sampleStatus: s.sampleStatus,
                                     fromDescriptions: false, confirmed: false, source: .ai)
                }
                self.assistant.finderCards[messageID] = card
                chat.edit(messageID) { $0.text = Self.finderSummary(card) }
                self.logFinder(target: target, model: model, title: card.title, result: current.location,
                               candidates: candidateCount, sampleQueries: sampleQueries)
            } catch where error is CancellationError || Task.isCancelled {
                await sampler.close()
                chat.edit(messageID) { $0.text = tr("(취소했어요)") }
            } catch {
                await sampler.close()
                let text = self.logError(error, .schema, context: tr("AI 데이터 찾기 실패"),
                    audit: AuditRecord(.ai, target: target, statement: DataFinder.auditResult(candidates: candidateCount,
                                                                                                sampleQueries: sampleQueries)))
                chat.edit(messageID) { $0.failed = true; $0.text = text }
            }
            self.finishFinder(chat, gen)
        }
    }

    /// 운영 접속이면 접속마다 처음 한 번 묻는다. 취소면 false.
    private func allowProdSamples(_ p: ConnectionProfile) async -> Bool {
        guard p.environment == .production, !assistant.prodSampleAllowed.contains(p.id) else { return true }
        switch await askProdSamples(p.name) {
        case .once: return true
        case .always:
            assistant.prodSampleAllowed.insert(p.id)
            return true
        case .cancel: return false
        }
    }

    /// 고른 모델이 실패했을 때 설치된 다른 모델을 차례로 확인해 답하는 것만 [‹모델› 로 바꾸기] 버튼으로 (추천 모델 먼저)
    private func probeAlternatives(messageID: UUID, failing: String, installed: [String], client: OllamaClient) {
        let others = AISettings.recommendedFirst(installed.filter { $0 != failing })
        Task { [weak self] in
            for m in others {
                let h = await ModelProbe.check(model: m, client: client)
                guard let self, var card = self.assistant.finderCards[messageID], card.modelProblem != nil else { return }
                if h.isOK { card.modelProblem?.alternatives.append(m) }
                self.assistant.finderCards[messageID] = card
            }
            guard let self, var card = self.assistant.finderCards[messageID], card.modelProblem != nil else { return }
            card.modelProblem?.checking = false
            self.assistant.finderCards[messageID] = card
        }
    }

    /// [‹모델› 로 바꾸기]: 설정의 모델을 바꾸고 같은 질문을 다시 찾는다
    func finderSwitchModel(_ model: String, card: DataFinderCard) {
        AISettings.model = model
        log(.info, .schema, tr("AI 모델을 %@ 로 바꿨어요", model))
        findData(card.question)
    }

    static func withoutAIText(_ card: DataFinderCard) -> String {
        var s = tr("AI 없이 이름 · 코멘트 · 값으로 찾은 후보예요")
        if let e = card.aiError { s += " (" + tr("AI 모델 오류: %@", e) + ")" }
        return s
    }

    private func finishFinder(_ chat: DiagramChat, _ gen: Int) {
        chat.finish(gen)
    }

    /// 감사 로그: `AI | 접속/DB | 데이터 찾기 · 후보 N · 샘플 조회 M` (질문 · 값은 남기지 않는다)
    private func logFinder(target: String, model: String, title: String, result: String?, candidates: Int, sampleQueries: Int) {
        log(.success, .schema, result.map { tr("AI 데이터 찾기 · %@ → %@ · %@", title, $0, model) }
                ?? tr("AI 데이터 찾기 · %@ → 못 찾음 · %@", title, model),
            audit: AuditRecord(.ai, target: target, result: DataFinder.auditResult(candidates: candidates, sampleQueries: sampleQueries)))
    }

    /// 샘플 조회 하나: 10초 제한, 따로 연 짧은 연결에서 (FinderSampler). 조회 SQL 은 평소처럼 `조회` 감사 줄로 남는다.
    private func runSample(_ sql: String, sampler: FinderSampler, profileName: String, target: String) async -> DataFinder.SampleOutcome {
        let started = Date()
        do {
            let r = try await sampler.run(sql)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            let values = DataFinder.cleanSamples(r.rows.map { $0.first ?? nil })
            log(.info, .query, "[\(profileName)] " + tr("데이터 찾기 샘플 · %@행 · %@ms · %@", "\(r.rows.count)", "\(ms)", Self.oneLine(sql)),
                detail: sql, audit: AuditRecord(.read, target: target, result: "데이터 찾기 샘플 · \(r.rows.count)행 · \(ms)ms", statement: sql))
            return .values(values)
        } catch is SideConnection.TimedOut {
            log(.warning, .query, "[\(profileName)] " + tr("데이터 찾기 샘플 · 시간 초과 · %@", Self.oneLine(sql)), detail: sql,
                audit: AuditRecord(.read, target: target, result: "실패: 데이터 찾기 샘플 시간 초과 (\(Int(DataFinder.sampleTimeout))초)",
                                   statement: sql))
            return .timedOut
        } catch {
            let message = ErrorText.describe(error).message
            log(.warning, .query, "[\(profileName)] " + tr("데이터 찾기 샘플 · 실패 · %@", Self.oneLine(sql)), detail: sql + "\n" + message,
                audit: AuditRecord(.read, target: target, result: "실패: 데이터 찾기 샘플 · \(message)", statement: sql))
            return .failed(String(message.prefix(80)))
        }
    }

    /// 운영 접속 확인 창을 띄우고 답을 기다린다 (작업을 취소하면 [취소]로 본다)
    private func askProdSamples(_ profileName: String) async -> ProdSampleChoice {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<ProdSampleChoice, Never>) in
                let once = DataFinderOnce()
                assistant.prodPrompt = ProdSamplePrompt(profileName: profileName) { [weak self] choice in
                    self?.assistant.prodPrompt = nil
                    if once.claim() { cont.resume(returning: choice) }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.assistant.prodPrompt?.resolve(.cancel) }
        }
    }

    /// 테이블 설명 고치기 + 저장
    private func editDescriptions(_ card: DataFinderCard, _ change: (inout TableDescriptionDoc) -> Void) {
        tableDescriptions.edit(profileID: card.profileID, database: card.database, change)
        TableDescriptionStore.shared.save(tableDescriptions)
    }

    // MARK: - 카드 버튼

    /// [데이터 보기]: 새 탭에서 평소 실행 경로로
    func finderViewData(_ card: DataFinderCard) {
        guard let a = card.current else { return }
        guard addTab(text: a.sql, title: "🔎 " + card.title, for: card.profileID) != nil else { return }
        Task { await run(sql: a.sql) }
    }

    /// [SQL 넣기]: 같은 접속의 지금 탭(없으면 새 탭)에
    func finderInsertSQL(_ card: DataFinderCard) {
        guard let a = card.current else { return }
        if let tab = selectedTab, tab.profileID == card.profileID {
            insertIntoTab(tab.id, sql: a.sql, label: tr("AI 데이터 찾기"))
        } else {
            addTab(text: a.sql + "\n", title: "🔎 " + card.title, for: card.profileID)
        }
    }

    /// [맞아요]: 이 질문의 말을 테이블 설명의 그 위치에 찾는 말로 넣는다 (다음엔 AI 없이 바로)
    func finderConfirm(_ messageID: UUID) {
        guard var card = assistant.finderCards[messageID], var a = card.current else { return }
        if !a.fromDescriptions {
            editDescriptions(card) { $0.addTerms([DataFinder.phrase(card.terms)], table: a.table, columns: a.columns) }
        }
        a.confirmed = true
        card.current = a
        updateFinderCard(messageID, card)
    }

    /// [아니에요]: 테이블 설명에서 찾은 것이면 그 찾는 말을 빼고, 다음 후보 (없으면 "다른 후보가 없어요")
    func finderReject(_ messageID: UUID) {
        guard var card = assistant.finderCards[messageID], let a = card.current else { return }
        if a.fromDescriptions {
            editDescriptions(card) {
                $0.removeTerms([DataFinder.phrase(card.terms)] + card.terms, table: a.table, columns: a.columns)
            }
        }
        if card.others.isEmpty {
            card.current = nil
        } else {
            var next = card.others.removeFirst()
            if !next.fromDescriptions { next.confirmed = false }
            card.current = next
        }
        updateFinderCard(messageID, card)
    }

    private func updateFinderCard(_ messageID: UUID, _ card: DataFinderCard) {
        assistant.finderCards[messageID] = card
        let chat = assistant.chat(assistantScope)
        if let i = chat.messages.firstIndex(where: { $0.id == messageID }) {
            chat.messages[i].text = Self.finderSummary(card)
            chat.persist()
        }
    }

    /// 대화 기록에 남는 글 요약 (카드는 앱을 다시 열면 사라지고 이 글만 남는다)
    static func finderSummary(_ card: DataFinderCard) -> String {
        if let m = card.modelProblem { return "🔎 **\(card.title)** — " + m.message }
        guard let a = card.current else { return "🔎 **\(card.title)** — " + tr("다른 후보가 없어요") }
        var s = "🔎 **\(card.title)** → `\(a.location)`"
        if let c = a.confidence { s += " · " + tr("신뢰도 %@", c.label) }
        s += " · " + (a.confirmed ? tr("확인됨") : tr("AI · 미확인"))
        if !a.explain.isEmpty { s += "\n\n" + a.explain }
        if card.withoutAI { s += "\n\n" + withoutAIText(card) }
        return s
    }
}

/// 한 번만 이어 가기 (확인 창 답 · 작업 취소 중 먼저 온 것)
final class DataFinderOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

/// 답 카드
struct DataFinderCardView: View {
    @Environment(AppState.self) private var app
    let messageID: UUID
    let card: DataFinderCard
    let running: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(card.title, systemImage: "magnifyingglass").font(.callout.weight(.semibold))
            if let m = card.modelProblem {
                modelProblem(m)
            } else if let a = card.current {
                answer(a)
            } else {
                Text(tr("다른 후보가 없어요")).font(.callout).foregroundStyle(.secondary)
                refindButton
            }
            if card.modelProblem == nil, card.withoutAI {
                Label(AppState.withoutAIText(card), systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if !card.others.isEmpty {
                Text(tr("다른 후보: %@", card.others.map { o in
                    o.sampleStatus.map { "\(o.location) (\($0))" } ?? o.location
                }.joined(separator: " · ")))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
            chips
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.purple.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.purple.opacity(0.25)))
    }

    @ViewBuilder
    private func answer(_ a: DataFinderAnswer) -> some View {
        HStack(spacing: 6) {
            Text(a.location).font(.system(.callout, design: .monospaced)).textSelection(.enabled).lineLimit(2)
            if let c = a.confidence {
                badge(tr("신뢰도 %@", c.label), color: c == .high ? .green : c == .medium ? .orange : .secondary)
            }
            badge(a.confirmed ? tr("확인됨") : tr("AI · 미확인"), color: a.confirmed ? .green : .purple)
        }
        if let samples = a.samples, !samples.isEmpty {
            Text(tr("값 예: %@", samples.prefix(10).joined(separator: ", ")))
                .font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
        }
        if let status = a.sampleStatus {
            Text(status).font(.caption2).foregroundStyle(.secondary)
        } else if a.samples?.isEmpty == true {
            Text(tr("샘플 없음")).font(.caption).foregroundStyle(.secondary)
        }
        if !a.explain.isEmpty {
            Text(a.explain).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        FlowButtons {
            Button { app.finderViewData(card) } label: { Label(tr("데이터 보기"), systemImage: "tablecells") }
            Button { app.finderInsertSQL(card) } label: { Label(tr("SQL 넣기"), systemImage: "text.insert") }
            Button { app.finderConfirm(messageID) } label: { Label(tr("맞아요"), systemImage: "hand.thumbsup") }
                .disabled(a.confirmed)
            Button { app.finderReject(messageID) } label: { Label(tr("아니에요"), systemImage: "hand.thumbsdown") }
            if card.fromNotes { refindButton }
        }
        .font(.caption)
        .buttonStyle(.hover)
    }

    @ViewBuilder
    private func modelProblem(_ m: FinderModelProblem) -> some View {
        Label(m.message, systemImage: "exclamationmark.octagon")
            .font(.callout).foregroundStyle(.red).textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        FlowButtons {
            ForEach(m.alternatives, id: \.self) { alt in
                Button { app.finderSwitchModel(alt, card: card) } label: {
                    Label(tr("%@ 로 바꾸기", alt), systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(running)
            }
        }
        .font(.caption)
        .buttonStyle(.hover)
        if m.checking {
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text(tr("설치된 다른 모델을 확인하는 중…")).font(.caption).foregroundStyle(.secondary)
            }
        } else if m.alternatives.isEmpty {
            Text(tr("답하는 다른 모델이 없어요. 터미널에서 ollama pull %@ 로 받을 수 있어요.", AISettings.defaultRecommendedModel))
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }

    private var refindButton: some View {
        Button { app.findData(card.question, skipNotes: true) } label: { Label(tr("다시 찾기"), systemImage: "arrow.clockwise") }
            .font(.caption)
            .buttonStyle(.hover)
            .disabled(running)
    }

    @ViewBuilder
    private var chips: some View {
        if card.fromNotes {
            FlowChips(items: [("note.text", tr("테이블 설명에서 찾음 (AI 호출 없음)"))])
        } else if let n = card.tablesSent {
            FlowChips(items: [("list.bullet", tr("테이블 목록 %@개", "\(n)")),
                              ("lock.shield", tr("후보 컬럼 샘플 %@개 (로컬)", "\(card.samplesSent ?? 0)"))])
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
    }
}

/// 버튼 여러 개를 좁은 패널에서도 넘치지 않게 (두 줄까지)
struct FlowButtons<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { content() }
            VStack(alignment: .leading, spacing: 4) { content() }
        }
    }
}
