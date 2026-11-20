import Foundation

/// DB 서버가 정해진 시간 안에 연결을 끝내지 않음
/// (연결은 받지만 응답이 없는 서버, SSH 터널 너머가 안 붙는 경우 등)
public struct DBConnectTimeoutError: LocalizedError, Sendable {
    public let seconds: Int
    public var errorDescription: String? {
        tr("DB 서버가 %@초 안에 연결되지 않았어요. 주소 · 포트와 네트워크(VPN · SSH 터널)를 확인하세요.", "\(seconds)")
    }
}

/// 취소를 모르는 작업(NIO 연결, FreeTDS 로그인)에 시간 제한을 건다.
/// 시간이 지나거나 호출한 쪽이 취소되면 작업을 기다리지 않고 바로 끝낸다.
/// 작업은 뒤에서 계속 돌 수 있으므로, 늦게 끝나면 `late` 로 결과를 넘겨 정리(연결 닫기)하게 한다.
public enum ConnectDeadline {
    public static func run<T: Sendable>(
        seconds: Double,
        late: @escaping @Sendable (T) async -> Void = { _ in },
        _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let race = Race<T>()
        let worker = Task {
            do {
                let value = try await work()
                if !race.finish(.success(value)) { await late(value) }
            } catch {
                race.finish(.failure(error))
            }
        }
        let timer = Task {
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            if race.finish(.failure(DBConnectTimeoutError(seconds: Int(seconds.rounded())))) { worker.cancel() }
        }
        defer { timer.cancel() }
        return try await withTaskCancellationHandler {
            try await race.wait()
        } onCancel: {
            if race.finish(.failure(CancellationError())) { worker.cancel() }
        }
    }

    /// 결과 · 시간 초과 · 취소 중 먼저 온 것 하나만 이긴다.
    private final class Race<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<T, Error>?
        private var waiter: CheckedContinuation<T, Error>?

        /// 처음 들어온 결과면 true
        @discardableResult
        func finish(_ r: Result<T, Error>) -> Bool {
            lock.lock()
            guard result == nil else { lock.unlock(); return false }
            result = r
            let w = waiter
            waiter = nil
            lock.unlock()
            w?.resume(with: r)
            return true
        }

        func wait() async throws -> T {
            try await withCheckedThrowingContinuation { cont in
                lock.lock()
                if let r = result {
                    lock.unlock()
                    cont.resume(with: r)
                } else {
                    waiter = cont
                    lock.unlock()
                }
            }
        }
    }
}
