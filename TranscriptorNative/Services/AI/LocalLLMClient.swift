import Foundation
import FoundationModels

enum AIProviderKind: String, CaseIterable, Identifiable {
    case ollama, lmstudio, appleFoundation
    var id: String { rawValue }
}

private func localized(_ spanish: String, _ english: String) -> String {
    UserDefaults.standard.string(forKey: "app_ui_language") == "es" ? spanish : english
}

enum AIError: LocalizedError {
    case notConfigured(String), serverUnreachable(String), badResponse(Int), emptyResponse

    var errorDescription: String? {
        switch self {
        case .notConfigured(let p):
            return localized("No se encontró \(p) en este equipo. Abre \(p) y vuelve a intentarlo.", "\(p) was not found on this machine. Open \(p) and try again.")
        case .serverUnreachable(let p):
            return localized("No se puede conectar a \(p) (¿está en marcha?).", "Cannot connect to \(p) (is it running?).")
        case .badResponse(let code):
            return localized("El servidor local devolvió HTTP \(code).", "The local server returned HTTP \(code).")
        case .emptyResponse:
            return localized("La IA local devolvió una respuesta vacía.", "The local AI returned an empty response.")
        }
    }
}

/// Chat completion against a *local* LLM server. No cloud providers, ever.
protocol LocalLLMClient {
    var kind: AIProviderKind { get }
    var displayName: String { get }
    func isAvailable() async -> Bool
    func chat(system: String, user: String, temperature: Double) async throws -> String
}

struct OllamaClient: LocalLLMClient {
    let kind = AIProviderKind.ollama
    let displayName = "Ollama"
    var baseURL = URL(string: "http://localhost:11434")!
    var model: String

    func isAvailable() async -> Bool {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        req.timeoutInterval = 1.5
        guard let (_, response) = try? await URLSession.shared.data(for: req),
              let http = response as? HTTPURLResponse, http.statusCode == 200 else { return false }
        return true
    }

    func chat(system: String, user: String, temperature: Double) async throws -> String {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user]
            ],
            "stream": false,
            "options": ["temperature": temperature]
        ])
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw AIError.serverUnreachable("Ollama") }
        guard http.statusCode == 200 else { throw AIError.badResponse(http.statusCode) }
        struct ChatResponse: Decodable {
            struct Msg: Decodable { let content: String }
            let message: Msg
        }
        let text = try JSONDecoder().decode(ChatResponse.self, from: data).message.content
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AIError.emptyResponse }
        return trimmed
    }
}

struct LMStudioClient: LocalLLMClient {
    let kind = AIProviderKind.lmstudio
    let displayName = "LM Studio"
    var baseURL = URL(string: "http://localhost:1234/v1")!
    var model: String

    func isAvailable() async -> Bool {
        var req = URLRequest(url: baseURL.appendingPathComponent("models"))
        req.timeoutInterval = 1.5
        guard let (_, response) = try? await URLSession.shared.data(for: req),
              let http = response as? HTTPURLResponse, http.statusCode == 200 else { return false }
        return true
    }

    func chat(system: String, user: String, temperature: Double) async throws -> String {
        var req = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user]
            ],
            "temperature": temperature
        ])
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw AIError.badResponse((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        struct Choice: Decodable { struct M: Decodable { let content: String }; let message: M }
        struct Root: Decodable { let choices: [Choice] }
        let text = try JSONDecoder().decode(Root.self, from: data).choices.first?.message.content ?? ""
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AIError.emptyResponse }
        return trimmed
    }
}

struct AppleFoundationClient: LocalLLMClient {
    let kind = AIProviderKind.appleFoundation
    let displayName = "Modelos de Apple"

    func isAvailable() async -> Bool {
        if #available(macOS 26.0, *) {
            return SystemLanguageModel.default.isAvailable
        }
        return false
    }

    func chat(system: String, user: String, temperature: Double) async throws -> String {
        if #available(macOS 26.0, *) {
            return try await _chat(system: system, user: user, temperature: temperature)
        }
        throw AIError.notConfigured("Modelos de Apple")
    }

    @available(macOS 26.0, *)
    private func _chat(system: String, user: String, temperature: Double) async throws -> String {
        let session = LanguageModelSession(instructions: system)
        let response = try await session.respond(to: user)
        let trimmed = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AIError.emptyResponse }
        return trimmed
    }
}
