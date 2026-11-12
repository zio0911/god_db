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

    public var errorDescription: String? {
        switch self {
        case .notRunning: return tr("Ollama 가 실행 중이 아니에요. 설정 > 쿼리 튜닝에서 확인해 주세요.")
        case .noModel: return tr("튜닝에 쓸 모델을 설정 > 쿼리 튜닝에서 골라 주세요.")
        case .http(let code, let body): return tr("Ollama 오류 (HTTP %@): %@", "\(code)", body)
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

    public func models() async throws -> [OllamaModel] {
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

    static func check(_ response: URLResponse, _ data: Data) throws {
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw OllamaError.http(http.statusCode, String(decoding: data, as: UTF8.self))
        }
    }
}

/// 쿼리 튜닝 설정 (UserDefaults)
public enum TuningSettings {
    private static let d = UserDefaults.standard

    public static var enabled: Bool {
        get { d.object(forKey: "GodDB.tuning.enabled") as? Bool ?? true }
        set { d.set(newValue, forKey: "GodDB.tuning.enabled") }
    }

    public static var url: String {
        get { d.string(forKey: "GodDB.tuning.url") ?? "http://localhost:11434" }
        set { d.set(newValue, forKey: "GodDB.tuning.url") }
    }

    /// 비어 있으면 설치된 첫 모델을 쓴다
    public static var model: String {
        get { d.string(forKey: "GodDB.tuning.model") ?? "" }
        set { d.set(newValue, forKey: "GodDB.tuning.model") }
    }

    public static var client: OllamaClient {
        OllamaClient(baseURL: URL(string: url) ?? URL(string: "http://localhost:11434")!)
    }

    /// 이 Mac 안의 주소인지 (아니면 스키마 정보가 다른 서버로 간다)
    public static var isLocal: Bool {
        guard let host = URL(string: url)?.host?.lowercased() else { return false }
        return ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
    }

    /// 코드·SQL 에 강한 추천 모델
    public static let recommendedModels = ["qwen2.5-coder:14b", "qwen2.5-coder:32b", "qwen3:30b"]
}
