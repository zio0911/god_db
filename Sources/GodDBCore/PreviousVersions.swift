import Foundation
import Security

/// 이전 버전 설치 (F5): GitHub 릴리스 목록 · 변경 사항 추출 · 백업 이름 · 도우미 스크립트 · 서명 정보 읽기.
/// 화면 · 내려받기 · 실행은 앱(PreviousVersionInstaller) 이 맡고, 여기에는 판단 로직만 둔다.
public enum PreviousVersions {
    public static let repository = "zio0911/god_db"
    public static let releasesAPI = URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=100")!
    public static let releasesPage = URL(string: "https://github.com/\(repository)/releases")!
    /// 이보다 낮은 버전은 목록에 넣지 않는다 (1.0.0 에는 자동 업데이트 · 같은 데이터 형식이 없음)
    public static let minimumVersion = "1.1.0"
    /// 백업 폴더 이름 앞부분 (`GodDB-backup-<버전>-<yyyyMMdd-HHmmss>`)
    public static let backupPrefix = "GodDB-backup-"
    public static let backupsToKeep = 3

    // MARK: - 릴리스 목록

    public struct Asset: Decodable, Sendable, Equatable {
        public var name: String
        public var browserDownloadURL: URL
        public var size: Int

        public init(name: String, browserDownloadURL: URL, size: Int) {
            self.name = name
            self.browserDownloadURL = browserDownloadURL
            self.size = size
        }

        enum CodingKeys: String, CodingKey {
            case name, size
            case browserDownloadURL = "browser_download_url"
        }
    }

    public struct Release: Decodable, Sendable, Equatable {
        public var tagName: String
        public var draft: Bool
        public var prerelease: Bool
        public var publishedAt: Date?
        public var body: String?
        public var htmlURL: URL?
        public var assets: [Asset]

        public init(tagName: String, draft: Bool = false, prerelease: Bool = false, publishedAt: Date? = nil,
                    body: String? = nil, htmlURL: URL? = nil, assets: [Asset] = []) {
            self.tagName = tagName
            self.draft = draft
            self.prerelease = prerelease
            self.publishedAt = publishedAt
            self.body = body
            self.htmlURL = htmlURL
            self.assets = assets
        }

        enum CodingKeys: String, CodingKey {
            case draft, prerelease, body, assets
            case tagName = "tag_name"
            case publishedAt = "published_at"
            case htmlURL = "html_url"
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            tagName = try c.decode(String.self, forKey: .tagName)
            draft = try c.decodeIfPresent(Bool.self, forKey: .draft) ?? false
            prerelease = try c.decodeIfPresent(Bool.self, forKey: .prerelease) ?? false
            publishedAt = try c.decodeIfPresent(Date.self, forKey: .publishedAt)
            body = try c.decodeIfPresent(String.self, forKey: .body)
            htmlURL = try c.decodeIfPresent(URL.self, forKey: .htmlURL)
            assets = try c.decodeIfPresent([Asset].self, forKey: .assets) ?? []
        }
    }

    /// 목록 한 줄
    public struct Entry: Identifiable, Sendable, Equatable {
        public var version: String
        public var date: Date?
        /// 변경 사항 첫 3줄 (앞의 "- " 는 뗀 Markdown)
        public var notes: [String]
        public var dmg: Asset
        public var pageURL: URL?
        public var id: String { version }
    }

