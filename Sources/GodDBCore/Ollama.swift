import Foundation

/// 로컬 Ollama 상태
public enum OllamaStatus: Equatable, Sendable {
    /// 실행 중, 설치된 모델 목록
    case running(models: [OllamaModel])
    /// 설치는 됐지만 서버가 꺼져 있음
    case installedNotRunning
    /// 설치 안 됨
    case notInstalled

    public var isRunning: Bool { if case .running = self { return true } else { return false } }
}

public struct OllamaModel: Equatable, Hashable, Sendable, Identifiable {
    public var id: String { name }
    public let name: String
    public let sizeGB: Double
    public let parameterSize: String
}

public enum OllamaError: LocalizedError {
    case notRunning
    case noModel
    case http(Int, String)
    /// 이 PC 밖의 주소 — 구조 · SQL · 샘플 값이 다른 서버로 가므로 요청하지 않는다
    case remoteBlocked(String)

    public var errorDescription: String? {
        switch self {
        case .notRunning: return tr("Ollama 가 실행 중이 아니에요. 설정 > AI 에서 확인해 주세요.")
        case .noModel: return tr("AI 에 쓸 모델을 설정 > AI 에서 골라 주세요.")
        case .http(let code, let body): return tr("Ollama 오류 (HTTP %@): %@", "\(code)", body)
        case .remoteBlocked(let host): return tr("AI 는 이 PC 의 Ollama 만 쓸 수 있어요 (%@ 는 다른 서버예요). 설정 > AI 에서 주소를 localhost 로 바꿔 주세요.", host)
        }
    }
}

/// 로컬 Ollama HTTP API (기본 http://localhost:11434). 데이터는 이 Mac 밖으로 나가지 않는다.
public struct OllamaClient: Sendable {
    public var baseURL: URL

    public init(baseURL: URL = URL(string: "http://localhost:11434")!) {
        self.baseURL = baseURL
    }

    /// Ollama 실행 파일 위치 (Homebrew / 공식 앱)
    public static let binaryPaths = ["/opt/homebrew/bin/ollama", "/usr/local/bin/ollama",
                                     "/Applications/Ollama.app/Contents/Resources/ollama"]

