import Foundation

@MainActor
final class LocalizationManager: ObservableObject {
    private let uiLanguageKey = "app_ui_language"
    private let defaults: UserDefaults

    @Published private(set) var appLanguage: AppLanguage

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.string(forKey: uiLanguageKey)

        // Migration from legacy values ("system", unsupported codes) to explicit app language.
        switch stored {
        case AppLanguage.en.rawValue:
            self.appLanguage = .en
        case AppLanguage.es.rawValue:
            self.appLanguage = .es
        case "system":
            let preferred = Locale.preferredLanguages.first?.lowercased() ?? ""
            self.appLanguage = preferred.hasPrefix("es") ? .es : .en
            defaults.set(self.appLanguage.rawValue, forKey: uiLanguageKey)
        default:
            self.appLanguage = .en
            defaults.set(self.appLanguage.rawValue, forKey: uiLanguageKey)
        }
    }

    var locale: Locale {
        Locale(identifier: appLanguage.localeIdentifier)
    }

    func setLanguage(_ language: AppLanguage) {
        guard language != appLanguage else { return }
        appLanguage = language
        defaults.set(language.rawValue, forKey: uiLanguageKey)
    }

    func text(_ key: String, fallback: String) -> String {
        // Resolve explicitly from the selected language bundle to avoid
        // stale lookups when switching language at runtime.
        if let path = Bundle.main.path(forResource: appLanguage.localeIdentifier, ofType: "lproj"),
           let langBundle = Bundle(path: path) {
            let value = langBundle.localizedString(forKey: key, value: nil, table: nil)
            if value != key {
                return value
            }
        }

        // Fallback to main bundle (covers Base localization entries).
        let mainValue = Bundle.main.localizedString(forKey: key, value: nil, table: nil)
        if mainValue != key {
            return mainValue
        }

        return fallback
    }
}
