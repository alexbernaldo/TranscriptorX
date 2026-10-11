import Foundation

/// Local-only AI post-processing: title, summary and tags. No cloud.
@MainActor
final class AISummaryService: ObservableObject {
    static let shared = AISummaryService()
    @Published var isRunning = false
    @Published var lastError: String?

    enum Kind { case title, shortSummary, longSummary, tags }

    private let models = ["llama3.2", "qwen2.5", "phi3"]
    private var client: (any LocalLLMClient)?

    private struct OllamaTags: Decodable {
        struct Model: Decodable { let name: String }
        let models: [Model]?
    }

    /// Ollama with the first installed model: preferred names if present, else whatever the server has.
    private func ollamaClient() async -> OllamaClient? {
        let probe = OllamaClient(model: "")
        guard await probe.isAvailable() else { return nil }
        var req = URLRequest(url: probe.baseURL.appendingPathComponent("api/tags"))
        req.timeoutInterval = 2
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let tags = try? JSONDecoder().decode(OllamaTags.self, from: data),
              let installed = tags.models?.map({ $0.name }), !installed.isEmpty else { return nil }
        let preferred = models.first { m in
            installed.contains { $0 == m || $0.hasPrefix(m + ":") }
        } ?? installed.first { !$0.contains("/") }
            ?? installed.first
        guard let model = preferred else { return nil }
        return OllamaClient(model: model)
    }

    /// First reachable local client, or nil (UI hides AI features then).
    func resolveClient() async -> (any LocalLLMClient)? {
        if let c = client, await c.isAvailable() { return c }
        if let ollama = await ollamaClient() { client = ollama; return ollama }
        let lm = LMStudioClient(model: "")
        if await lm.isAvailable() { client = lm; return lm }
        if #available(macOS 26.0, *) {
            let apple = AppleFoundationClient()
            if await apple.isAvailable() { client = apple; return apple }
        }
        return nil
    }

    /// Client for an explicit provider choice (inspector › IA). `model` is the provider's model name.
    func client(for provider: AIProviderKind, model: String?) async -> (any LocalLLMClient)? {
        switch provider {
        case .ollama:
            if let model, !model.isEmpty {
                let c = OllamaClient(model: model)
                return await c.isAvailable() ? c : nil
            }
            return await ollamaClient()
        case .lmstudio:
            let c = LMStudioClient(model: model ?? "")
            return await c.isAvailable() ? c : nil
        case .appleFoundation:
            let c = AppleFoundationClient()
            return await c.isAvailable() ? c : nil
        }
    }

    /// Models offered by a local server (Ollama `/api/tags`, LM Studio `/v1/models`).
    func availableModels(for provider: AIProviderKind) async -> [String] {
        switch provider {
        case .ollama:
            var req = URLRequest(url: URL(string: "http://localhost:11434/api/tags")!)
            req.timeoutInterval = 2
            guard let (data, _) = try? await URLSession.shared.data(for: req),
                  let tags = try? JSONDecoder().decode(OllamaTags.self, from: data) else { return [] }
            return tags.models?.map(\.name) ?? []
        case .lmstudio:
            struct Models: Decodable { struct M: Decodable { let id: String }; let data: [M] }
            var req = URLRequest(url: URL(string: "http://localhost:1234/v1/models")!)
            req.timeoutInterval = 2
            guard let (data, _) = try? await URLSession.shared.data(for: req),
                  let models = try? JSONDecoder().decode(Models.self, from: data) else { return [] }
            return models.data.map(\.id)
        case .appleFoundation:
            return []
        }
    }

    /// Runs a task and returns the text without writing to storage (the caller decides).
    func generate(_ kind: Kind, transcript: String, using client: any LocalLLMClient) async throws -> String {
        let (system, user) = prompt(for: kind, transcript: String(transcript.prefix(24000)))
        var text = try await client.chat(system: system, user: user, temperature: 0.2)
        if kind == .longSummary && transcript.count > 24000 {
            var partials: [String] = []
            var start = transcript.startIndex
            var part = 1
            while start < transcript.endIndex {
                try Task.checkCancellation()
                let end = transcript.index(start, offsetBy: 6000, limitedBy: transcript.endIndex) ?? transcript.endIndex
                let p = prompt(for: .shortSummary, transcript: String(transcript[start..<end]))
                partials.append("Part \(part): " + (try await client.chat(system: p.system, user: p.user, temperature: 0.2)))
                start = end
                part += 1
            }
            let merged = prompt(for: .longSummary, transcript: partials.joined(separator: "\n\n"))
            text = try await client.chat(system: merged.system, user: merged.user, temperature: 0.2)
        }
        return text
    }

    func prompt(for kind: Kind, transcript: String) -> (system: String, user: String) {
        switch kind {
        case .title:
            return ("You name transcripts. No quotes, colons, subtitles or emoji. Max 8 words.",
                    "Title this transcript:\n\n\(transcript)")
        case .shortSummary:
            return ("You summarize transcripts in 20 words or fewer, one sentence, no preamble.",
                    "Summarize:\n\n\(transcript)")
        case .longSummary:
            return ("You write clear, structured summaries with bullet points and section headings when useful.",
                    "Summarize the following transcript concisely:\n\n\(transcript)")
        case .tags:
            return ("You extract 3-6 single-word or short topic tags, comma separated, lowercase, no hashtags.",
                    "Tags for:\n\n\(transcript)")
        }
    }

    /// Chunk long transcripts (Ollama context limits): ~6000 chars per chunk,
    /// summarize each, then merge with a final pass.
    func run(_ kind: Kind, on transcript: String, for transcriptionId: UUID?) async -> String? {
        guard let client = await resolveClient() else {
            lastError = AIError.notConfigured("Ollama, LM Studio o Modelos de Apple").errorDescription
            return nil
        }
        isRunning = true; defer { isRunning = false; lastError = nil }

        do {
            let (system, user) = prompt(for: kind, transcript: String(transcript.prefix(24000)))
            var text = try await client.chat(system: system, user: user, temperature: 0.2)

            if kind == .longSummary && transcript.count > 24000 {
                let chunks = stride(from: 0, to: transcript.count, by: 6000).map {
                    String(transcript[transcript.index(transcript.startIndex, offsetBy: $0)
                        ..< transcript.index(transcript.startIndex, offsetBy: min($0 + 6000, transcript.count))])
                }
                var partials: [String] = []
                for (i, chunk) in chunks.enumerated() {
                    let p = prompt(for: .shortSummary, transcript: chunk)
                    partials.append("Part \(i + 1): " + (try await client.chat(system: p.system, user: p.user, temperature: 0.2)))
                }
                let merged = prompt(for: .longSummary, transcript: partials.joined(separator: "\n\n"))
                text = try await client.chat(system: merged.system, user: merged.user, temperature: 0.2)
            }

            if let id = transcriptionId, let idx = TranscriptionStorage.shared.loadTranscriptions().firstIndex(where: { $0.id == id }) {
                var all = TranscriptionStorage.shared.loadTranscriptions()
                switch kind {
                case .title: all[idx].aiTitle = text
                case .shortSummary, .longSummary: all[idx].aiSummary = text
                case .tags: all[idx].aiTags = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                }
                TranscriptionStorage.shared.saveTranscriptions(all)
                NotificationCenter.default.post(name: .transcriptionsDidChange, object: nil)
            }
            return text
        } catch {
            lastError = error.localizedDescription
            AppLogger.shared.logError(error, context: "AISummaryService", category: .transcription)
            return nil
        }
    }
}
