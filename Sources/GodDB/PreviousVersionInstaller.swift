import AppKit
import GodDBCore
import Observation

/// 이전 버전 설치 (F5): 목록 가져오기 → 확인 → 열린 트랜잭션 확인 → 데이터 폴더 백업 → 내려받기 → 검증 → 도우미로 교체.
@MainActor
@Observable
final class PreviousVersionInstaller {
    enum ListState: Equatable {
        case loading
        case loaded([PreviousVersions.Entry])
        case failed(String)
    }

    enum Phase: Equatable {
        case idle
        case backingUp
        case downloading(Double)
        case verifying
        case launching
        case failed(String)
    }

    var list: ListState = .loading
    var phase: Phase = .idle
    /// 진행 중인 버전
    var target: String?

    @ObservationIgnored private var downloadTask: URLSessionDownloadTask?
    @ObservationIgnored private var work: Task<Void, Never>?

    static var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev" }

    /// 도우미가 교체에 실패하면 남기는 표시 파일 (다음 실행 때 읽고 지운다)
    static var failureMarker: URL { AppPaths.dataDirectory.appendingPathComponent("previous-version-install-failed.txt") }

    var busy: Bool {
        switch phase {
        case .idle, .failed: false
        default: true
        }
    }

    // MARK: - 목록

