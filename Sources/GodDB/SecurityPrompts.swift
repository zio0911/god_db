import GodDBCore
import SwiftUI

// F9-3 TLS 서버 인증서 확인 — 확인 창

/// 연결 중 만난 인증서 · 호스트 키 문제
enum SecurityPrompt: Equatable {
    /// 체인 · 이름 확인 실패 → [이 인증서 신뢰 (고정)]
    case tlsUntrusted(TLSCertInfo, [TLSFailureReason])
    /// 고정한 인증서와 다름 → [저장된 인증서 지우기]
    case tlsPinMismatch(TLSCertInfo)

    /// 연결 오류에서 확인 창을 고른다 (해당 없으면 nil)
    static func from(_ error: any Error) -> SecurityPrompt? {
        if let e = error as? TLSCertificateError {
            switch e {
            case .untrusted(let info, let reasons): return .tlsUntrusted(info, reasons)
            case .pinMismatch(let info, _): return .tlsPinMismatch(info)
            case .serverNoTLS: return nil
            }
        }
        return nil
    }

    var acceptTitle: String {
        switch self {
        case .tlsUntrusted: return tr("이 인증서 신뢰 (고정)")
        case .tlsPinMismatch: return tr("저장된 인증서 지우기")
        }
    }

    /// 지우는 동작이면 위험 표시
    var isRemoval: Bool {
        switch self {
        case .tlsPinMismatch: return true
        default: return false
        }
    }
}

/// 접속 하나에 대한 확인 요청 (메인 창)
struct SecurityPromptRequest: Identifiable {
    let id = UUID()
    let profileID: UUID
    let profileName: String
    let prompt: SecurityPrompt
}

/// 고정 지문을 바꾼 결과
enum PinChange: Equatable {
    case none
    case set(String)
    case clear
}

extension AppState {
    /// 연결 실패가 인증서 · 호스트 키 문제면 확인 창을 띄운다
    @discardableResult
    func presentSecurityPrompt(for error: any Error, profile: ConnectionProfile) -> Bool {
        guard let prompt = SecurityPrompt.from(error) else { return false }
        securityPrompt = SecurityPromptRequest(profileID: profile.id, profileName: profile.name, prompt: prompt)
        return true
    }

    /// 확인 창에서 [신뢰] · [지우기] 를 눌렀을 때.
    /// TLS 고정 지문은 저장하지 않고 바꿀 값을 돌려준다 (메인 창은 접속 목록에, 접속 편집은 편집 중인 값에 넣는다).
    func applySecurityAccept(_ prompt: SecurityPrompt, profileName: String) -> PinChange {
        switch prompt {
        case .tlsUntrusted(let info, _):
            return .set(info.sha256)
        case .tlsPinMismatch:
            return .clear
        }
    }

    /// TLS 고정 지문이 바뀌었으면 감사 로그에 남긴다 (접속 정보 저장 · 확인 창 공용)
    func auditPinChange(profileName: String, old: String?, new: String?) {
        guard (old ?? "") != (new ?? "") else { return }
        if let new, !new.isEmpty {
            log(.info, .app, tr("%@ TLS 인증서 신뢰 SHA256:%@", profileName, new),
                audit: AuditRecord(.settings, target: profileName, result: "TLS 인증서 신뢰 SHA256:\(new)"))
        } else {
            log(.info, .app, tr("%@ 인증서 고정 지움", profileName),
                audit: AuditRecord(.settings, target: profileName, result: "인증서 고정 지움"))
        }
    }

    /// 메인 창 확인 창의 결과
    func resolveSecurityPrompt(_ request: SecurityPromptRequest, accept: Bool) async {
        securityPrompt = nil
        guard accept else { return }
        let change = applySecurityAccept(request.prompt, profileName: request.profileName)
        if change != .none, let i = profiles.firstIndex(where: { $0.id == request.profileID }) {
            let old = profiles[i].tlsPinSHA256
            if case .set(let pin) = change { profiles[i].tlsPinSHA256 = pin } else { profiles[i].tlsPinSHA256 = nil }
            persist()
            auditPinChange(profileName: profiles[i].name, old: old, new: profiles[i].tlsPinSHA256)
        }
        // 다시 연결 (지운 경우에는 새 인증서 · 키를 확인 창으로 다시 보여 준다)
        await connect(request.profileID)
    }

    /// 연결 후 상태창 한 줄
    func logTLSStatus(_ name: String, _ status: TLSStatus) {
        log(.info, .connection, "\(name) · \(status.text)")
    }
}

/// 확인 창
struct SecurityPromptView: View {
    let prompt: SecurityPrompt
    let profileName: String
    let onCancel: () -> Void
    let onAccept: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon)
                .font(.headline)
                .foregroundStyle(prompt.isRemoval ? .red : .primary)
            content
            HStack {
                Spacer()
                Button(tr("취소"), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(prompt.acceptTitle, role: prompt.isRemoval ? .destructive : nil, action: onAccept)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private var title: String {
        switch prompt {
        case .tlsUntrusted: return tr("서버 인증서를 확인할 수 없어요 — %@", profileName)
        case .tlsPinMismatch: return tr("서버 인증서가 바뀌었어요 — %@", profileName)
        }
    }

    private var icon: String {
        switch prompt {
        case .tlsUntrusted: return "exclamationmark.shield"
        case .tlsPinMismatch: return "exclamationmark.octagon"
        }
    }

    @ViewBuilder private var content: some View {
        switch prompt {
        case .tlsUntrusted(let info, let reasons):
            certGrid(info)
            row(tr("이유"), reasons.map(\.text).joined(separator: " / "))
            Text(tr("처음 연결하는 서버라면, 관리자에게 받은 지문과 같은지 확인하세요."))
                .font(.callout).foregroundStyle(.secondary)
        case .tlsPinMismatch(let info):
            Text(tr("서버 인증서가 바뀌었어요. 서버를 교체한 게 아니라면 중간에서 가로채는 공격일 수 있어요. 관리자에게 확인한 뒤 [저장된 인증서 지우기] 를 누르세요."))
                .font(.callout)
            certGrid(info)
        }
    }

    private func certGrid(_ info: TLSCertInfo) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            row(tr("주체"), info.subject)
            row(tr("발급"), info.issuer)
            row(tr("유효"), info.validityText)
            row("SHA-256", info.sha256)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
            Text(value).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
    }
}
