import Foundation
import NIOCore
import NIOPosix
import NIOSSL

/// 연결 과정에서 서버가 정해진 시간 안에 응답하지 않음
public struct RedisTimeoutError: LocalizedError, Sendable {
    public let seconds: Int
    public var errorDescription: String? {
        tr("Redis 서버가 %@초 안에 응답하지 않았어요. 주소 · 포트 · TLS 설정과 네트워크(SSH 터널)를 확인하세요.", "\(seconds)")
    }
}

/// Redis 연결 하나. 명령은 보낸 순서대로 응답이 온다 (파이프라인).
/// 구독(SUBSCRIBE) 연결로 쓰면 모든 응답을 push 스트림으로 넘긴다.
public final class RedisConnection: @unchecked Sendable {
    let channel: Channel
    private let handler: RedisHandler

    private init(channel: Channel, handler: RedisHandler) {
        self.channel = channel
        self.handler = handler
    }

    public var isOpen: Bool { channel.isActive }

    struct Options: Sendable {
        var host: String
        var port: Int
        var serverName: String?
        var useTLS: Bool
        var username: String
        var password: String?
        var database: Int
        var clientName = "GodDB"
        /// 연결 과정 명령(AUTH · SELECT 등)의 응답 제한
        var timeout: TimeAmount = .seconds(10)
    }

    static func connect(_ o: Options) async throws -> RedisConnection {
        let conn = try await HostResolver.tryEach(o.host, port: o.port) { ip in
            let handler = RedisHandler()
            let tls: NIOSSLContext? = o.useTLS ? try NIOSSLContext(configuration: HostResolver.insecureTLS()) : nil
            let channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                .connectTimeout(.seconds(10))
                .channelOption(ChannelOptions.socketOption(.so_keepalive), value: 1)
                .channelInitializer { ch in
                    do {
                        if let tls {
                            try ch.pipeline.syncOperations.addHandler(NIOSSLClientHandler(context: tls, serverHostname: o.serverName))
                        }
                        try ch.pipeline.syncOperations.addHandler(handler)
                        return ch.eventLoop.makeSucceededVoidFuture()
                    } catch {
                        return ch.eventLoop.makeFailedFuture(error)
                    }
                }
                .connect(to: try SocketAddress(ipAddress: ip, port: o.port)).get()
            return RedisConnection(channel: channel, handler: handler)
        }
        do {
            if let pw = o.password, !pw.isEmpty {
                if o.username.isEmpty {
                    _ = try await conn.send(["AUTH", pw], timeout: o.timeout)
                } else {
                    _ = try await conn.send(["AUTH", o.username, pw], timeout: o.timeout)
                }
            }
            if o.database != 0 { _ = try await conn.send(["SELECT", String(o.database)], timeout: o.timeout) }
            do {
                _ = try await conn.send(["CLIENT", "SETNAME", o.clientName], timeout: o.timeout)
            } catch let e as RedisServerError {
                _ = e  // 이름 붙이기를 막은 서버(권한 등)는 무시. 시간 초과 · 연결 끊김은 실패로 본다
            }
        } catch {
            await conn.close()
            throw error
        }
        return conn
    }

    /// 명령 하나를 보내고 응답을 받는다. 서버 오류(-ERR …)는 RedisServerError 로 던진다.
    /// - timeout: 이 시간 안에 응답이 없으면 연결을 닫고 RedisTimeoutError (nil 이면 제한 없음 — BLPOP 같은 콘솔 명령)
    @discardableResult
    public func send(_ args: [String], timeout: TimeAmount? = nil) async throws -> RESPValue {
        try await sendBytes(args.map { Array($0.utf8) }, timeout: timeout)
    }

    @discardableResult
    public func sendBytes(_ args: [[UInt8]], timeout: TimeAmount? = nil) async throws -> RESPValue {
        let v = try await raw(args, timeout: timeout)
        if case .error(let m) = v { throw RedisServerError(message: m) }
        return v
    }

    /// 오류 응답도 값으로 돌려준다 (콘솔용)
    public func raw(_ args: [[UInt8]], timeout: TimeAmount? = nil) async throws -> RESPValue {
        guard channel.isActive else { throw DBError.notConnected }
        let promise = channel.eventLoop.makePromise(of: RESPValue.self)
        if let timeout {
            // 응답이 없으면 연결에 오류를 흘려 대기 중인 요청을 모두 실패시키고 연결을 닫는다
            let seconds = Int(timeout.nanoseconds / 1_000_000_000)
            let handler = self.handler
            let task = channel.eventLoop.scheduleTask(in: timeout) {
                handler.abort(RedisTimeoutError(seconds: seconds))
            }
            promise.futureResult.whenComplete { _ in task.cancel() }
        }
        channel.writeAndFlush(RedisHandler.Request(args: args, promise: promise), promise: nil)
        return try await promise.futureResult.get()
    }

    /// 구독 모드로 바꾼다. 이후 오는 모든 값은 스트림으로 간다.
    func pushStream() -> AsyncStream<RESPValue> {
        AsyncStream { cont in
            handler.setPush(on: channel.eventLoop) { cont.yield($0) }
            channel.closeFuture.whenComplete { _ in cont.finish() }
        }
    }

    /// 응답을 기다리지 않고 보낸다 (구독 모드)
    func fire(_ args: [String]) {
        channel.writeAndFlush(RedisHandler.Request(args: args.map { Array($0.utf8) }, promise: nil), promise: nil)
    }

    public func close() async {
        try? await channel.close().get()
    }

    deinit {
        if channel.isActive { channel.close(promise: nil) }
    }
}

final class RedisHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundIn = Request
    typealias OutboundOut = ByteBuffer

    struct Request {
        let args: [[UInt8]]
        let promise: EventLoopPromise<RESPValue>?
    }

    private var buffer: ByteBuffer?
    private var context: ChannelHandlerContext?
    private var waiting: CircularBuffer<EventLoopPromise<RESPValue>> = []
    private var push: ((RESPValue) -> Void)?

    func handlerAdded(context: ChannelHandlerContext) { self.context = context }
    func handlerRemoved(context: ChannelHandlerContext) { self.context = nil }

    /// 이벤트 루프에서 부른다: 기다리는 요청을 모두 실패시키고 연결을 닫는다 (응답 시간 초과)
    func abort(_ error: Error) {
        failAll(error)
        context?.close(promise: nil)
    }

    func setPush(on loop: EventLoop, _ f: @escaping (RESPValue) -> Void) {
        loop.execute { self.push = f }
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let req = unwrapOutboundIn(data)
        var out = context.channel.allocator.buffer(capacity: 64)
        RESPCoder.encode(req.args, into: &out)
        if let p = req.promise { waiting.append(p) }
        context.write(wrapOutboundOut(out), promise: promise)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var incoming = unwrapInboundIn(data)
        if buffer == nil { buffer = incoming } else { buffer!.writeBuffer(&incoming) }
        do {
            while var b = buffer, let v = try RESPCoder.decode(&b) {
                buffer = b
                if let push, waiting.isEmpty {
                    push(v)
                } else if !waiting.isEmpty {
                    waiting.removeFirst().succeed(v)
                } else if let push {
                    push(v)
                }
            }
            if buffer?.readableBytes == 0 { buffer = nil } else { buffer?.discardReadBytes() }
        } catch {
            failAll(error)
            context.close(promise: nil)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        failAll(DBError.notConnected)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        failAll(error)
        context.close(promise: nil)
    }

    private func failAll(_ error: Error) {
        while let p = waiting.popFirst() { p.fail(error) }
    }
}
