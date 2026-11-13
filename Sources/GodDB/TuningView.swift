import GodDBCore
import Observation
import SwiftUI

/// 쿼리 튜닝 작업 하나 (모으기 → 모델 응답 → 개선 SQL 실행 계획 비교)
@MainActor
@Observable
final class TuningJob: Identifiable {
    enum Phase: Equatable {
        case collecting
        case thinking
        case writing
        case comparing
        case done
        case failed(String)
    }

    let id = UUID()
    let tabID: UUID
    let sql: String
    let model: String
    let connectionName: String
    var phase: Phase = .collecting
    var context: TuningContext?
    var prompt: String = ""
    var streamed: String = ""
    var thinkingChars = 0
    var result: TuningResult?
    var afterWarnings: [PlanAnalyzer.Warning]?
    var afterError: String?
    var started = Date()
    var finished: Date?
    var task: Task<Void, Never>?

    init(tabID: UUID, sql: String, model: String, connectionName: String) {
        self.tabID = tabID
        self.sql = sql
        self.model = model
        self.connectionName = connectionName
    }

    var isRunning: Bool {
        switch phase {
        case .collecting, .thinking, .writing, .comparing: return true
        case .done, .failed: return false
        }
    }
}

extension AppState {
    /// 튜닝을 쓸 수 없는 이유 (쓸 수 있으면 nil)
    var tuningUnavailableReason: String? {
        if !TuningSettings.enabled { return tr("설정 > 쿼리 튜닝에서 켜 주세요.") }
        if selectedTab == nil { return tr("쿼리 탭을 먼저 여세요.") }
        return nil
    }

    func startTuning(sql: String) {
        guard let tab = selectedTab else { return }
        var trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix(";") { trimmed.removeLast() }
        guard !trimmed.isEmpty else { return }
        let job = TuningJob(tabID: tab.id, sql: trimmed, model: TuningSettings.model,
                            connectionName: profile(tab.profileID)?.name ?? "")
        tuningJob = job
        job.task = Task { await runTuning(job, tab: tab) }
    }

    func cancelTuning() {
        tuningJob?.task?.cancel()
        if let job = tuningJob, job.isRunning { job.phase = .failed(tr("취소했어요.")) }
    }

    private func runTuning(_ job: TuningJob, tab: QueryTab) async {
        let client = TuningSettings.client
        do {
            // 1) 모델 확인
            guard case .running(let models) = await client.status() else { throw OllamaError.notRunning }
            let model = job.model.isEmpty ? (models.first?.name ?? "") : job.model
            guard !model.isEmpty else { throw OllamaError.noModel }

            // 2) 정보 모으기 (쿼리, 테이블 구조, 예상 행 수, 실행 계획)
            guard let session = connections[tab.profileID]?.session else {
                throw DBError.notConnected
            }
            if !tab.database.isEmpty, await session.current != tab.database { try await session.use(tab.database) }
            let known = connections[tab.profileID]?.tables ?? []
            let context = await session.tuningContext(sql: job.sql, knownTables: known)
            job.context = context
            let messages = TuningPrompt.messages(context, english: L10n.isEnglish)
            job.prompt = messages.last?.content ?? ""
            log(.info, .query, tr("쿼리 튜닝 시작 · %@ · 테이블 %@개", model, "\(context.tables.count)"),
                detail: job.prompt)

            // 3) 모델 응답 (스트리밍)
            job.phase = .thinking
            for try await chunk in client.chat(model: model, messages: messages) {
                try Task.checkCancellation()
                switch chunk {
                case .thinking(let t): job.thinkingChars += t.count
                case .content(let c):
                    job.phase = .writing
                    job.streamed += c
                }
            }
            let result = TuningResult.parse(job.streamed)
            job.result = result

            // 4) 개선 SQL 의 실행 계획을 다시 떠서 비교 (실행은 하지 않음)
            if let improved = result.improvedSQL {
                job.phase = .comparing
                var s = improved
                while s.hasSuffix(";") { s.removeLast() }
                do {
                    let (plan, _) = try await session.explain(s.trimmingCharacters(in: .whitespacesAndNewlines))
                    job.afterWarnings = PlanAnalyzer.warnings(plan)
                } catch {
                    job.afterError = ErrorText.describe(error).message
                }
            }
            job.phase = .done
            job.finished = Date()
            let secs = Int(Date().timeIntervalSince(job.started))
            log(.success, .query, tr("쿼리 튜닝 완료 · %@초", "\(secs)"), detail: job.streamed,
                audit: AuditRecord(.ai, target: auditTarget(tab), result: "튜닝 완료 · \(secs)초 · \(model)"))
        } catch is CancellationError {
            job.phase = .failed(tr("취소했어요."))
        } catch {
            job.phase = .failed(logError(error, .query, context: tr("쿼리 튜닝 실패"),
                                         audit: AuditRecord(.ai, target: auditTarget(tab), statement: "쿼리 튜닝")))
        }
    }
}

