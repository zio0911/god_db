import Foundation

/// 화면 언어
public enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case ko
    case en

    public var id: String { rawValue }

    /// 설정 화면에 보이는 이름 (각 언어 자기 이름으로)
    public var displayName: String {
        switch self {
        case .system: return tr("시스템 언어 따르기")
        case .ko: return "한국어"
        case .en: return "English"
        }
    }
}

/// 다국어 처리. 소스의 한국어 문장이 키이고, 영어는 `L10nEnglish` 표에서 찾는다.
/// 표에 없는 문장은 한국어 그대로 보인다.
public enum L10n {
    private static let defaultsKey = "GodDB.language"

    /// 설정에서 고른 언어
    public static var language: AppLanguage {
        get { AppLanguage(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .system }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }

    /// 실제로 쓰는 언어. 환경변수 GODDB_LANG(ko/en)이 있으면 그것을 우선한다 (테스트용).
    public static var resolved: AppLanguage {
        if let env = ProcessInfo.processInfo.environment["GODDB_LANG"], let lang = AppLanguage(rawValue: env), lang != .system {
            return lang
        }
        switch language {
        case .ko, .en: return language
        case .system:
            let preferred = Locale.preferredLanguages.first ?? "en"
            return preferred.hasPrefix("ko") ? .ko : .en
        }
    }

    public static var isEnglish: Bool { resolved == .en }

    static func lookup(_ key: String) -> String {
        guard isEnglish else { return key }
        return L10nEnglish.table[key] ?? key
    }
}

/// 한국어 문장을 현재 언어로 바꾼다.
public func tr(_ key: String) -> String {
    L10n.lookup(key)
}

/// `%@` 자리에 값을 넣는다. 예: tr("%@행", "\(count)")
public func tr(_ key: String, _ args: CVarArg...) -> String {
    String(format: L10n.lookup(key), arguments: args)
}
