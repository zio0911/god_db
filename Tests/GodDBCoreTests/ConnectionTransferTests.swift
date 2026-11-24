import Foundation
import Testing
@testable import GodDBCore

@Suite("ConnectionTransfer")
struct ConnectionTransferTests {
    let a = ConnectionProfile(kind: .mysql, name: "dev", host: "db.local", port: 3306, username: "app",
                              database: "main", ssh: SSHConfig(host: "bastion", keyPath: "~/.ssh/id"))
    let b = ConnectionProfile(kind: .postgres, name: "pg", host: "pg.local", port: 5432, username: "pg")

    @Test func roundTripWithoutPasswords() throws {
        let data = try ConnectionTransfer.export([a, b], appVersion: "0.7.5")
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("goddb-connections"))
        #expect(!text.contains("passwords"))
        let bundle = try ConnectionTransfer.parse(data)
        #expect(bundle.profiles == [a, b])
        #expect(!bundle.hasPasswords)
        #expect(bundle.app == "GodDB 0.7.5")
    }

    @Test func passwordsAreEncrypted() throws {
        let data = try ConnectionTransfer.export([a, b], passwords: [a.id: "s3cret-pw", UUID(): "other"],
                                                 passphrase: "team-pass")
        #expect(!String(decoding: data, as: UTF8.self).contains("s3cret-pw"))
        let bundle = try ConnectionTransfer.parse(data)
        #expect(bundle.hasPasswords)
        #expect(try ConnectionTransfer.passwords(in: bundle, passphrase: "team-pass") == [a.id: "s3cret-pw"])
        #expect(throws: ConnectionTransferError.wrongPassphrase) {
            try ConnectionTransfer.passwords(in: bundle, passphrase: "wrong")
        }
    }

    /// 새로 내보내면 60만 회, 1.4.2 까지의 20만 회 파일도 그대로 열림, 터무니없는 횟수는 거절 (#191)
    @Test func keyStrengthAndOldFiles() throws {
        let data = try ConnectionTransfer.export([a], passwords: [a.id: "pw"], passphrase: "team-pass")
        #expect(try ConnectionTransfer.parse(data).passwords?.rounds == 600_000)

        let plain = try JSONEncoder().encode([a.id.uuidString: "old-pw"])
        let old = try ConnectionTransfer.encrypt(plain, passphrase: "team-pass", rounds: 200_000)
        #expect(old.rounds == 200_000)
        #expect(try ConnectionTransfer.decrypt(old, passphrase: "team-pass") == plain)

        var huge = old
        huge.rounds = 2_000_000_000
        #expect(throws: ConnectionTransferError.notGodDBFile) { try ConnectionTransfer.decrypt(huge, passphrase: "team-pass") }
    }

    /// 접속 목록 파일은 나만 읽고 쓰게 (0600), 예전 0644 파일도 읽을 때 맞춤 (#191)
    @Test func profileFileIsPrivate() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("goddb-perm-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("profiles.json")
        let store = ProfileStore(fileURL: url)
        try store.save([a])
        func mode() throws -> Int { (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? -1 }
        #expect(try mode() == 0o600)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        #expect(store.load().count == 1)
        #expect(try mode() == 0o600)
    }

    /// 같은 ID 로 가져올 때 서버 · 계정이 바뀌면 예전 비밀번호를 쓰지 않는다 (#197)
    @Test func savedPasswordOnlyForSameServer() {
        var old = ConnectionProfile(kind: .mysql, name: "a", host: "db.example.test", port: 3306, username: "app")
        var same = old
        same.name = "이름만 바뀜"
        same.host = "DB.example.test"
        #expect(ConnectionTransfer.savedPasswordStillApplies(old: old, new: same))
        for change in [{ (p: inout ConnectionProfile) in p.host = "other.example.test" },
                       { p in p.port = 3307 }, { p in p.username = "root" }, { p in p.kind = .postgres },
                       { p in p.ssh = SSHConfig(host: "bastion.example.test") }] {
            var n = old
            change(&n)
            #expect(!ConnectionTransfer.savedPasswordStillApplies(old: old, new: n))
        }
        old.ssh = SSHConfig(host: "b.example.test", username: "u")
        var viaOther = old
        viaOther.ssh = SSHConfig(host: "b.example.test", username: "v")
        #expect(!ConnectionTransfer.savedPasswordStillApplies(old: old, new: viaOther))
    }

    @Test func passwordsNeedPassphrase() {
        #expect(throws: ConnectionTransferError.emptyPassphrase) {
            try ConnectionTransfer.export([a], passwords: [a.id: "x"], passphrase: "")
        }
    }

    @Test func rejectsOtherFiles() {
        #expect(throws: ConnectionTransferError.notGodDBFile) {
            try ConnectionTransfer.parse(Data("[1,2]".utf8))
        }
        #expect(throws: ConnectionTransferError.notGodDBFile) {
            try ConnectionTransfer.parse(Data(#"{"format":"other","version":1,"exportedAt":"2026-01-01T00:00:00Z","app":"x","profiles":[]}"#.utf8))
        }
    }

    @Test func mergeReplacesSameIDAndRenamesDuplicates() {
        var changed = a
        changed.host = "new.host"
        let sameName = ConnectionProfile(name: "pg", host: "other")
        let merged = ConnectionTransfer.merge([changed, sameName], into: [a, b])
        #expect(merged.count == 3)
        #expect(merged[0].host == "new.host")
        #expect(merged[2].name == "pg (2)")
        #expect(ConnectionTransfer.action(for: changed, existing: [a]) == .replace(existingName: "dev"))
        #expect(ConnectionTransfer.action(for: sameName, existing: [a, b]) == .add)
    }
}
