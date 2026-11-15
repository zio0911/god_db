import AppKit
import GodDBCore
import SwiftUI

/// 커밋하지 않은 트랜잭션이 있을 때 묻는 이유
struct TxPrompt: Identifiable {
    enum Reason { case enableAutoCommit, disconnect }
    let id = UUID()
    let profileID: UUID
    let reason: Reason
}

extension AppState {
    func txState(_ id: UUID) -> DBSession.TransactionState {
        connections[id]?.tx ?? DBSession.TransactionState()
    }

    func refreshTx(_ id: UUID) async {
        guard let s = connections[id]?.session else { return }
        let st = await s.transactionState
        if connections[id]?.tx != st { updateConnection(id) { $0.tx = st } }
    }

    private func txTarget(_ id: UUID) -> String {
        let name = profiles.first { $0.id == id }?.name ?? "?"
        let db = connections[id]?.currentDatabase ?? ""
        return db.isEmpty ? name : "\(name)/\(db)"
    }

    /// 자동 커밋 켜기/끄기. 켤 때 열린 트랜잭션이 있으면 먼저 묻는다.
    func setAutoCommit(_ id: UUID, _ on: Bool) async {
        guard let s = connections[id]?.session else { return }
        if on, txState(id).open {
            txPrompt = TxPrompt(profileID: id, reason: .enableAutoCommit)
            return
        }
        do {
            try await s.setAutoCommit(on)
            await refreshTx(id)
            log(.info, .query, on ? tr("[%@] 자동 커밋 켬", txTarget(id)) : tr("[%@] 자동 커밋 끔 · 변경은 커밋할 때 반영돼요", txTarget(id)),
                audit: AuditRecord(.settings, target: txTarget(id), result: on ? "자동 커밋 켬" : "자동 커밋 끔 (수동 커밋)"))
        } catch {
            logError(error, .query, context: tr("자동 커밋 전환 실패"))
        }
    }

    func commitTx(_ id: UUID) async {
        guard let s = connections[id]?.session else { return }
        do {
            let n = try await s.commit()
            await refreshTx(id)
            log(.success, .query, tr("[%@] 커밋 · 변경 %@건", txTarget(id), "\(n)"),
                audit: AuditRecord(.execute, target: txTarget(id), result: "커밋 · 변경 \(n)건", statement: s.dialect.commitSQL))
        } catch {
            await refreshTx(id)
            logError(error, .query, context: tr("커밋 실패"),
                     audit: AuditRecord(.execute, target: txTarget(id), statement: s.dialect.commitSQL))
        }
    }

    func rollbackTx(_ id: UUID) async {
        guard let s = connections[id]?.session else { return }
        do {
            let n = try await s.rollback()
            await refreshTx(id)
            log(.success, .query, tr("[%@] 롤백 · 변경 %@건 되돌림", txTarget(id), "\(n)"),
                audit: AuditRecord(.execute, target: txTarget(id), result: "롤백 · 변경 \(n)건 되돌림", statement: s.dialect.rollbackSQL))
            // 되돌린 데이터가 보이도록 열린 결과를 다시 읽는다
            for tab in tabs where tab.profileID == id && tab.result?.isPaged == true {
                if let page = tab.result?.page { await loadPage(page, in: tab.id) }
            }
        } catch {
            await refreshTx(id)
            logError(error, .query, context: tr("롤백 실패"),
                     audit: AuditRecord(.execute, target: txTarget(id), statement: s.dialect.rollbackSQL))
        }
    }

    /// 확인 창에서 커밋/롤백을 고른 뒤 원래 하려던 일을 이어서 한다
    func resolveTxPrompt(_ prompt: TxPrompt, commit: Bool) async {
        txPrompt = nil
        if commit { await commitTx(prompt.profileID) } else { await rollbackTx(prompt.profileID) }
        guard !txState(prompt.profileID).open else { return }   // 실패했으면 멈춘다
        switch prompt.reason {
        case .enableAutoCommit: await setAutoCommit(prompt.profileID, true)
        case .disconnect: await disconnect(prompt.profileID, force: true)
        }
    }

    /// 앱 종료 전: 열린 트랜잭션이 있는 접속들
    var openTransactions: [(UUID, Int)] {
        connections.compactMap { id, c in c.tx.open ? (id, c.tx.changes) : nil }
    }
}

/// 쿼리 도구 막대의 자동 커밋 체크박스 + 열린 트랜잭션 표시 + 커밋/롤백
struct TransactionControls: View {
    @Environment(AppState.self) private var app
    let profileID: UUID

    var body: some View {
        let tx = app.txState(profileID)
        HStack(spacing: 6) {
            Toggle(tr("자동 커밋"), isOn: Binding(get: { tx.autoCommit },
                                                  set: { v in Task { await app.setAutoCommit(profileID, v) } }))
                .toggleStyle(.checkbox)
                .help(tr("끄면 INSERT·UPDATE·DELETE 가 트랜잭션 안에서 실행되고 [커밋] 할 때 반영돼요. (MySQL 은 CREATE·ALTER·DROP 이 자동 커밋돼요)"))
            if tx.open {
                Label(tr("트랜잭션 · 변경 %@건", "\(tx.changes)"), systemImage: "clock.arrow.circlepath")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.orange.opacity(0.12), in: Capsule())
                Button(tr("커밋")) { Task { await app.commitTx(profileID) } }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .help(tr("열린 트랜잭션의 변경을 DB 에 반영해요"))
                Button(tr("롤백")) { Task { await app.rollbackTx(profileID) } }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .help(tr("열린 트랜잭션의 변경을 모두 되돌려요"))
            }
        }
    }
}

/// 앱 종료 때 커밋하지 않은 트랜잭션이 있으면 묻는다
final class GodDBAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let app = MainActor.assumeIsolated({ AppState.shared }) else { return .terminateNow }
        let open = MainActor.assumeIsolated { app.openTransactions }
        guard !open.isEmpty else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = tr("커밋하지 않은 트랜잭션이 있어요")
        alert.informativeText = tr("접속 %@개에 커밋하지 않은 변경 %@건이 있어요. 종료하면 되돌려져요(롤백).",
                                   "\(open.count)", "\(open.map(\.1).reduce(0, +))")
        alert.alertStyle = .warning
        alert.addButton(withTitle: tr("롤백하고 종료"))
        alert.addButton(withTitle: tr("취소"))
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        Task { @MainActor in
            for (id, _) in open { await app.rollbackTx(id) }
            LogFile.shared.flush()
            NSApplication.shared.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
