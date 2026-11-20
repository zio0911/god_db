import Foundation
import Testing
@testable import GodDBCore

@Suite("PreviousVersions")
struct PreviousVersionsTests {
    static func asset(_ v: String) -> PreviousVersions.Asset {
        PreviousVersions.Asset(name: "GodDB-\(v).dmg",
                               browserDownloadURL: URL(string: "https://github.com/zio0911/god_db/releases/download/v\(v)/GodDB-\(v).dmg")!,
                               size: 17_000_000)
    }

    static func release(_ v: String, draft: Bool = false, prerelease: Bool = false, body: String = "",
                        dmg: Bool = true) -> PreviousVersions.Release {
        PreviousVersions.Release(tagName: "v\(v)", draft: draft, prerelease: prerelease,
                                 publishedAt: Date(timeIntervalSince1970: 1_800_000_000), body: body,
                                 assets: dmg ? [asset(v)] : [])
    }

    /// 1.3.7 릴리스 노트 (scripts/release-notes.sh + GitHub 자동 생성 부분)
    static let body137 = """
    ## 변경 사항
    - ⌘↩ 는 커서가 있는 문장(강조된 문장)만 실행. 모든 문장은 새 **전체 실행** 버튼 또는 ⌥⌘↩
    - 끌어서 바꾼 화면 크기를 기억. 메뉴 보기 > **레이아웃 초기화** 로 처음 크기로
    - DB 종류를 로고 아이콘으로
    - 설정 > 일반 > 안전: 위험한 명령 확인을 켜고 끌 수 있음

    ## 설치
    `GodDB-*.dmg` 를 열고 GodDB 를 Applications 로 끌어다 놓은 뒤 실행하세요.
    이미 1.1.0 이상을 쓰고 있으면 앱이 자동으로 업데이트를 알려줘요.


    <!-- Release notes generated using configuration in .github/release.yml at v1.3.7 -->

    ## What's Changed
    ### 새 기능
    * feat: 화면 경계 크기 기억 by @zio0911 in https://github.com/zio0911/god_db/pull/100

    **Full Changelog**: https://github.com/zio0911/god_db/compare/v1.3.6...v1.3.7
    """

    // MARK: - 목록

    @Test func decodesGitHubJSON() throws {
        let json = """
        [{"tag_name":"v1.3.6","draft":false,"prerelease":false,"published_at":"2026-11-18T01:50:54Z",
          "html_url":"https://github.com/zio0911/god_db/releases/tag/v1.3.6","body":"## 변경 사항\\r\\n- 고침",
          "assets":[{"name":"appcast.xml","browser_download_url":"https://x/appcast.xml","size":10},
                    {"name":"GodDB-1.3.6.dmg","browser_download_url":"https://x/GodDB-1.3.6.dmg","size":17663224}]}]
        """
        let releases = try PreviousVersions.decode(Data(json.utf8))
        #expect(releases.count == 1)
        #expect(releases[0].publishedAt != nil)
        let entries = PreviousVersions.entries(from: releases, current: "1.4.0")
        #expect(entries.map(\.version) == ["1.3.6"])
        #expect(entries[0].dmg.size == 17663224)
        #expect(entries[0].dmg.browserDownloadURL.absoluteString == "https://x/GodDB-1.3.6.dmg")
        #expect(entries[0].notes == ["고침"])
    }

    @Test func filtersDraftPrereleaseOldAndCurrent() {
        let releases = [
            Self.release("1.4.0"),                    // 지금 버전
            Self.release("1.3.7"),
            Self.release("1.3.8", draft: true),
            Self.release("1.5.0", prerelease: true),
            Self.release("1.0.0"),                    // 1.1.0 미만
            Self.release("0.9.1"),
            Self.release("1.1.0"),                    // 경계: 포함
            Self.release("1.2.0", dmg: false),        // 설치 파일 없음
            PreviousVersions.Release(tagName: "nightly", assets: [Self.asset("nightly")]),
        ]
        let versions = PreviousVersions.entries(from: releases, current: "1.4.0").map(\.version)
        #expect(versions == ["1.3.7", "1.1.0"])
    }