    func load() async {
        list = .loading
        var request = URLRequest(url: PreviousVersions.releasesAPI, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("GodDB", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            let releases = try PreviousVersions.decode(data)
            list = .loaded(PreviousVersions.entries(from: releases, current: Self.currentVersion))
        } catch {
            list = .failed(error.localizedDescription)
        }
    }

    // MARK: - 설치

    /// 버전을 고르면: 확인 창 → 트랜잭션 확인 → 진행
    func confirmAndInstall(_ entry: PreviousVersions.Entry, app: AppState) {
        guard !busy else { return }
        let alert = NSAlert()
        alert.messageText = tr("%@ 으로 되돌릴까요?", entry.version)
        alert.informativeText = tr("앱을 끄고 이전 버전을 설치한 뒤 다시 켭니다. 접속 · 탭 · 설정은 그대로 남고, 설치 전에 백업합니다.")
        alert.addButton(withTitle: tr("설치"))
        alert.addButton(withTitle: tr("취소"))
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = tr("이 버전에 머물기 (자동 업데이트를 '수동'으로 바꿈)")
        alert.suppressionButton?.state = .on
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let stay = alert.suppressionButton?.state == .on

        // 열린 트랜잭션: 앱 종료와 같은 확인
        let open = app.openTransactions
        if !open.isEmpty {
            guard GodDBAppDelegate.confirmRollback(open, proceedTitle: tr("롤백하고 설치")) else { return }
        }
        target = entry.version
        work = Task { [weak self] in
            for (id, _) in open { await app.rollbackTx(id) }
            guard app.openTransactions.isEmpty else {
                self?.phase = .failed(tr("트랜잭션을 롤백하지 못해 설치를 멈췄어요"))
                return
            }
            await self?.install(entry, stay: stay, app: app)
        }
    }

    func cancel() {
        downloadTask?.cancel()
        work?.cancel()
    }

    private func install(_ entry: PreviousVersions.Entry, stay: Bool, app: AppState) async {
        let current = Self.currentVersion
        let fail: (String) -> Void = { [weak self] message in
            self?.phase = .failed(message)
            app.log(.error, .app, tr("이전 버전 설치 실패 · %@", message))
        }
        // 0) 미리 확인: 서명된 .app 이고, 앱 위치에 쓸 수 있어야 한다
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app", let teamID = PreviousVersions.currentTeamID() else {
            return fail(PreviousVersions.InstallError.unsignedCurrent.errorDescription ?? "")
        }
        let parent = bundle.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path), FileManager.default.isWritableFile(atPath: bundle.path) else {
            return fail(tr("앱 위치에 쓸 수 없어요 (%@). 응용 프로그램 폴더로 옮긴 뒤 다시 시도하세요.", parent.path))
        }

        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("GodDB-install-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

        // 1) 데이터 폴더 백업 (최근 3개만)
        phase = .backingUp
        LogFile.shared.flush()
        app.saveTabsNow()
        do {
            let name = try await Task.detached(priority: .userInitiated) {
                try Self.backupDataFolder(current: current)
            }.value
            if let name { app.log(.info, .app, tr("데이터 폴더 백업 · %@", name)) }
        } catch {
            return fail(tr("데이터 폴더를 백업하지 못했어요: %@", error.localizedDescription))
        }
        guard !Task.isCancelled else { phase = .idle; return }

        // 2) 내려받기
        phase = .downloading(0)
        let dmg = work.appendingPathComponent(entry.dmg.name)
        do {
            try await download(entry.dmg.browserDownloadURL, to: dmg, expectedSize: entry.dmg.size)
        } catch {
            if (error as? URLError)?.code == .cancelled || Task.isCancelled { phase = .idle; return }
            return fail(tr("내려받지 못했어요: %@", error.localizedDescription))
        }
        guard !Task.isCancelled else { phase = .idle; return }

        // 3) 검증 (DMG 열기 · codesign · 팀 ID · spctl)
        phase = .verifying
        let mount = work.appendingPathComponent("mnt", isDirectory: true)
        let bundleID = Bundle.main.bundleIdentifier
        let verified: PreviousVersions.VerifiedApp
        do {
            verified = try await Task.detached(priority: .userInitiated) {
                try PreviousVersions.mountAndVerify(dmg: dmg, mountPoint: mount, expectedTeamID: teamID,
                                                    expectedBundleID: bundleID, expectedVersion: entry.version)
            }.value
        } catch {
            return fail((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
        guard !Task.isCancelled else {
            PreviousVersions.detach(mount)
            phase = .idle
            return
        }

        // 4) 도우미 스크립트를 띄우고 앱 종료
        phase = .launching
        let script = work.appendingPathComponent("install-previous.sh")
        let text = PreviousVersions.helperScript(pid: ProcessInfo.processInfo.processIdentifier,
                                                 newApp: verified.appURL.path, target: bundle.path,
                                                 mountPoint: mount.path, failureMarker: Self.failureMarker.path)
        do {
            try text.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = [script.path]
            p.standardInput = FileHandle.nullDevice
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
        } catch {
            PreviousVersions.detach(mount)
            return fail(tr("설치 도우미를 실행하지 못했어요: %@", error.localizedDescription))
        }
        if stay { UpdateController.shared.apply(.manual) }
        app.log(.info, .app, tr("이전 버전 설치 · %@ → %@", current, entry.version),
                audit: AuditRecord(.settings, result: "이전 버전 설치 \(current) → \(entry.version)"))
        LogFile.shared.flush()
        NSApplication.shared.terminate(nil)
    }

    /// `…/GodDB` → `…/GodDB-backup-<버전>-<시각>`, 그 뒤 오래된 백업을 지워 최근 3개만 남긴다. 데이터 폴더가 없으면 nil.
    nonisolated static func backupDataFolder(current: String, now: Date = Date()) throws -> String? {
        let fm = FileManager.default
        let data = AppPaths.dataDirectory
        guard fm.fileExists(atPath: data.path) else { return nil }
        let parent = data.deletingLastPathComponent()
        let name = PreviousVersions.backupName(current: current, date: now)
        try fm.copyItem(at: data, to: parent.appendingPathComponent(name, isDirectory: true))
        let names = (try? fm.contentsOfDirectory(atPath: parent.path)) ?? []
        for old in PreviousVersions.backupsToPrune(names) {
            try? fm.removeItem(at: parent.appendingPathComponent(old, isDirectory: true))
        }
        return name
    }

    /// 진행률을 보이며 내려받는다. cancel() 로 멈춘다.
    private func download(_ url: URL, to dest: URL, expectedSize: Int) async throws {
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.setValue("GodDB", forHTTPHeaderField: "User-Agent")
        let finished: (URL?, URLResponse?, (any Error)?) -> Result<Void, any Error> = { tmp, response, error in
            if let error { return .failure(error) }
            guard let tmp, let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return .failure(URLError(.badServerResponse))
            }
            do {
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: tmp, to: dest)
                return .success(())
            } catch { return .failure(error) }
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
                let task = URLSession.shared.downloadTask(with: request) { tmp, response, error in
                    cont.resume(with: finished(tmp, response, error))
                }
                downloadTask = task
                task.resume()
                // 진행률 (0.2초마다)
                Task { @MainActor [weak self, weak task] in
                    while let task, task.state == .running, let self {
                        let total = task.countOfBytesExpectedToReceive > 0 ? task.countOfBytesExpectedToReceive : Int64(expectedSize)
                        if total > 0, case .downloading = self.phase {
                            self.phase = .downloading(min(1, Double(task.countOfBytesReceived) / Double(total)))
                        }
                        try? await Task.sleep(for: .milliseconds(200))
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.downloadTask?.cancel() }
        }
        downloadTask = nil
    }

    // MARK: - 다음 실행 때: 교체 실패 표시

    /// 도우미가 교체에 실패했으면 이유를 보여 주고 표시 파일을 지운다
    static func reportHelperFailureIfAny(app: AppState) {
        let marker = failureMarker
        guard let raw = try? String(contentsOf: marker, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(at: marker)
        let reason: String
        switch PreviousVersions.HelperFailure(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
        case .timeout?: reason = tr("앱이 제때 종료되지 않아 설치를 취소했어요")
        case .copy?: reason = tr("새 앱을 복사하지 못했어요")
        case .move?, .swap?: reason = tr("앱을 바꾸지 못했어요")
        case nil: reason = raw
        }
        app.log(.error, .app, tr("이전 버전 설치 실패 · %@", reason),
                hint: tr("지금 앱은 그대로예요. GitHub 에서 직접 받아 설치할 수 있어요."),
                audit: AuditRecord(.settings, result: "실패: 이전 버전 설치 · \(reason)"))
        let alert = NSAlert()
        alert.messageText = tr("이전 버전을 설치하지 못했어요")
        alert.informativeText = reason + "\n" + tr("지금 앱은 그대로예요. GitHub 에서 직접 받아 설치할 수 있어요.")
        alert.alertStyle = .warning
        alert.runModal()
    }
}
