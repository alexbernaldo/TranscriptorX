import Foundation
import Translation

/// Local translation via the system Translation framework (macOS 15+).
/// Falls back to a local LLM; never calls a cloud translation API.
@MainActor
final class TranslationService: ObservableObject {
    static let shared = TranslationService()
    @Published var isTranslating = false
    @Published var lastError: String?

    static var isSystemTranslationAvailable: Bool {
        if #available(macOS 15.0, *) { return true }
        return false
    }

    /// Configuration for `.translationTask` (macOS 15+); callers below that use the LLM path.
    @available(macOS 15.0, *)
    static func systemConfiguration(for language: String) -> TranslationSession.Configuration? {
        TranslationSession.Configuration(target: Locale.Language(identifier: language))
    }

    /// Translate `text` into `target` using a SwiftUI-less session.
    /// NOTE: `TranslationSession` is only creatable from a `.translationTask` view modifier.
    /// Therefore the view drives it: this service only stores results and orchestrates the LLM fallback.
    func store(_ text: String, for language: String, in transcriptionId: UUID?) {
        guard let id = transcriptionId else { return }
        var all = TranscriptionStorage.shared.loadTranscriptions()
        guard let idx = all.firstIndex(where: { $0.id == id }) else { return }
        if all[idx].fullTextTranslations == nil { all[idx].fullTextTranslations = [:] }
        all[idx].fullTextTranslations?[language] = text
        TranscriptionStorage.shared.saveTranscriptions(all)
        NotificationCenter.default.post(name: .transcriptionsDidChange, object: nil)
    }

    /// Fallback: translate with the local LLM (chunked, joined).
    func translateWithLLM(_ text: String, to language: String) async throws -> String {
        guard let client = await AISummaryService.shared.resolveClient() else {
            throw AIError.notConfigured("Ollama, LM Studio o Modelos de Apple")
        }
        let names = ["en": "English", "es": "Spanish", "fr": "French", "de": "German", "pt": "Portuguese"]
        let target = names[language] ?? language
        let chunk = String(text.prefix(6000))
        return try await client.chat(
            system: "You translate transcripts. Output only the translation, no notes.",
            user: "Translate to \(target):\n\n\(chunk)", temperature: 0)
    }
}
