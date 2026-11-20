import Foundation
import Testing
@testable import GodDBCore

@Suite("AI settings")
struct AISettingsTests {
    @Test func onlyLoopbackOllamaIsAllowed() {
        for ok in ["http://localhost:11434", "http://127.0.0.1:11434", "https://127.5.6.7", "http://[::1]:11434", "http://LOCALHOST:11434/"] {
            #expect(AISettings.isLocalURL(ok), "\(ok)")
        }
        for bad in ["http://10.0.0.5:11434", "http://gpu.example.com:11434", "http://localhost.evil.com", "http://127.0.0.1.nip.io",
                    "ftp://localhost", "localhost:11434", "http://128.0.0.1", "http://127.0.0.256", ""] {
            #expect(!AISettings.isLocalURL(bad), "\(bad)")
        }
    }

    @Test func clientRefusesRemoteBeforeSending() async {
        let c = OllamaClient(baseURL: URL(string: "http://10.1.2.3:11434")!)
        await #expect(throws: OllamaError.self) { _ = try await c.models() }
    }
}
