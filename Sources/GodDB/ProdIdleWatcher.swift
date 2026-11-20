import AppKit
import GodDBCore

/// 운영 접속 자동 끊기 (설정 > 일반 > 안전). 운영(production) 접속을 정해진 시간 동안 쓰지 않으면 끊는다.
/// - 사용 = 쿼리 · 페이지 · 내보내기 · 스키마 읽기 · Redis 명령 (자동 새로고침 · 화면 보기는 사용이 아님)
/// - 커밋하지 않은 변경이 있으면 끊지 않고 한 번만 알린다. 실행 · 내보내기 중이면 끝날 때까지 미룬다.
extension AppState {
    static let prodIdleMinutesKey = "GodDB.safety.prodIdleMinutes"
    /// 화면 테스트용 (초). GODDB_UI_TEST 일 때만 쓴다
    static let prodIdleSecondsForTestKey = "GodDB.safety.prodIdleSecondsForTest"
    static let prodIdleChoices = [0, 10, 30, 60]

    /// 끊기까지의 시간 (초). 0 이면 끔
    static var prodIdleLimit: TimeInterval {
        let d = UserDefaults.standard
        if AppPaths.uiTest, let s = d.object(forKey: prodIdleSecondsForTestKey) as? Int, s > 0 { return TimeInterval(s) }
        let m = d.object(forKey: prodIdleMinutesKey) as? Int ?? 30
        return TimeInterval(max(0, m) * 60)
    }

    func startIdleWatcher() {
        guard idleWatcher == nil else { return }
        idleWatcher = Task { [weak self] in
            while !Task.isCancelled {
                // 설정을 바꾸면 바로 반영되게 짧게 자주 본다 (화면 테스트는 1초, 평소 15초 — 확인은 가벼움)
                try? await Task.sleep(for: AppPaths.uiTest ? .seconds(1) : .seconds(15))
                guard let self, !Task.isCancelled else { return }
                await self.checkIdleProduction(limit: AppState.prodIdleLimit)
            }
        }
    }

    func checkIdleProduction(limit: TimeInterval, now: Date = Date()) async {
        guard limit > 0 else { return }
        for profile in profiles where profile.environment == .production && connectionState(profile.id) == .connected {
            let id = profile.id
            let last: Date
            if let ws = redisWorkspaces[id] {
                last = await ws.session.lastActivity
            } else if let session = connections[id]?.session {
                if await session.isRunning { continue }
                last = await session.lastActivity
            } else { continue }
            if tabs.contains(where: { $0.profileID == id && ($0.running || $0.exportProgress != nil) }) { continue }
            guard now.timeIntervalSince(last) >= limit else {
                idleWarned.remove(id)
                continue
            }
            let minutes = Int(limit / 60)
            let span = minutes > 0 ? tr("%@분", "\(minutes)") : tr("%@초", "\(Int(limit))")
            if let session = connections[id]?.session, await session.inTransaction {
                guard !idleWarned.contains(id) else { continue }
                idleWarned.insert(id)
                log(.warning, .connection, tr("운영 접속 %@ 에 커밋하지 않은 변경이 있어 자동으로 끊지 않았어요", profile.name))
                NSApp.requestUserAttention(.informationalRequest)
                continue
            }
            idleWarned.remove(id)
            await disconnect(id, force: true,
                             reason: tr("운영 접속 %@ 을 %@ 동안 쓰지 않아 끊었어요", profile.name, span),
                             auditResult: "자동 (\(minutes > 0 ? "\(minutes)분" : "\(Int(limit))초") 미사용)")
        }
    }
}
