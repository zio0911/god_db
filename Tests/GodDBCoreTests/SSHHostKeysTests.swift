import Foundation
import Testing
@testable import GodDBCore

@Suite("SSHHostKeys")
struct SSHHostKeysTests {
    /// 테스트용 공개키 (ssh-keygen 으로 만든 ED25519 — 어느 서버의 키도 아님)
    static let edKey = "AAAAC3NzaC1lZDI1NTE5AAAAIChtIjIrffCgho75EL9ZKPIMs9wEuDDnaOjuD4Q/Ep5M"

    static func tempFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("goddb-kh-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("known_hosts")
    }

    @Test func patternUsesBracketsForNonDefaultPort() {
        #expect(SSHHostKeys.pattern(host: "bastion.example.com", port: 22) == "bastion.example.com")
        #expect(SSHHostKeys.pattern(host: "bastion.example.com", port: 2222) == "[bastion.example.com]:2222")
    }

    @Test func sshOptionsQuoteThePathWithSpace() {
        let file = URL(fileURLWithPath: "/Users/me/Library/Application Support/GodDB/known_hosts")
        let opts = SSHHostKeys.sshOptions(godDBFile: file)
        #expect(opts == [
            "-o", "StrictHostKeyChecking=yes",
            "-o", "UserKnownHostsFile=\"~/.ssh/known_hosts\" \"/Users/me/Library/Application Support/GodDB/known_hosts\"",
        ])
    }

    @Test func tunnelArgumentsUseStrictChecking() {
        let file = URL(fileURLWithPath: "/tmp/a b/known_hosts")
        let args = SSHTunnel.arguments(
            config: SSHConfig(host: "bastion", port: 2222, username: "ec2-user"),
            localPort: 40000, remoteHost: "db", remotePort: 5432, knownHostsFile: file)
        #expect(args.contains("StrictHostKeyChecking=yes"))
        #expect(!args.contains("StrictHostKeyChecking=accept-new"))
        #expect(args.contains("UserKnownHostsFile=\"~/.ssh/known_hosts\" \"/tmp/a b/known_hosts\""))
        #expect(args.last == "ec2-user@bastion")
    }

    /// ssh 가 옵션을 실제로 두 파일로 읽는지 (ssh -G: 접속하지 않고 설정만 출력)
    @Test func sshParsesQuotedKnownHostsOption() {
        let file = URL(fileURLWithPath: "/tmp/x y/known_hosts")
        let r = SSHHostKeys.run("/usr/bin/ssh", ["-G"] + SSHHostKeys.sshOptions(godDBFile: file) + ["example.invalid"], timeout: 5)
        let line = r.stdout.split(separator: "\n").first { $0.hasPrefix("userknownhostsfile ") }
        #expect(line?.hasSuffix(" /tmp/x y/known_hosts") == true)
        #expect(line?.contains("/.ssh/known_hosts ") == true)
    }

    @Test func scanOutputParsing() {
        let out = """
        # bastion:2222 SSH-2.0-OpenSSH_9.6
        [bastion]:2222 ssh-ed25519 \(Self.edKey)
        # bastion:2222 SSH-2.0-OpenSSH_9.6

        [bastion]:2222 ecdsa-sha2-nistp256 AAAAE2VjZHNh
        garbage line
        """
        let lines = SSHHostKeys.keyLines(fromScan: out, pattern: "[alias]:2222")
        #expect(lines == ["[alias]:2222 ssh-ed25519 \(Self.edKey)", "[alias]:2222 ecdsa-sha2-nistp256 AAAAE2VjZHNh"])
    }

    @Test func fingerprintOutputParsing() {
        let out = """
        256 SHA256:9cP3abcDEF/xk+0 [bastion]:2222 (ED25519)
        3072 SHA256:RSAfp bastion (RSA)
        not a fingerprint
        """
        let keys = SSHHostKeys.parseFingerprints(out)
        #expect(keys == [
            SSHHostKeyFingerprint(type: "ED25519", fingerprint: "SHA256:9cP3abcDEF/xk+0", bits: 256),
            SSHHostKeyFingerprint(type: "RSA", fingerprint: "SHA256:RSAfp", bits: 3072),
        ])
    }

    @Test func realFingerprintFromSSHKeygen() {
        let line = "[h]:2222 ssh-ed25519 \(Self.edKey)\n"
        let r = SSHHostKeys.run("/usr/bin/ssh-keygen", ["-l", "-f", "-"], stdin: line, timeout: 5)
        let keys = SSHHostKeys.parseFingerprints(r.stdout)
        #expect(keys.count == 1)
        #expect(keys.first?.type == "ED25519")
        #expect(keys.first?.fingerprint.hasPrefix("SHA256:") == true)
    }

    @Test func configParsing() {
        let out = """
        user ec2-user
        hostname 10.1.2.3
        port 2200
        hostkeyalias none
        """
        let r = SSHHostKeys.parseConfig(out, fallbackHost: "b", fallbackPort: 22)
        #expect(r == SSHHostKeys.Resolved(hostname: "10.1.2.3", port: 2200, hostKeyAlias: nil))
        #expect(r.pattern == "[10.1.2.3]:2200")
        let alias = SSHHostKeys.parseConfig("hostname h\nport 2200\nhostkeyalias prod-bastion\n", fallbackHost: "b", fallbackPort: 22)
        #expect(alias.pattern == "prod-bastion")
        #expect(SSHHostKeys.parseConfig("", fallbackHost: "b", fallbackPort: 22).pattern == "b")
    }

    @Test func changedKeyDetection() {
        let changed = """
        @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
        @    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @
        @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
        Host key verification failed.
        """
        #expect(SSHHostKeys.classify(stderr: changed) == .changed)
        let unknown = """
        No ED25519 host key is known for [bastion]:2222 and you have requested strict checking.
        Host key verification failed.
        """
        #expect(SSHHostKeys.classify(stderr: unknown) == .unknown)
        #expect(SSHHostKeys.classify(stderr: "Host key verification failed.") == .changed)
        #expect(SSHHostKeys.classify(stderr: "Permission denied (publickey).") == nil)
    }

    @Test func appendLookupAndRemoveInTempFile() throws {
        let file = Self.tempFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let pattern = SSHHostKeys.pattern(host: "bastion.test", port: 2222)
        #expect(!SSHHostKeys.isKnown(pattern: pattern, files: [file]))

        let scan = SSHHostScan(host: "bastion.test", port: 2222, pattern: pattern,
                               lines: ["\(pattern) ssh-ed25519 \(Self.edKey)"], keys: [])
        try SSHHostKeys.trust(scan, file: file)
        // 본인만 읽고 쓰기
        let perms = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(perms == 0o600)
        #expect(SSHHostKeys.isKnown(pattern: pattern, files: [file]))
        #expect(!SSHHostKeys.isKnown(pattern: "[bastion.test]:2223", files: [file]))
        #expect(!SSHHostKeys.isKnown(pattern: "bastion.test", files: [file]))

        // 줄바꿈 없이 끝난 파일에 더해도 줄이 붙지 않는다
        try Data("other ssh-ed25519 \(Self.edKey)".utf8).write(to: file)
        try SSHHostKeys.append(["\(pattern) ssh-ed25519 \(Self.edKey)"], to: file)
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.split(separator: "\n").count == 2)

        // 지우기 (GodDB 파일에서만, 백업 .old 는 남기지 않음)
        #expect(SSHHostKeys.remove(pattern: pattern, file: file))
        #expect(!SSHHostKeys.isKnown(pattern: pattern, files: [file]))
        #expect(SSHHostKeys.isKnown(pattern: "other", files: [file]))
        #expect(!FileManager.default.fileExists(atPath: file.path + ".old"))
    }

    @Test func checkPassesForKnownHostWithoutScanning() throws {
        let file = Self.tempFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let config = SSHConfig(host: "127.0.0.1", port: 2222, username: "u")
        let pattern = SSHHostKeys.resolve(config).pattern
        try SSHHostKeys.append(["\(pattern) ssh-ed25519 \(Self.edKey)"], to: file)
        let missing = file.deletingLastPathComponent().appendingPathComponent("none")
        try SSHHostKeys.check(config, godDBFile: file, userFile: missing)
    }

    @Test func checkReportsScanFailureForUnreachableHost() {
        let file = Self.tempFile()
        let missing = file.deletingLastPathComponent().appendingPathComponent("none")
        // 이 PC 의 닫힌 포트 → 키를 받지 못함
        let config = SSHConfig(host: "127.0.0.1", port: 1, username: "u")
        #expect(throws: SSHHostKeyError.self) {
            try SSHHostKeys.check(config, godDBFile: file, userFile: missing)
        }
    }

    @Test func errorMessages() {
        let scan = SSHHostScan(host: "b", port: 22, pattern: "b", lines: [],
                               keys: [SSHHostKeyFingerprint(type: "ED25519", fingerprint: "SHA256:x")])
        #expect(SSHHostKeyError.unknown(scan).errorDescription == "처음 접속하는 SSH 서버예요 — b:22\nED25519  SHA256:x")
        #expect(SSHHostKeyError.changed(host: "b", port: 22, pattern: "b").errorDescription?.hasPrefix("SSH 서버 키가 바뀌었어요.") == true)
    }
}