    @Test func sortsNewestFirstNumerically() {
        let releases = ["1.2.1", "1.10.0", "1.3.7", "1.9.2", "1.3.10", "1.1.0"].map { Self.release($0) }
        let versions = PreviousVersions.entries(from: releases, current: "dev").map(\.version)
        #expect(versions == ["1.10.0", "1.9.2", "1.3.10", "1.3.7", "1.2.1", "1.1.0"])
    }

    @Test func dmgAssetNeedsExactName() {
        let assets = [
            PreviousVersions.Asset(name: "appcast.xml", browserDownloadURL: URL(string: "https://x/a")!, size: 1),
            PreviousVersions.Asset(name: "GodDB-1.3.5.dmg", browserDownloadURL: URL(string: "https://x/b")!, size: 1),
            PreviousVersions.Asset(name: "GodDB-1.3.6.dmg", browserDownloadURL: URL(string: "https://x/c")!, size: 1),
        ]
        #expect(PreviousVersions.dmgAsset(assets, version: "1.3.6")?.browserDownloadURL.absoluteString == "https://x/c")
        #expect(PreviousVersions.dmgAsset(assets, version: "1.3.7") == nil)
    }

    @Test func versionFromTag() {
        #expect(PreviousVersions.version(fromTag: "v1.3.6") == "1.3.6")
        #expect(PreviousVersions.version(fromTag: "1.10.0") == "1.10.0")
        #expect(PreviousVersions.version(fromTag: "v1.4.0-beta") == nil)
        #expect(PreviousVersions.version(fromTag: "latest") == nil)
    }

    // MARK: - 변경 사항

