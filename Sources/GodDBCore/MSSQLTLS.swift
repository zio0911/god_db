import Foundation
import NIOCore
import NIOPosix
import NIOSSL
import NIOTLS
import Security

// F9-3. SQL Server 서버 인증서 확인
// FreeTDS(DB-Library) 에는 인증서 확인 콜백이 없어서 두 단계로 확인한다.
// 1) 미리 받기: PRELOGIN(ENCRYPTION=ON) 을 보내고, TDS 패킷(0x12)에 감싼 TLS 핸드셰이크로 서버 인증서만 받는다.
//    받은 인증서는 다른 DB 와 같은 판정(TLSVerifier — 시스템 신뢰 저장소 → 고정 지문 → 확인 창)을 거친다. 로그인은 하지 않는다.
// 2) FreeTDS 연결: 같은 IP · 포트로, 판정에 맞는 "ca file"(+ 이름 확인)을 넣은 freetds.conf 섹션으로 연결해
//    FreeTDS(OpenSSL) 도 인증서를 다시 확인하게 한다. 고정 인증서인데 체인을 자체 서명 인증서로 끝낼 수 없으면
//    FreeTDS 쪽은 암호화만 한다 (두 연결 사이의 짧은 틈 — docs/specs/1.4.0.md F9-3).

enum MSSQLTLS {
    // MARK: - TDS 패킷

    /// PRELOGIN 패킷 종류 (TDS 7.x 에서는 TLS 핸드셰이크도 이 종류의 패킷에 감싼다)
    static let preloginType: UInt8 = 0x12
    /// 패킷 머리 8바이트
    static let headerSize = 8
    /// 핸드셰이크에 쓰는 패킷 크기 (로그인 전 기본값)
    static let packetSize = 4096

    /// PRELOGIN ENCRYPTION 값
    enum Encryption: UInt8 {
        case off = 0x00, on = 0x01, notSupported = 0x02, required = 0x03
    }

    /// 페이로드 → TDS 패킷들 (마지막 패킷에 EOM)
    static func packets(_ payload: [UInt8], type: UInt8 = preloginType, maxSize: Int = packetSize) -> [UInt8] {
        let chunk = maxSize - headerSize
        var out: [UInt8] = []
        var offset = 0
        var id: UInt8 = 1
        repeat {
            let end = min(offset + chunk, payload.count)
            let length = end - offset + headerSize
            out += [type, end == payload.count ? 0x01 : 0x00, UInt8(length >> 8), UInt8(length & 0xFF), 0, 0, id, 0]
            out += payload[offset..<end]
            offset = end
            id &+= 1
        } while offset < payload.count
        return out
    }

    /// PRELOGIN 메시지: VERSION · ENCRYPTION=ON · INSTOPT · THREADID · MARS=off
    static func preloginPayload() -> [UInt8] {
        let options: [(token: UInt8, data: [UInt8])] = [
            (0x00, [9, 0, 0, 0, 0, 0]),
            (0x01, [Encryption.on.rawValue]),
            (0x02, [0]),
            (0x03, [0, 0, 0, 0]),
            (0x04, [0]),
        ]
        var offset = options.count * 5 + 1
        var head: [UInt8] = []
        var body: [UInt8] = []
        for o in options {
            head += [o.token, UInt8(offset >> 8), UInt8(offset & 0xFF), UInt8(o.data.count >> 8), UInt8(o.data.count & 0xFF)]
            body += o.data
            offset += o.data.count
        }
        return head + [0xFF] + body
    }

    /// PRELOGIN 응답에서 ENCRYPTION 값 (없거나 깨졌으면 nil)
    static func encryption(inPreloginResponse payload: [UInt8]) -> Encryption? {
        var i = 0
        while i < payload.count, payload[i] != 0xFF {
            guard i + 5 <= payload.count else { return nil }
            let token = payload[i]
            let offset = Int(payload[i + 1]) << 8 | Int(payload[i + 2])
            let length = Int(payload[i + 3]) << 8 | Int(payload[i + 4])
            if token == 0x01 {
                guard length >= 1, offset < payload.count else { return nil }
                return Encryption(rawValue: payload[offset])
            }
            i += 5
        }
        return nil
    }

    // MARK: - 인증서 미리 받기

    /// 받은 인증서 체인(서버 인증서 먼저)과 이 주소에서의 판정
    struct Probe: Sendable {
        var chain: [[UInt8]]
        var verdict: TLSVerdict
    }