/// 실제 sshd 로 확인 (호스트 키가 다른 sshd 두 개를 이 PC 에 띄운다. 인증은 하지 않고 호스트 키 단계만 본다)
///   /usr/sbin/sshd -f cfg   (ListenAddress 127.0.0.1, Port A, HostKey k1)
///   /usr/sbin/sshd -f cfg2  (Port B, HostKey k2)
///   GODDB_SSHD_PORT=A GODDB_SSHD_OTHER_PORT=B ./scripts/test.sh --filter SSHHostKeysIntegrationTests
@Suite("SSH host key integration", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["GODDB_SSHD_PORT"] != nil))
struct SSHHostKeysIntegrationTests {
    let env = ProcessInfo.processInfo.environment

    func runSSH(port: Int, knownHosts: URL) -> SSHHostKeys.StderrKind? {
        let config = SSHConfig(host: "127.0.0.1", port: port, username: "goddb-nobody")
        let args = SSHTunnel.arguments(config: config, localPort: 1, remoteHost: "127.0.0.1", remotePort: 1,
                                       knownHostsFile: knownHosts)
        let r = SSHHostKeys.run("/usr/bin/ssh", ["-F", "/dev/null"] + args, timeout: 15)
        #expect(r.status != 0)   // 인증은 실패한다 (키 없음)
        return SSHHostKeys.classify(stderr: r.stderr)
    }