    @Test func changeNotesTakeFirstThreeUnderChanges() {
        let notes = PreviousVersions.changeNotes(Self.body137)
        #expect(notes == [
            "⌘↩ 는 커서가 있는 문장(강조된 문장)만 실행. 모든 문장은 새 **전체 실행** 버튼 또는 ⌥⌘↩",
            "끌어서 바꾼 화면 크기를 기억. 메뉴 보기 > **레이아웃 초기화** 로 처음 크기로",
            "DB 종류를 로고 아이콘으로",
        ])
    }

    @Test func changeNotesOlderHeadings() {
        // 1.1.0: 설치 안내가 먼저, 변경은 "## 주요 변경"
        let body110 = """
        ## 설치
        `GodDB-1.1.0.dmg` 를 열고 끌어다 놓으세요.

        ## 주요 변경
        - **트랜잭션**: 자동 커밋 / 수동 커밋
        - **자동 업데이트**

        ## What's Changed
        * 트랜잭션 by @zio0911 in https://github.com/zio0911/god_db/pull/20
        """
        #expect(PreviousVersions.changeNotes(body110) == ["**트랜잭션**: 자동 커밋 / 수동 커밋", "**자동 업데이트**"])
        // 1.3.1: "## 수정" 다음 "## 개발" (개발 항목은 뺀다)
        let body131 = "## 수정\n- 고침 A\n\n## 개발\n- CI 정리\n- 빌드\n"
        #expect(PreviousVersions.changeNotes(body131) == ["고침 A"])
    }

    @Test func changeNotesFallBackToGeneratedList() {
        // 1.3.3: 자동 생성 부분만 있음
        let body = """
        <!-- Release notes generated using configuration in .github/release.yml at v1.3.3 -->

        ## What's Changed
        ### 버그 수정
        * fix: ORDER BY 없는 결과 이어 받기 by @zio0911 in https://github.com/zio0911/god_db/pull/82
        """
        #expect(PreviousVersions.changeNotes(body) == ["fix: ORDER BY 없는 결과 이어 받기"])
        #expect(PreviousVersions.changeNotes("").isEmpty)
    }

    // MARK: - 백업

    @Test func backupNameUsesVersionAndLocalStamp() {
        let utc = TimeZone(identifier: "UTC")!
        let date = Date(timeIntervalSince1970: 1_795_000_000)   // 2026-11-18 ...
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = utc; f.dateFormat = "yyyyMMdd-HHmmss"
        let name = PreviousVersions.backupName(current: "1.4.0", date: date, timeZone: utc)
        #expect(name == "GodDB-backup-1.4.0-" + f.string(from: date))
        #expect(PreviousVersions.backupStamp(name) == f.string(from: date))
    }

    @Test func pruneKeepsThreeNewestBackupsOnly() {
        let names = [
            "GodDB",
            "GodDB-backup-1.3.7-20261118-090000",
            "GodDB-backup-1.4.0-20261120-101500",
            "GodDB-backup-1.4.0-20261120-101501",
            "GodDB-backup-1.3.6-20261101-235959",
            "GodDB-backup-1.4.0-20261119-120000",
            "GodDB-backup-notes",                 // 백업 꼴 아님 → 건드리지 않음
            "GodDB-backup--20261120-000000",      // 버전 없음 → 건드리지 않음
            "Other-20261120-000000",
        ]
        let prune = PreviousVersions.backupsToPrune(names)
        #expect(Set(prune) == ["GodDB-backup-1.3.7-20261118-090000", "GodDB-backup-1.3.6-20261101-235959"])
        #expect(PreviousVersions.backupsToPrune(Array(names.prefix(3))).isEmpty)
        #expect(PreviousVersions.backupsToPrune(names, keep: 0).count == 5)
    }

    // MARK: - 서명

    @Test func parsesDeveloperIDSigning() {
        let out = """
        Executable=/Volumes/GodDB/GodDB.app/Contents/MacOS/GodDB
        Identifier=local.goddb.app
        Format=app bundle with Mach-O thin (arm64)
        CodeDirectory v=20500 size=74459 flags=0x10000(runtime) hashes=2320+3 location=embedded
        Authority=Developer ID Application: Example Developer (ABCDE12345)
        Authority=Developer ID Certification Authority
        Authority=Apple Root CA
        TeamIdentifier=ABCDE12345
        """
        let info = PreviousVersions.signingInfo(fromCodesignOutput: out)
        #expect(info.teamID == "ABCDE12345")
        #expect(info.identifier == "local.goddb.app")
        #expect(info.authority == "Developer ID Application: Example Developer (ABCDE12345)")
    }

    @Test func adHocSigningHasNoTeam() {
        let out = "Identifier=local.goddb.app\nSignature=adhoc\nTeamIdentifier=not set\n"
        #expect(PreviousVersions.signingInfo(fromCodesignOutput: out).teamID == nil)
        #expect(PreviousVersions.signingInfo(fromCodesignOutput: "code object is not signed at all").teamID == nil)
    }

    @Test func minimumSystemVersion() {
        let os26 = OperatingSystemVersion(majorVersion: 26, minorVersion: 1, patchVersion: 0)
        #expect(PreviousVersions.supports(minimumSystemVersion: "15.0", os: os26))
        #expect(PreviousVersions.supports(minimumSystemVersion: "26.0", os: os26))
        #expect(PreviousVersions.supports(minimumSystemVersion: nil, os: os26))
        #expect(!PreviousVersions.supports(minimumSystemVersion: "26.2", os: os26))
        #expect(!PreviousVersions.supports(minimumSystemVersion: "27.0", os: os26))
    }

    @Test func unsignedCurrentBuildIsRefused() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("goddb-pv-\(UUID().uuidString)")
        #expect(throws: PreviousVersions.InstallError.unsignedCurrent) {
            try PreviousVersions.mountAndVerify(dmg: tmp.appendingPathComponent("x.dmg"), mountPoint: tmp,
                                                expectedTeamID: nil, expectedBundleID: nil, expectedVersion: nil)
        }
    }

    /// 가짜 서명(ad-hoc) 앱을 담은 DMG 는 팀 ID 가 달라 거부되고, DMG 는 닫힌다
    @Test func rejectsAppSignedByAnotherTeam() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("goddb-pv-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let app = root.appendingPathComponent("src/GodDB.app/Contents", isDirectory: true)
        try fm.createDirectory(at: app.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        let exe = app.appendingPathComponent("MacOS/GodDB")
        try "#!/bin/sh\nexit 0\n".write(to: exe, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
        let plist: [String: Any] = ["CFBundleIdentifier": "local.goddb.app", "CFBundleExecutable": "GodDB",
                                    "CFBundleShortVersionString": "1.3.6", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Info.plist"))
        let bundle = root.appendingPathComponent("src/GodDB.app").path
        #expect(SSHHostKeys.run("/usr/bin/codesign", ["-s", "-", "--force", bundle], timeout: 30).status == 0)
        let dmg = root.appendingPathComponent("fake.dmg")
        let create = SSHHostKeys.run("/usr/bin/hdiutil", ["create", "-quiet", "-srcfolder", root.appendingPathComponent("src").path,
                                                          "-volname", "GodDBTest", "-format", "UDZO", dmg.path], timeout: 120)
        try #require(create.status == 0, "hdiutil create: \(create.stderr)")

        let mount = root.appendingPathComponent("mnt with space", isDirectory: true)
        #expect(throws: PreviousVersions.InstallError.teamMismatch(expected: "ABCDE12345", found: nil)) {
            try PreviousVersions.mountAndVerify(dmg: dmg, mountPoint: mount, expectedTeamID: "ABCDE12345",
                                                expectedBundleID: "local.goddb.app", expectedVersion: "1.3.6")
        }
        // 닫혔으면 마운트 지점은 비어 있다
        #expect(((try? fm.contentsOfDirectory(atPath: mount.path)) ?? []).isEmpty)
    }

    // MARK: - 도우미 스크립트

    @Test func shellQuoteHandlesTrickyCharacters() {
        #expect(PreviousVersions.shellQuote("/Applications/GodDB.app") == "'/Applications/GodDB.app'")
        #expect(PreviousVersions.shellQuote("it's") == #"'it'\''s'"#)
    }

    @Test func helperScriptQuotesPathsWithSpaces() throws {
        let src = "/private/tmp/GodDB install/mnt/GodDB.app"
        let dst = "/Users/me/내 앱's/$HOME `x` \"q\"/GodDB.app"
        let mnt = "/private/tmp/GodDB install/mnt"
        let marker = "/Users/me/Library/Application Support/GodDB/previous-version-install-failed.txt"
        let script = PreviousVersions.helperScript(pid: 4242, newApp: src, target: dst, mountPoint: mnt,
                                                   failureMarker: marker, waitSeconds: 30)
        #expect(script.hasPrefix("#!/bin/sh\n"))
        #expect(script.contains("PID=4242\n"))
        #expect(script.contains("-gt 150 ]"))
        // 새 앱을 옆자리에 먼저 복사하고 → 격리 속성 제거 → 바꿔치기 → DMG 닫기 → 다시 열기 순서
        let order = ["ditto \"$SRC\" \"$NEW\"", "xattr -dr com.apple.quarantine \"$NEW\"", "mv \"$DST\" \"$OLD\"",
                     "mv \"$NEW\" \"$DST\"", "rm -rf \"$OLD\"", "open \"$DST\"\nexit 0"]
        let positions = order.map { script.range(of: $0)?.lowerBound }
        #expect(positions.allSatisfy { $0 != nil })
        #expect(positions.compactMap { $0 } == positions.compactMap { $0 }.sorted())

        // 문법 확인 (실행하지 않음)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("goddb-pv-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("helper.sh")
        try script.write(to: file, atomically: true, encoding: .utf8)
        #expect(SSHHostKeys.run("/bin/sh", ["-n", file.path], timeout: 10).status == 0)

        // 변수 줄만 실행해 경로가 그대로 들어가는지
        let header = script.components(separatedBy: "\n").filter { line in
            ["SRC=", "DST=", "MNT=", "MARKER="].contains { line.hasPrefix($0) }
        }.joined(separator: "\n")
        let probe = header + "\nprintf '%s\\n' \"$SRC\" \"$DST\" \"$MNT\" \"$MARKER\"\n"
        let out = SSHHostKeys.run("/bin/sh", ["-c", probe], timeout: 10)
        #expect(out.status == 0)
        #expect(out.stdout == [src, dst, mnt, marker].joined(separator: "\n") + "\n")
    }
}