    /// 서버 인증서를 받아 판정한다. 거부하면 TLSCertificateError(인증서 정보 포함)를 던진다.
    static func probe(ip: String, port: Int, serverName: String?, verifier: TLSVerifier,
                      timeout: TimeAmount = .seconds(10)) async throws -> Probe {
        let box = ProbeBox()
        let callback: @Sendable ([NIOSSLCertificate], EventLoopPromise<NIOSSLVerificationResult>) -> Void = { certs, promise in
            let ders = certs.compactMap { try? $0.toDERBytes() }
            // 시스템 확인은 네트워크(폐기 확인)를 쓸 수 있어 이벤트 루프 밖에서
            DispatchQueue.global(qos: .userInitiated).async {
                let v = verifier.judge(chain: ders)
                box.set(chain: ders, verdict: v)
                promise.succeed(v.allowsConnection ? .certificateVerified : .failed)
            }
        }
        let tls = try NIOSSLContext(configuration: TLSVerify.tlsConfiguration(verify: true))
        let group = MultiThreadedEventLoopGroup.singleton
        let done = group.any().makePromise(of: Void.self)
        let framer = TDSFramer()
        let channel: Channel
        do {
            channel = try await ClientBootstrap(group: group)
                .connectTimeout(timeout)
                .channelInitializer { ch in
                    do {
                        try ch.pipeline.syncOperations.addHandler(framer)
                        try ch.pipeline.syncOperations.addHandler(ProbeHandler(
                            framer: framer, done: done,
                            makeTLS: { try NIOSSLClientHandler(context: tls, serverHostname: serverName, customVerificationCallback: callback) }))
                        return ch.eventLoop.makeSucceededVoidFuture()
                    } catch {
                        return ch.eventLoop.makeFailedFuture(error)
                    }
                }
                .connect(to: try SocketAddress(ipAddress: ip, port: port)).get()
        } catch {
            done.fail(error)
            throw error
        }
        let timer = channel.eventLoop.scheduleTask(in: timeout) {
            channel.pipeline.fireErrorCaught(MSSQLError(number: 20003, message: tr("서버 인증서를 받는 중에 시간이 초과됐어요.")))
        }
        do {
            try await done.futureResult.get()
            timer.cancel()
            try? await channel.close()
        } catch {
            timer.cancel()
            try? await channel.close()
            if let failure = verifier.failure { throw failure }
            throw error
        }
        guard let verdict = box.verdict, let chain = box.chain else {
            throw MSSQLError(number: 20002, message: tr("서버 인증서를 받지 못했어요."))
        }
        return Probe(chain: chain, verdict: verdict)
    }

