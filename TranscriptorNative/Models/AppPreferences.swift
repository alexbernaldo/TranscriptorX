import Foundation

/// App-level preferences that are independent from transcription engine settings.
struct AppPreferences: Codable, Equatable {
    var uiLanguage: AppLanguage = .en

    static let `default` = AppPreferences()
}
