import Foundation

/// Localised strings for the redesigned interface.
///
/// Keys live in `Localizable.xcstrings` with `es` and `en` values (checked by
/// `scripts/check_localization.py`). The second argument is the Spanish text of the
/// specification and is only used if the key is missing from the catalog.
enum TXL {
    private static var bundles: [String: Bundle] = [:]
    private static let lock = NSLock()

    static var languageCode: String {
        UserDefaults.standard.string(forKey: "app_ui_language") == "es" ? "es" : "en"
    }

    static var isSpanish: Bool { languageCode == "es" }

    static var locale: Locale { Locale(identifier: languageCode) }

    private static func bundle(for code: String) -> Bundle? {
        lock.lock(); defer { lock.unlock() }
        if let b = bundles[code] { return b }
        guard let path = Bundle.main.path(forResource: code, ofType: "lproj"), let b = Bundle(path: path) else { return nil }
        bundles[code] = b
        return b
    }

    /// Localised text for `key`.
    static func t(_ key: String, _ fallback: String) -> String {
        if let b = bundle(for: languageCode) {
            let value = b.localizedString(forKey: key, value: nil, table: nil)
            if value != key { return value }
        }
        return fallback
    }

    /// Localised format string filled with `args` (`%@`, `%d`, `%lld`).
    static func f(_ key: String, _ fallback: String, _ args: CVarArg...) -> String {
        String(format: t(key, fallback), locale: locale, arguments: args)
    }

    /// Singular/plural pair chosen by `count`; the format receives `count` first.
    static func n(_ key: String, _ one: String, _ other: String, _ count: Int, _ args: CVarArg...) -> String {
        let format = count == 1 ? t(key + ".one", one) : t(key + ".other", other)
        return String(format: format, locale: locale, arguments: [count] + args)
    }
}

// MARK: - Shared formatters (tabular, localised)

enum TXFormat {
    /// `mm:ss` under one hour, `h:mm:ss` otherwise (spec 7.3).
    static func timestamp(_ seconds: TimeInterval, documentDuration: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if documentDuration >= 3600 {
            return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
        }
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    /// `00:01:12,400` (tooltips and time fields).
    static func precise(_ seconds: TimeInterval) -> String {
        let total = max(0, seconds)
        let ms = Int((total - floor(total)) * 1000 + 0.5) % 1000
        let s = Int(total)
        return String(format: "%02d:%02d:%02d,%03d", s / 3600, (s % 3600) / 60, s % 60, ms)
    }

    /// `12:04` for elapsed recording time, `1:02:04` past one hour.
    static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    /// «42 min», «1 h 5 min», «38 s».
    static func shortDuration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s) s" }
        let m = s / 60
        if m < 60 { return "\(m) min" }
        return m % 60 == 0 ? "\(m / 60) h" : "\(m / 60) h \(m % 60) min"
    }

    /// «42 min 10 s».
    static func longDuration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s) s" }
        let h = s / 3600, m = (s % 3600) / 60, r = s % 60
        var parts: [String] = []
        if h > 0 { parts.append("\(h) h") }
        if m > 0 { parts.append("\(m) min") }
        if r > 0 && h == 0 { parts.append("\(r) s") }
        return parts.joined(separator: " ")
    }

    /// Spoken duration for VoiceOver: «1 minuto 12 segundos».
    static func spokenDuration(_ seconds: TimeInterval) -> String {
        let f = DateComponentsFormatter()
        f.allowedUnits = seconds >= 3600 ? [.hour, .minute, .second] : [.minute, .second]
        f.unitsStyle = .full
        var cal = Calendar.current
        cal.locale = TXL.locale
        f.calendar = cal
        return f.string(from: max(0, seconds)) ?? ""
    }

    /// «12 oct».
    static func shortDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = TXL.locale
        f.setLocalizedDateFormatFromTemplate("d MMM")
        return f.string(from: date).replacingOccurrences(of: ".", with: "")
    }

    /// «12 oct 2026, 10:42».
    static func longDateTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = TXL.locale
        f.setLocalizedDateFormatFromTemplate("d MMM y HH:mm")
        return f.string(from: date).replacingOccurrences(of: ".", with: "")
    }

    /// «12 de octubre» for VoiceOver.
    static func spokenDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = TXL.locale
        f.setLocalizedDateFormatFromTemplate("d MMMM")
        return f.string(from: date)
    }

    static func monthYear(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = TXL.locale
        f.setLocalizedDateFormatFromTemplate("MMMM y")
        return f.string(from: date).capitalized(with: TXL.locale)
    }

    /// «320 MB».
    static func bytes(_ value: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = value >= 1_000_000_000 ? [.useGB] : [.useMB]
        return f.string(fromByteCount: value)
    }

    /// Grouped integer: «1.380».
    static func integer(_ value: Int) -> String {
        let f = NumberFormatter()
        f.locale = TXL.locale
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    /// «~/Media/clase.m4a»: abbreviates the home folder only as a prefix of the path.
    static func displayPath(_ path: String, home: String = NSHomeDirectory()) -> String {
        let h = home.hasSuffix("/") ? String(home.dropLast()) : home
        if path == h { return "~" }
        if path.hasPrefix(h + "/") { return "~" + path.dropFirst(h.count) }
        return path
    }

    static func languageName(_ code: String) -> String {
        if code == "auto" { return TXL.t("language.auto", "Detectar automáticamente") }
        let name = TXL.locale.localizedString(forLanguageCode: code) ?? code
        return name.prefix(1).uppercased() + name.dropFirst()
    }
}