    final class ProbeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _chain: [[UInt8]]?
        private var _verdict: TLSVerdict?
        func set(chain: [[UInt8]], verdict: TLSVerdict) { lock.withLock { _chain = chain; _verdict = verdict } }
        var chain: [[UInt8]]? { lock.withLock { _chain } }
        var verdict: TLSVerdict? { lock.withLock { _verdict } }
    }

    /// 아래(소켓) 쪽: 보내는 바이트를 PRELOGIN 패킷에 감싸고, 받은 패킷에서 페이로드를 꺼낸다.
    /// - prelogin 단계: EOM 까지 모아 메시지 하나로 넘긴다
    /// - tls 단계: 패킷마다 페이로드를 바로 넘긴다 (TLS 레코드가 패킷 경계를 넘을 수 있음)
    final class TDSFramer: ChannelDuplexHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer
        typealias InboundOut = ByteBuffer
        typealias OutboundIn = ByteBuffer
        typealias OutboundOut = ByteBuffer

        var tlsMode = false
        private var pending: [UInt8] = []
        private var message: [UInt8] = []

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            var buf = unwrapInboundIn(data)
            pending += buf.readBytes(length: buf.readableBytes) ?? []
            while pending.count >= MSSQLTLS.headerSize {
                let length = Int(pending[2]) << 8 | Int(pending[3])
                guard length >= MSSQLTLS.headerSize else {
                    context.fireErrorCaught(MSSQLError(number: 20020, message: tr("서버가 보낸 TDS 패킷이 올바르지 않아요.")))
                    return
                }
                guard pending.count >= length else { break }
                let eom = pending[1] & 0x01 != 0
                let payload = Array(pending[MSSQLTLS.headerSize..<length])
                pending.removeFirst(length)
                if tlsMode {
                    context.fireChannelRead(wrapInboundOut(context.channel.allocator.buffer(bytes: payload)))
                } else {
                    message += payload
                    if eom {
                        let m = message
                        message = []
                        context.fireChannelRead(wrapInboundOut(context.channel.allocator.buffer(bytes: m)))
                    }
                }
            }
        }

        func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
            var buf = unwrapOutboundIn(data)
            let bytes = buf.readBytes(length: buf.readableBytes) ?? []
            context.write(wrapOutboundOut(context.channel.allocator.buffer(bytes: MSSQLTLS.packets(bytes))), promise: promise)
        }
    }

    /// 위쪽: PRELOGIN 을 보내고, 응답이 오면 TLS 핸드셰이크를 시작해 끝나면 알린다.
    final class ProbeHandler: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer
        private let framer: TDSFramer
        private let done: EventLoopPromise<Void>
        private let makeTLS: () throws -> NIOSSLClientHandler
        private var startedTLS = false
        private var finished = false

        init(framer: TDSFramer, done: EventLoopPromise<Void>, makeTLS: @escaping () throws -> NIOSSLClientHandler) {
            self.framer = framer
            self.done = done
            self.makeTLS = makeTLS
        }

        func channelActive(context: ChannelHandlerContext) {
            let p = MSSQLTLS.preloginPayload()
            context.writeAndFlush(NIOAny(context.channel.allocator.buffer(bytes: p)), promise: nil)
            context.fireChannelActive()
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            guard !startedTLS else { return }
            var buf = unwrapInboundIn(data)
            let payload = buf.readBytes(length: buf.readableBytes) ?? []
            let enc = MSSQLTLS.encryption(inPreloginResponse: payload)
            guard let enc, enc != .notSupported else {
                fail(context, enc == nil ? MSSQLError(number: 20020, message: tr("서버의 PRELOGIN 응답을 읽을 수 없어요."))
                                         : TLSCertificateError.serverNoTLS)
                return
            }
            startedTLS = true
            framer.tlsMode = true
            do {
                // 프레이머 바로 위에 넣는다 (핸들러가 들어가면 핸드셰이크가 바로 시작됨)
                try context.pipeline.syncOperations.addHandler(try makeTLS(), position: .before(self))
            } catch {
                fail(context, error)
            }
        }

        func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
            if case .handshakeCompleted? = event as? TLSUserEvent {
                if !finished { finished = true; done.succeed(()) }
                context.close(promise: nil)
                return
            }
            context.fireUserInboundEventTriggered(event)
        }

        func errorCaught(context: ChannelHandlerContext, error: any Error) {
            fail(context, error)
        }

        func channelInactive(context: ChannelHandlerContext) {
            if !finished {
                finished = true
                done.fail(MSSQLError(number: 20002, message: tr("서버 인증서를 받기 전에 연결이 끊어졌어요.")))
            }
            context.fireChannelInactive()
        }

        private func fail(_ context: ChannelHandlerContext, _ error: any Error) {
            if !finished { finished = true; done.fail(error) }
            context.close(promise: nil)
        }
    }

    // MARK: - FreeTDS 에 넘길 확인 설정

    /// FreeTDS(OpenSSL) 가 다시 확인할 방법
    struct FreeTDSCheck: Sendable, Equatable {
        /// "ca file" 에 넣을 인증서들 (PEM)
        var caPEM: String
        /// 이름 확인할 호스트 이름 (nil 이면 이름 확인 안 함 — 고정 인증서 · 터널)
        var hostname: String?
    }

    /// 판정 → FreeTDS 확인 설정. nil 이면 FreeTDS 는 암호화만 한다.
    /// - trusted: 시스템 루트 + macOS 가 만든 체인(사용자가 추가한 루트 포함), 이름 확인
    /// - pinned: 서버가 보낸 체인이 자체 서명 인증서로 끝나고 유효 기간 안이면 그 체인만 신뢰 (이름 확인 안 함)
    static func freeTDSCheck(verdict: TLSVerdict, chain: [[UInt8]], hostname: String?, now: Date = Date()) -> FreeTDSCheck? {
        switch verdict {
        case .trusted:
            guard let hostname else { return nil }
            let built = TLSVerify.trustedChain(chain: chain, hostname: hostname) ?? []
            let extra = built.dropFirst().map(pem)
            return FreeTDSCheck(caPEM: systemRootsPEM + extra.joined(), hostname: hostname)
        case .pinned:
            guard anchorable(chain, now: now) else { return nil }
            return FreeTDSCheck(caPEM: chain.map(pem).joined(), hostname: nil)
        default:
            return nil
        }
    }

    /// OpenSSL 이 이 체인만으로 확인할 수 있는지 (마지막이 자체 서명 · 모두 유효 기간 안)
    static func anchorable(_ chain: [[UInt8]], now: Date = Date()) -> Bool {
        guard let last = chain.last,
              let root = SecCertificateCreateWithData(nil, Data(last) as CFData),
              let subject = SecCertificateCopyNormalizedSubjectSequence(root) as Data?,
              let issuer = SecCertificateCopyNormalizedIssuerSequence(root) as Data?,
              subject == issuer else { return false }
        return chain.allSatisfy { der in
            let info = TLSVerify.certInfo(der: der)
            guard let from = info.notBefore, let to = info.notAfter else { return false }
            return from <= now && now <= to
        }
    }

    /// DER → PEM
    static func pem(_ der: [UInt8]) -> String {
        let b64 = Data(der).base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN CERTIFICATE-----\n\(b64)\n-----END CERTIFICATE-----\n"
    }

    /// macOS 시스템 루트 인증서 (PEM 묶음). 한 번 만들어 둔다.
    static let systemRootsPEM: String = {
        var anchors: CFArray?
        guard SecTrustCopyAnchorCertificates(&anchors) == errSecSuccess, let certs = anchors as? [SecCertificate] else { return "" }
        return certs.map { pem([UInt8](SecCertificateCopyData($0) as Data)) }.joined()
    }()
}

