import Foundation

/// UI language selector for app-level localization.
enum AppLanguage: String, CaseIterable, Identifiable, Codable {
    case en
    case es

    var id: String { rawValue }

    /// Interface languages currently shipped in Localizable.xcstrings.
    static var supportedInterfaceLanguages: [AppLanguage] {
        [.en, .es]
    }

    /// Locale identifier used for SwiftUI environment locale.
    var localeIdentifier: String {
        switch self {
        case .en: return "en"
        case .es: return "es"
        }
    }

    var displayName: String {
        switch self {
        case .en: return "English"
        case .es: return "Español"
        }
    }
}
