import Foundation
import Testing
@testable import GodDBCore

@Suite("Problem report")
struct ProblemReportTests {
    @Test func redactsCompanyInfo() {
        let text = """
        연결 실패: shop-prd.cluster-abc123.ap-northeast-2.rds.amazonaws.com:3306 (SSH 10.20.30.40 경유)
        kim@MacBook-Pro 이 kim.dev@corp.example.com 로 접속 · 파일 /Users/kim/Library/Logs/x.log
        """
        let r = ProblemReport.redact(text, identity: "kim@MacBook-Pro", home: "/Users/kim")
        #expect(!r.contains("amazonaws") && r.contains("<host>:3306"))
        #expect(!r.contains("10.20.30.40") && r.contains("<ip>"))
        #expect(!r.contains("corp.example.com") && r.contains("<email>"))
        #expect(r.contains("<user> 이") && r.contains("~/Library/Logs/x.log"))
    }

    @Test func parsesCrashReport() {
        let head = #"{"app_name":"GodDB","timestamp":"2026-11-13 14:59:45.00 +0900","app_version":"0.9.0"}"#
        let body = """
        {"exception":{"type":"EXC_BREAKPOINT","signal":"SIGTRAP"},"faultingThread":0,
         "usedImages":[{"name":"libswiftCore.dylib"},{"name":"SwiftUI"}],
         "threads":[{"frames":[{"imageIndex":0,"symbol":"_assertionFailure"},{"imageIndex":1,"symbol":"ViewListTree.visitItem"}]}]}
        """
        let c = ProblemReport.parseCrash(head + "\n" + body)
        #expect(c?.appVersion == "0.9.0")
        #expect(c?.exception == "EXC_BREAKPOINT SIGTRAP")
        #expect(c?.frames == ["libswiftCore.dylib  _assertionFailure", "SwiftUI  ViewListTree.visitItem"])
        #expect(ProblemReport.parseCrash("not json") == nil)
    }

    @Test func issueURLIsPrefilledAndBounded() throws {
        let long = String(repeating: "오류 로그 줄\n", count: 3000)
        let url = try #require(ProblemReport.issueURL(title: "앱이 종료돼요", version: "1.0.0", db: "Redis",
                                                      steps: "1. 키 트리 열기", expected: "종료되지 않음", log: long))
        #expect(url.absoluteString.count <= 7_500)
        let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(q.first { $0.name == "template" }?.value == "bug.yml")
        #expect(q.first { $0.name == "version" }?.value == "1.0.0")
        #expect(q.first { $0.name == "log" }?.value?.hasSuffix("…(잘림)") == true)
    }
}