    public static var isInstalled: Bool {
        binaryPaths.contains { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public func status() async -> OllamaStatus {
        if let models = try? await models() { return .running(models: models) }
        return Self.isInstalled ? .installedNotRunning : .notInstalled
    }

    /// 이 PC 밖이면 요청 전에 막는다 (설정을 거치지 않고 주소가 들어와도)
    func ensureLocal() throws {
        guard AISettings.isLocalURL(baseURL.absoluteString) else { throw OllamaError.remoteBlocked(baseURL.host ?? baseURL.absoluteString) }
    }

    public func models() async throws -> [OllamaModel] {
        try ensureLocal()
        var request = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        request.timeoutInterval = 3
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.check(response, data)
        struct Tags: Decodable {
            struct Model: Decodable {
                struct Details: Decodable { let parameter_size: String? }
                let name: String
                let size: Int64?
                let details: Details?
            }
            let models: [Model]
        }
        return try JSONDecoder().decode(Tags.self, from: data).models.map {
            OllamaModel(name: $0.name, sizeGB: Double($0.size ?? 0) / 1_000_000_000,
                        parameterSize: $0.details?.parameter_size ?? "")
        }
    }

    /// `ollama serve` 를 백그라운드로 띄운다. (공식 앱이 있으면 앱을 연다)
    public static func start() throws {
        if FileManager.default.fileExists(atPath: "/Applications/Ollama.app") {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = ["-g", "-a", "Ollama"]
            try p.run()
            return
        }
        guard let path = binaryPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw OllamaError.notRunning
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["serve"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
    }

    /// 대화 응답을 조각 단위로 받는다. 생각(thinking) 조각과 본문(content) 조각을 구분한다.
    public enum ChatChunk: Sendable {
        case thinking(String)
        case content(String)
    }

    public struct Message: Encodable, Sendable {
        public let role: String
        public let content: String
        public init(role: String, content: String) { self.role = role; self.content = content }
    }

    /// 스트리밍 대화. `think` 옵션은 보내지 않는다 (일부 모델은 false 를 주면 생각이 본문에 섞인다).
    public func chat(model: String, messages: [Message], temperature: Double = 0.2) -> AsyncThrowingStream<ChatChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try ensureLocal()
                    var request = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
                    request.httpMethod = "POST"
                    request.timeoutInterval = 600
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    struct Body: Encodable {
                        let model: String
                        let messages: [Message]
                        let stream: Bool
                        let options: [String: Double]
                    }
                    request.httpBody = try JSONEncoder().encode(
                        Body(model: model, messages: messages, stream: true, options: ["temperature": temperature]))
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                        var body = ""
                        for try await line in bytes.lines { body += line }
                        throw OllamaError.http(http.statusCode, body)
                    }
                    struct Line: Decodable {
                        struct Msg: Decodable { let content: String?; let thinking: String? }
                        let message: Msg?
                        let done: Bool?
                        let error: String?
                    }
                    for try await line in bytes.lines {
                        guard let data = line.data(using: .utf8),
                              let decoded = try? JSONDecoder().decode(Line.self, from: data) else { continue }
                        if let error = decoded.error { throw OllamaError.http(500, error) }
                        if let t = decoded.message?.thinking, !t.isEmpty { continuation.yield(.thinking(t)) }
                        if let c = decoded.message?.content, !c.isEmpty { continuation.yield(.content(c)) }
                        if decoded.done == true { break }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// 모델 확인용 짧은 요청: "Reply with OK" (스트리밍 없이, 최대 256 토큰). 실패하거나 답이 비면 OllamaError 를 던진다.
    /// 토큰을 너무 적게 받으면 고장 난 모델도 오류 전에 끝나 통과하므로(빈 답) 조금 넉넉히 받고, 빈 답은 실패로 본다.
    public func ping(model: String, timeout: Double) async throws {
        try ensureLocal()
        var request = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": ModelProbe.prompt]],
            "stream": false,
            "options": ["num_predict": ModelProbe.maxTokens, "temperature": 0],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.check(response, data)
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let error = obj?["error"] as? String { throw OllamaError.http(500, error) }
        let message = obj?["message"] as? [String: Any]
        let text = ((message?["content"] as? String) ?? "") + ((message?["thinking"] as? String) ?? "")
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw OllamaError.http(200, tr("빈 답을 돌려줬어요"))
        }
    }

    static func check(_ response: URLResponse, _ data: Data) throws {
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw OllamaError.http(http.statusCode, String(decoding: data, as: UTF8.self))
        }
    }
}

/// 로컬 AI(Ollama) 설정 (UserDefaults). 저장 키는 예전 쿼리 튜닝 시절 이름을 그대로 써서 기존 설정이 유지된다.
public enum AISettings {
    private static let d = UserDefaults.standard

    public static var url: String {
        get { d.string(forKey: "GodDB.tuning.url") ?? "http://localhost:11434" }
        set { d.set(newValue, forKey: "GodDB.tuning.url") }
    }

    /// 비어 있으면 `defaultModel(installed:)` 로 고른다
    public static var model: String {
        get { d.string(forKey: "GodDB.tuning.model") ?? "" }
        set { d.set(newValue, forKey: "GodDB.tuning.model") }
    }

    public static var client: OllamaClient {
        OllamaClient(baseURL: URL(string: url) ?? URL(string: "http://localhost:11434")!)
    }

    public static let defaultURL = "http://localhost:11434"

    /// 지금 저장된 주소가 이 PC 인지
    public static var isLocal: Bool { isLocalURL(url) }

