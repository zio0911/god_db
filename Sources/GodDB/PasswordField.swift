import GodDBCore
import LocalAuthentication
import SwiftUI

/// 비밀번호 칸 + 보기(눈) 버튼.
/// `needsAuthentication` 이 참이면 보이기 전에 macOS 본인 확인(Touch ID 또는 Mac 로그인 암호)을 거친다.
/// 키체인이 "항상 허용"이어도 매번 확인한다 (키체인과 별개로 앱이 직접 요청).
struct PasswordField: View {
    let title: String
    @Binding var text: String
    var prompt: Text?
    var needsAuthentication = false
    var authenticationReason = ""
    /// 본인 확인을 거쳐 보였을 때
    var onAuthenticatedReveal: () -> Void = {}
    var onSubmit: () -> Void = {}

    @State private var visible = false
    @State private var authenticating = false

    var body: some View {
        HStack(spacing: 4) {
            Group {
                if visible {
                    TextField(title, text: $text, prompt: prompt)
                } else {
                    SecureField(title, text: $text, prompt: prompt)
                }
            }
            .onSubmit(onSubmit)
            Button(action: toggle) {
                Image(systemName: visible ? "eye.slash" : "eye")
                    .frame(width: 18)
            }
            .buttonStyle(.borderless)
            .disabled(authenticating)
            .help(visible ? tr("비밀번호 가리기") : tr("비밀번호 보기"))
            .accessibilityLabel(visible ? tr("비밀번호 가리기") : tr("비밀번호 보기"))
        }
    }

    private func toggle() {
        if visible { visible = false; return }
        guard needsAuthentication else { visible = true; return }
        authenticating = true
        Task {
            let ok = await DeviceOwner.confirm(reason: authenticationReason)
            authenticating = false
            if ok {
                visible = true
                onAuthenticatedReveal()
            }
        }
    }
}

/// macOS 본인 확인 (Touch ID / Apple Watch / Mac 로그인 암호)
enum DeviceOwner {
    static func confirm(reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return false }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }
}