/// 튜닝 결과 창
struct TuningSheet: View {
    @Environment(AppState.self) private var app
    let job: TuningJob
    @State private var showPrompt = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    codeBox(tr("원래 쿼리"), job.sql, actions: false)
                    if let result = job.result, job.phase != .writing {
                        resultView(result)
                    } else {
                        progressView
                    }
                    DisclosureGroup(tr("Ollama 에 보낸 정보 보기"), isExpanded: $showPrompt) {
                        Text(job.prompt.isEmpty ? tr("아직 모으는 중이에요.") : job.prompt)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    }
                    .font(.callout)
                }
                .padding(16)
            }
            Divider()
            HStack {
                Text(tr("개선 SQL 과 인덱스는 자동으로 실행하지 않아요."))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if job.isRunning {
                    Button(tr("취소")) { app.cancelTuning() }
                } else {
                    Button(tr("다시 튜닝")) { app.startTuning(sql: job.sql) }
                }
                Button(tr("닫기")) {
                    app.cancelTuning()
                    app.tuningJob = nil
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(width: 820, height: 720)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles").foregroundStyle(.purple)
            Text(tr("쿼리 튜닝")).font(.headline)
            Text("\(job.connectionName) · \(job.model.isEmpty ? tr("자동 모델") : job.model)")
                .foregroundStyle(.secondary)
            Spacer()
            if let finished = job.finished {
                Text(tr("%@초", "\(Int(finished.timeIntervalSince(job.started)))")).foregroundStyle(.secondary)
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private var progressView: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch job.phase {
            case .failed(let message):
                Label(message, systemImage: "xmark.octagon").foregroundStyle(.red).textSelection(.enabled)
            default:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(phaseText)
                }
            }
            if !job.streamed.isEmpty {
                Text(job.streamed)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private var phaseText: String {
        switch job.phase {
        case .collecting: return tr("테이블 구조와 실행 계획을 모으는 중…")
        case .thinking: return tr("모델이 생각하는 중… (%@자)", "\(job.thinkingChars)")
        case .writing: return tr("답변을 쓰는 중…")
        case .comparing: return tr("개선 SQL 의 실행 계획을 확인하는 중…")
        case .done, .failed: return ""
        }
    }

    @ViewBuilder
    private func resultView(_ r: TuningResult) -> some View {
        if case .failed(let message) = job.phase {
            Label(message, systemImage: "xmark.octagon").foregroundStyle(.red)
        }
        VStack(alignment: .leading, spacing: 6) {
            Text(tr("요약")).font(.headline)
            Text(r.summary.isEmpty ? tr("(요약 없음)") : r.summary).textSelection(.enabled)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.purple.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))

        planCompare

        if let sql = r.improvedSQL {
            codeBox(tr("개선 SQL"), sql, actions: true)
        }
        if let idx = r.indexSQL {
            codeBox(tr("추천 인덱스"), idx, actions: r.hasIndexes)
            if r.hasIndexes {
                Text(tr("인덱스는 쓰기 성능과 저장 공간에도 영향을 줘요. 운영 DB 에는 검토 후 만드세요."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        if !r.explanation.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(tr("설명")).font(.headline)
                Text(r.explanation).textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private var planCompare: some View {
        let before = job.context?.warnings ?? []
        VStack(alignment: .leading, spacing: 6) {
            Text(tr("실행 계획 주의사항 (전 → 후)")).font(.headline)
            HStack(alignment: .top, spacing: 16) {
                warningList(tr("원래 쿼리"), before)
                if let after = job.afterWarnings {
                    warningList(tr("개선 SQL"), after)
                } else if let e = job.afterError {
                    VStack(alignment: .leading) {
                        Text(tr("개선 SQL")).font(.subheadline.weight(.semibold))
                        Text(tr("실행 계획을 확인할 수 없어요: %@", e)).font(.caption).foregroundStyle(.red)
                    }
                }
            }
            Text(tr("추천 인덱스는 아직 만들지 않았으므로, 인덱스 효과는 '후' 계획에 반영되지 않아요."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func warningList(_ title: String, _ list: [PlanAnalyzer.Warning]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title + " · " + (list.isEmpty ? tr("주의 없음") : tr("주의 %@건", "\(list.count)")))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(list.isEmpty ? .green : .orange)
            ForEach(list, id: \.self) { w in
                Text("[\(w.table)] \(w.message)").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func codeBox(_ title: String, _ sql: String, actions: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button { Pasteboard.copy(sql) } label: { Label(tr("복사"), systemImage: "doc.on.doc") }
                    .buttonStyle(.borderless)
                if actions {
                    Button {
                        app.insertIntoTab(job.tabID, sql: sql, label: title)
                    } label: { Label(tr("편집기에 넣기"), systemImage: "text.insert") }
                        .buttonStyle(.borderless)
                    Button {
                        if let tab = app.tabs.first(where: { $0.id == job.tabID }) {
                            app.addTab(text: sql + ";\n", title: title, for: tab.profileID)
                        }
                    } label: { Label(tr("새 탭으로"), systemImage: "plus.square.on.square") }
                        .buttonStyle(.borderless)
                }
            }
            Text(sql)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}