// MARK: - 연결별 freetds.conf 섹션

/// FreeTDS 는 설정 파일 위치가 프로세스 전역이다. 그래서 파일 하나(임시 폴더, 0600)를 처음에 한 번 dbsetifile 로 지정하고,
/// 연결마다 고유한 이름의 섹션을 넣었다가 연결이 끝나면 뺀다. 파일은 통째로 새로 써서 rename 으로 바꾸므로
/// 동시에 연결해도 FreeTDS 가 반쯤 쓴 파일을 읽지 않는다. 섹션이 하나도 없으면 파일을 지운다.
enum MSSQLConfigFile {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var sections: [String: String] = [:]

    /// $TMPDIR/GodDB-mssql (0700)
    static let directory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("GodDB-mssql", isDirectory: true)
    static var path: String { directory.appendingPathComponent("freetds.conf").path }

    /// 섹션 하나 (연결 한 번). 끝나면 remove() 로 설정 · CA 파일을 지운다.
    struct Entry {
        let name: String
        let caFile: URL
    }

    /// 섹션 본문 (freetds.conf 형식)
    static func sectionText(name: String, ip: String, port: Int, caFile: String, hostname: String?) -> String {
        var lines = [
            "[\(name)]",
            "\thost = \(ip)",
            "\tport = \(port)",
            "\ttds version = 7.4",
            "\tencryption = require",
            "\tca file = \(caFile)",
        ]
        if let hostname {
            lines.append("\tcheck certificate hostname = yes")
            lines.append("\tcertificate hostname = \(hostname)")
        } else {
            lines.append("\tcheck certificate hostname = no")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func add(ip: String, port: Int, check: MSSQLTLS.FreeTDSCheck) throws -> Entry {
        let name = "goddb-" + UUID().uuidString.lowercased()
        let ca = directory.appendingPathComponent(name + "-ca.pem")
        try lock.withLock {
            try ensureDirectory()
            try writePrivate(Data(check.caPEM.utf8), to: ca)
            sections[name] = sectionText(name: name, ip: ip, port: port, caFile: ca.path, hostname: check.hostname)
            try rewrite()
        }
        return Entry(name: name, caFile: ca)
    }

    static func remove(_ entry: Entry) {
        lock.withLock {
            sections[entry.name] = nil
            try? rewrite()
            try? FileManager.default.removeItem(at: entry.caFile)
        }
    }

    /// 지금 들어 있는 섹션 수 (테스트용)
    static var count: Int { lock.withLock { sections.count } }

    private static func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }

    private static func rewrite() throws {
        let file = URL(fileURLWithPath: path)
        if sections.isEmpty {
            try? FileManager.default.removeItem(at: file)
            return
        }
        let text = sections.keys.sorted().compactMap { sections[$0] }.joined(separator: "\n")
        let tmp = directory.appendingPathComponent("freetds.conf.\(UUID().uuidString)")
        try writePrivate(Data(text.utf8), to: tmp)
        guard rename(tmp.path, file.path) == 0 else {
            try? FileManager.default.removeItem(at: tmp)
            throw CocoaError(.fileWriteUnknown)
        }
    }

    /// 0600 으로 새로 만든다 (이미 있으면 실패 — 이름은 UUID 라 겹치지 않음)
    private static func writePrivate(_ data: Data, to url: URL) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        defer { close(fd) }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                guard n > 0 else { throw CocoaError(.fileWriteUnknown) }
                offset += n
            }
        }
    }
}
