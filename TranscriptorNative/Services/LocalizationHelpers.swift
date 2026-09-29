import Foundation

// MARK: - Centralized Domain Helpers
// Unified language & model display helpers to avoid duplication across views.

enum LocalizationHelpers {
    /// Short uppercase language tag (e.g. "ES", "EN", "Auto")
    static func languageTag(_ code: String) -> String {
        let tags: [String: String] = [
            "es": "ES", "en": "EN", "fr": "FR", "de": "DE",
            "it": "IT", "pt": "PT", "ja": "JA", "zh": "ZH", "auto": "Auto"
        ]
        return tags[code] ?? code.uppercased()
    }

    /// Full display name for a language code (e.g. "Español", "English")
    static func languageDisplayName(_ code: String) -> String {
        let names: [String: String] = [
            "es": "Español", "en": "English", "fr": "Français",
            "de": "Deutsch", "it": "Italiano", "pt": "Português",
            "ja": "日本語", "zh": "中文", "auto": "Auto"
        ]
        return names[code] ?? code.uppercased()
    }

    /// Compact model label for UI badges
    static func modelShortName(_ id: String) -> String {
        switch id {
        case "tiny": return "Tiny"
        case "base": return "Base"
        case "small": return "Small"
        case "medium": return "Med"
        case "large-v3-turbo": return "Turbo"
        default: return id.capitalized
        }
    }
}