    @Test func unknownThenTrustThenChanged() throws {
        let port = Int(env["GODDB_SSHD_PORT"]!)!
        let other = Int(env["GODDB_SSHD_OTHER_PORT"] ?? "") ?? 0
        let file = SSHHostKeysTests.tempFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let noUser = file.deletingLastPathComponent().appendingPathComponent("none")
        let config = SSHConfig(host: "127.0.0.1", port: port, username: "u")

        // 1) 모르는 서버 → 지문과 함께 확인 요청
        var scan: SSHHostScan?
        do { try SSHHostKeys.check(config, godDBFile: file, userFile: noUser) } catch SSHHostKeyError.unknown(let s) { scan = s }
        let s = try #require(scan)
        #expect(s.pattern == "[127.0.0.1]:\(port)")
        #expect(s.keys.contains { $0.type == "ED25519" && $0.fingerprint.hasPrefix("SHA256:") })

        // 2) 신뢰 → 다음에는 묻지 않고, ssh 도 호스트 키를 받아들인다 (인증 단계까지 감)
        try SSHHostKeys.trust(s, file: file)
        try SSHHostKeys.check(config, godDBFile: file, userFile: noUser)
        #expect(runSSH(port: port, knownHosts: file) == nil)

        // 3) 같은 이름에 다른 키를 가진 서버 → ssh 가 거부, "바뀜" 으로 판정
        if other > 0 {
            let fakeLines = s.lines.map { $0.replacingOccurrences(of: "[127.0.0.1]:\(port)", with: "[127.0.0.1]:\(other)") }
            try SSHHostKeys.append(fakeLines, to: file)
            #expect(runSSH(port: other, knownHosts: file) == .changed)
            // 4) 저장된 키 지우기 → 다시 처음 접속 확인
            #expect(SSHHostKeys.remove(pattern: "[127.0.0.1]:\(other)", file: file))
            #expect(throws: SSHHostKeyError.self) {
                try SSHHostKeys.check(SSHConfig(host: "127.0.0.1", port: other, username: "u"), godDBFile: file, userFile: noUser)
            }
        }
    }
}
