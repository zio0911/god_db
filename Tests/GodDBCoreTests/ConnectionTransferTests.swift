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