    /// GitHub API 응답(JSON 배열)을 읽는다
    public static func decode(_ data: Data) throws -> [Release] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([Release].self, from: data)
    }

    /// `v1.3.6` → `1.3.6`. 숫자.숫자(.숫자) 꼴이 아니면 nil
    public static func version(fromTag tag: String) -> String? {
        let v = tag.hasPrefix("v") || tag.hasPrefix("V") ? String(tag.dropFirst()) : tag
        guard v.range(of: #"^\d+(\.\d+){1,3}$"#, options: .regularExpression) != nil else { return nil }
        return v
    }

    /// 1.10.0 > 1.9.2 처럼 숫자로 비교 (릴리스 노트와 같은 규칙)
    public static func compare(_ a: String, _ b: String) -> ComparisonResult {
        ReleaseNotes.compare(a, b)
    }

    /// 보여 줄 버전: 초안 · 사전 릴리스 제외, 1.1.0 이상, 지금 버전 제외, `GodDB-<버전>.dmg` 가 있는 것만. 최신순.
    public static func entries(from releases: [Release], current: String) -> [Entry] {
        var seen = Set<String>()
        var out: [Entry] = []
        for r in releases where !r.draft && !r.prerelease {
            guard let v = version(fromTag: r.tagName),
                  compare(v, minimumVersion) != .orderedAscending,
                  compare(v, current) != .orderedSame,
                  let dmg = dmgAsset(r.assets, version: v),
                  seen.insert(v).inserted else { continue }
            out.append(Entry(version: v, date: r.publishedAt, notes: changeNotes(r.body ?? ""),
                             dmg: dmg, pageURL: r.htmlURL))
        }
        return out.sorted { compare($0.version, $1.version) == .orderedDescending }
    }

    /// 설치할 자산: 정확히 `GodDB-<버전>.dmg`
    public static func dmgAsset(_ assets: [Asset], version: String) -> Asset? {
        assets.first { $0.name == "GodDB-\(version).dmg" }
    }

    /// 릴리스 노트에서 변경 사항 첫 줄들.
    /// `## 변경 사항` 아래 목록이 기준. 예전 릴리스(1.1.0 ~ 1.3.x)는 제목이 `## 주요 변경` · `## 변경` · `## 새 기능` · `## 수정` 처럼
    /// 제각각이라, 없으면 `## 설치` 와 자동 생성 부분(`## What's Changed` 이후)을 뺀 목록을 쓰고,
    /// 그것도 없으면 자동 생성 목록(`* feat: … by @x in …`)의 제목만 쓴다.
    public static func changeNotes(_ body: String, limit: Int = 3) -> [String] {
        let lines = body.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }

        func bullet(_ line: String) -> String? {
            guard line.hasPrefix("- ") || line.hasPrefix("* ") else { return nil }
            let text = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : text
        }

        // 1) ## 변경 사항
        var primary: [String] = []
        var preferred: [String] = []
        var generated: [String] = []
        var section: String?
        var afterGenerated = false
        for line in lines {
            if line.hasPrefix("## ") {
                let title = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                section = title
                if title.lowercased().hasPrefix("what's changed") { afterGenerated = true }
                continue
            }
            guard let text = bullet(line) else { continue }
            if afterGenerated {
                generated.append(text.replacingOccurrences(of: #"\s+by @\S+ in \S+$"#, with: "", options: .regularExpression))
            } else if section == "변경 사항" {
                preferred.append(text)
            } else if let s = section, s != "설치", s != "개발" {
                primary.append(text)
            }
        }
        let chosen = !preferred.isEmpty ? preferred : !primary.isEmpty ? primary : generated
        return Array(chosen.prefix(limit))
    }

    // MARK: - 백업

    private static func stampFormatter() -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }

    /// `GodDB-backup-1.4.0-20261120-103000`
    public static func backupName(current: String, date: Date, timeZone: TimeZone = .current) -> String {
        let f = stampFormatter()
        f.timeZone = timeZone
        let safe = current.replacingOccurrences(of: "/", with: "-")
        return "\(backupPrefix)\(safe)-\(f.string(from: date))"
    }

    /// 백업 이름 끝의 시각 (`yyyyMMdd-HHmmss`). 백업 이름 꼴이 아니면 nil
    public static func backupStamp(_ name: String) -> String? {
        guard name.hasPrefix(backupPrefix),
              let r = name.range(of: #"-(\d{8}-\d{6})$"#, options: .regularExpression),
              r.lowerBound > name.index(name.startIndex, offsetBy: backupPrefix.count) else { return nil }
        return String(name[r].dropFirst())
    }

    /// 지울 백업 이름들: 백업 꼴 이름 중 최신 `keep` 개를 뺀 나머지 (시각 기준, 같으면 이름 순). 그 밖의 이름은 건드리지 않는다.
    public static func backupsToPrune(_ names: [String], keep: Int = backupsToKeep) -> [String] {
        let backups = names.compactMap { n in backupStamp(n).map { (n, $0) } }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 > $1.0 }
        return backups.dropFirst(max(0, keep)).map(\.0)
    }

    // MARK: - 서명 확인

    public struct SigningInfo: Sendable, Equatable {
        public var identifier: String?
        public var teamID: String?
        public var authority: String?
    }

    /// `codesign -dv --verbose=2 <앱>` 출력(표준 오류)에서 Identifier · TeamIdentifier · 첫 Authority.
    /// 서명 안 된 빌드는 `TeamIdentifier=not set` → teamID nil.
    public static func signingInfo(fromCodesignOutput text: String) -> SigningInfo {
        var info = SigningInfo()
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]), value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            switch key {
            case "Identifier": info.identifier = info.identifier ?? value
            case "TeamIdentifier":
                info.teamID = value.isEmpty || value == "not set" ? nil : value
            case "Authority": info.authority = info.authority ?? value
            default: break
            }
        }
        return info
    }

    /// 새 앱의 최소 macOS(`LSMinimumSystemVersion`) 를 지금 OS 가 만족하는지. 값이 없으면 만족으로 본다.
    public static func supports(minimumSystemVersion: String?, os: OperatingSystemVersion) -> Bool {
        guard let m = minimumSystemVersion?.trimmingCharacters(in: .whitespaces), !m.isEmpty else { return true }
        let current = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        return compare(m, current) != .orderedDescending
    }

    /// 설치할 수 없는 이유 (검증 실패 · 준비 실패). 실패하면 설치하지 않는다.
    public enum InstallError: LocalizedError, Equatable {
        /// 지금 앱이 서명 없는 개발 빌드라 팀 ID 를 비교할 수 없음
        case unsignedCurrent
        case mount(String)
        case noApp
        case codesign(String)
        case teamMismatch(expected: String, found: String?)
        case bundleMismatch(expected: String, found: String?)
        case notarization(String)
        case requiresNewerOS(String)
        case versionMismatch(expected: String, found: String?)

        public var errorDescription: String? {
            switch self {
            case .unsignedCurrent:
                return tr("지금 앱이 서명 없는 개발 빌드라 내려받은 앱의 서명을 비교할 수 없어요. GitHub 에서 직접 받아 설치하세요.")
            case .mount(let m): return tr("DMG 를 열지 못했어요: %@", m)
            case .noApp: return tr("DMG 안에 GodDB.app 이 없어요")
            case .codesign(let m): return tr("코드 서명 확인 실패: %@", m)
            case .teamMismatch(let e, let f):
                return tr("서명한 개발자(팀 ID)가 지금 앱과 달라요 (지금 %@, 받은 앱 %@)", e, f ?? tr("서명 없음"))
            case .bundleMismatch(let e, let f): return tr("다른 앱이에요 (번들 ID %@ ≠ %@)", f ?? "?", e)
            case .notarization(let m): return tr("Apple 공증 확인 실패: %@", m)
            case .requiresNewerOS(let v): return tr("이 버전은 macOS %@ 이상이 필요해요", v)
            case .versionMismatch(let e, let f): return tr("받은 앱의 버전(%@)이 고른 버전(%@)과 달라요", f ?? "?", e)
            }
        }
    }

    /// 실행 중인 앱의 서명 팀 ID (Security.framework). 서명 없는 개발 빌드 · ad-hoc 서명이면 nil
    public static func currentTeamID() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        let team = dict[kSecCodeInfoTeamIdentifier as String] as? String
        return team?.isEmpty == false ? team : nil
    }

    /// 검증을 통과한 새 앱 (DMG 를 연 채로 둔다 — 도우미가 복사한 뒤 닫는다)
    public struct VerifiedApp: Sendable, Equatable {
        public var appURL: URL
        public var mountPoint: URL
        public var signing: SigningInfo
        public var version: String?
    }

    /// DMG 를 읽기 전용으로 열고 안의 앱을 확인한다:
    /// `codesign --verify --deep --strict` → 팀 ID 가 지금 앱과 같음 → 번들 ID 같음 → `spctl --assess --type execute`(공증) →
    /// 최소 macOS · 버전 확인. 하나라도 실패하면 DMG 를 닫고 이유를 던진다.
    public static func mountAndVerify(dmg: URL, mountPoint: URL, expectedTeamID: String?, expectedBundleID: String?,
                                      expectedVersion: String?,
                                      os: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) throws -> VerifiedApp {
        guard let expectedTeamID, !expectedTeamID.isEmpty else { throw InstallError.unsignedCurrent }
        try? FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        let attach = SSHHostKeys.run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen",
                                                          "-mountpoint", mountPoint.path, dmg.path], timeout: 120)
        guard attach.status == 0 else { throw InstallError.mount(lastLine(attach.stderr, attach.stdout)) }
        do {
            let apps = (try? FileManager.default.contentsOfDirectory(at: mountPoint, includingPropertiesForKeys: nil)) ?? []
            guard let app = apps.first(where: { $0.lastPathComponent == "GodDB.app" })
                    ?? apps.first(where: { $0.pathExtension == "app" }) else { throw InstallError.noApp }

            let verify = SSHHostKeys.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path], timeout: 120)
            guard verify.status == 0 else { throw InstallError.codesign(lastLine(verify.stderr, verify.stdout)) }

            let display = SSHHostKeys.run("/usr/bin/codesign", ["-dv", "--verbose=2", app.path], timeout: 30)
            let signing = signingInfo(fromCodesignOutput: display.stderr + "\n" + display.stdout)
            guard signing.teamID == expectedTeamID else {
                throw InstallError.teamMismatch(expected: expectedTeamID, found: signing.teamID)
            }
            let plist = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any] ?? [:]
            let bundleID = plist["CFBundleIdentifier"] as? String
            if let expectedBundleID, bundleID != expectedBundleID {
                throw InstallError.bundleMismatch(expected: expectedBundleID, found: bundleID)
            }

            let assess = SSHHostKeys.run("/usr/sbin/spctl", ["--assess", "--type", "execute", app.path], timeout: 120)
            guard assess.status == 0 else { throw InstallError.notarization(lastLine(assess.stderr, assess.stdout)) }

            let minOS = plist["LSMinimumSystemVersion"] as? String
            guard supports(minimumSystemVersion: minOS, os: os) else { throw InstallError.requiresNewerOS(minOS ?? "?") }
            let version = plist["CFBundleShortVersionString"] as? String
            if let expectedVersion, version != expectedVersion {
                throw InstallError.versionMismatch(expected: expectedVersion, found: version)
            }
            return VerifiedApp(appURL: app, mountPoint: mountPoint, signing: signing, version: version)
        } catch {
            detach(mountPoint)
            throw error
        }
    }

    /// DMG 닫기 (안 되면 강제로)
    public static func detach(_ mountPoint: URL) {
        if SSHHostKeys.run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-quiet"], timeout: 60).status != 0 {
            _ = SSHHostKeys.run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-quiet", "-force"], timeout: 60)
        }
    }

    private static func lastLine(_ a: String, _ b: String) -> String {
        let lines = (a + "\n" + b).components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.contains("is deprecated") }
        return lines.last ?? tr("알 수 없는 오류")
    }

    // MARK: - 교체 도우미 스크립트

    /// sh 용 작은따옴표 인용 (공백 · 따옴표 · $ · 한글이 들어간 경로도 안전)
    public static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// 앱이 끝나기를 기다렸다가 새 앱으로 바꾸고 다시 여는 /bin/sh 스크립트.
    /// - 새 앱을 먼저 옆자리 임시 이름으로 `ditto` 하고 격리 속성을 지운 뒤, 원래 앱을 옆으로 옮기고 새 앱을 제자리에 놓는다.
    ///   어느 단계에서든 실패하면 원래 앱을 제자리에 두고 실패 표시 파일(`failureMarker`)에 이유를 쓰고 원래 앱을 다시 연다.
    /// - 앱이 `waitSeconds` 안에 끝나지 않으면(종료 취소 등) 아무것도 바꾸지 않고 실패 표시만 남긴다.
    public static func helperScript(pid: Int32, newApp: String, target: String, mountPoint: String,
                                    failureMarker: String, waitSeconds: Int = 60) -> String {
        let q = shellQuote
        return """
        #!/bin/sh
        # GodDB 이전 버전 설치 도우미 (앱이 만든 임시 스크립트)
        PID=\(pid)
        SRC=\(q(newApp))
        DST=\(q(target))
        MNT=\(q(mountPoint))
        MARKER=\(q(failureMarker))
        NEW="$DST.goddb-new-$$"
        OLD="$DST.goddb-old-$$"

        detach() { /usr/bin/hdiutil detach "$MNT" -quiet >/dev/null 2>&1 || /usr/bin/hdiutil detach "$MNT" -quiet -force >/dev/null 2>&1; }
        fail() {
          /bin/mkdir -p "$(/usr/bin/dirname "$MARKER")"
          printf '%s\\n' "$1" > "$MARKER"
          /bin/rm -rf "$NEW"
          detach
          [ "$2" = "reopen" ] && /usr/bin/open "$DST"
          exit 1
        }

        i=0
        while /bin/kill -0 "$PID" 2>/dev/null; do
          i=$((i + 1))
          [ "$i" -gt \(max(1, waitSeconds) * 5) ] && fail "timeout" keep
          /bin/sleep 0.2
        done

        /bin/rm -rf "$NEW"
        /usr/bin/ditto "$SRC" "$NEW" || fail "copy" reopen
        /usr/bin/xattr -dr com.apple.quarantine "$NEW" 2>/dev/null
        /bin/mv "$DST" "$OLD" || fail "move" reopen
        if ! /bin/mv "$NEW" "$DST"; then
          /bin/mv "$OLD" "$DST"
          fail "swap" reopen
        fi
        /bin/rm -rf "$OLD"
        detach
        /usr/bin/open "$DST"
        exit 0
        """ + "\n"
    }

    /// 도우미가 남긴 실패 이유 코드 → 화면 문구 키
    public enum HelperFailure: String, Sendable {
        case timeout, copy, move, swap
    }
}