    /// 이 PC(루프백) 주소인지: localhost, 127.0.0.0/8, ::1. 스킴은 http(s) 만.
    public static func isLocalURL(_ text: String) -> Bool {
        guard let u = URL(string: text.trimmingCharacters(in: .whitespaces)),
              let scheme = u.scheme?.lowercased(), ["http", "https"].contains(scheme),
              var host = u.host?.lowercased() else { return false }
        if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host == "localhost" || host == "::1" || host == "0:0:0:0:0:0:0:1" { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts[0] == "127" && parts.allSatisfy { p in Int(p).map { (0...255).contains($0) } ?? false }
    }

    /// 추천 모델 (앞이 먼저, "자동" 이면 설치된 것 중 앞의 것).
    /// 메모리 48GB 이상(M5 Pro 등) qwen3.8:27b-mlx, 24GB qwen3:14b. 예전 추천(qwen3:30b · qwen2.5-coder)은 뒤에 남긴다.
    public static let recommendedModels = ["qwen3.8:27b-mlx", "qwen3:14b", "qwen3:30b", "qwen2.5-coder:14b", "qwen2.5-coder:32b"]

    /// 기본 추천 모델 (받기 안내에 쓴다)
    public static var defaultRecommendedModel: String { recommendedModels[0] }

    /// 메모리 24GB 에 맞는 추천 모델
    public static let smallMemoryModel = "qwen3:14b"

    /// 모델을 고르지 않았을 때 쓸 모델: 설치된 추천 모델(앞 순서) → 설치된 첫 모델
    public static func defaultModel(installed: [String]) -> String? {
        recommendedModels.first(where: installed.contains) ?? installed.first
    }

    /// 쓸 모델: 고른 모델, 없으면 기본 모델
    public static func effectiveModel(installed: [String]) -> String? {
        model.isEmpty ? defaultModel(installed: installed) : model
    }

    /// 추천 모델을 앞으로 (바꿀 모델 버튼 순서)
    public static func recommendedFirst(_ names: [String]) -> [String] {
        let rec = recommendedModels.filter(names.contains)
        return rec + names.filter { !rec.contains($0) }
    }
}

// MARK: - 모델 확인 (F7)

/// 모델 확인 결과
public enum ModelHealth: Equatable, Sendable {
    case ok
    /// 짧은 이유 (예: "prediction aborted, token repeat limit reached")
    case failed(String)
    /// 제한 시간 안에 답이 없음 (모델을 처음 올리는 중일 수 있어 기억하지 않는다)
    case timedOut

    public var isOK: Bool { self == .ok }

    /// 화면에 보일 짧은 이유
    public var reason: String {
        switch self {
        case .ok: return "OK"
        case .failed(let r): return r
        case .timedOut: return tr("%@초 안에 답이 없어요", "\(Int(ModelProbe.timeout))")
        }
    }
}

/// 고른 모델이 실제로 답하는지 아주 짧은 요청으로 확인한다. 결과는 앱을 켜 둔 동안 모델별로 기억한다.
/// (어떤 모델은 "hi" 에도 HTTP 500 "token repeat limit reached" 로 실패한다 — 그런 모델로 찾기를 하면 틀린 답만 나온다)
public enum ModelProbe {
    public static let prompt = "Reply with OK"
    public static let maxTokens = 256
    public static let timeout: Double = 20

    /// 확인 하나. `send` 는 실제로는 `OllamaClient.ping` (시험에서는 가짜).
    public static func check(timeout: Double = timeout, send: @escaping @Sendable () async throws -> Void) async -> ModelHealth {
        do {
            try await ConnectDeadline.run(seconds: timeout) { try await send() }
            return .ok
        } catch is DBConnectTimeoutError {
            return .timedOut
        } catch let e as URLError where e.code == .timedOut {
            return .timedOut
        } catch is CancellationError {
            return .failed(tr("취소했어요"))
        } catch {
            return .failed(shortReason(error))
        }
    }

    /// Ollama 오류에서 짧은 이유만: `{"error":"…"}` 이면 그 글, 아니면 오류 설명 첫 줄 (120자까지)
    public static func shortReason(_ error: any Error) -> String {
        var text: String
        if case OllamaError.http(let code, let body) = error {
            if let data = body.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let msg = obj["error"] as? String {
                text = msg
            } else {
                text = body.isEmpty ? "HTTP \(code)" : body
            }
        } else {
            text = error.localizedDescription
        }
        text = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        text = text.trimmingCharacters(in: .whitespaces)
        return text.count > 120 ? String(text.prefix(120)) + "…" : text
    }

    /// 로컬 Ollama 로 확인 (기억한 결과가 있으면 그것). 시간 초과는 기억하지 않는다.
    public static func check(model: String, client: OllamaClient, cache: ModelHealthCache = .shared,
                             useCache: Bool = true) async -> ModelHealth {
        let key = client.baseURL.absoluteString + "|" + model
        if useCache, let known = await cache.get(key) { return known }
        let health = await check { try await client.ping(model: model, timeout: timeout + 5) }
        if health != .timedOut { await cache.set(key, health) }
        return health
    }
}

/// 모델 확인 결과 기억 (앱을 켜 둔 동안)
public actor ModelHealthCache {
    public static let shared = ModelHealthCache()
    private var items: [String: ModelHealth] = [:]

    public init() {}

    public func get(_ key: String) -> ModelHealth? { items[key] }
    public func set(_ key: String, _ value: ModelHealth) { items[key] = value }
}
