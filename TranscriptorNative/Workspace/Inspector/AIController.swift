import SwiftUI

/// Local AI for the open document (spec 6.18): provider and model choice, availability,
/// title/summary/tags and chat. Everything runs on this Mac (Ollama and LM Studio on localhost,
/// Apple Foundation Models on device). Results are kept only through the document editor.
@MainActor
final class AIController: ObservableObject {
    static let shared = AIController()

    enum AITask: String { case title, summary, tags }

    enum Availability: Equatable {
        case checking
        case available
        case unavailable(String)
    }

    struct ChatMessage: Identifiable, Equatable {
        let id = UUID()
        let fromUser: Bool
        let author: String
        var text: String
        var incomplete = false
    }

    @AppStorage("ai.provider") var providerRaw: String = AIProviderKind.ollama.rawValue {
        willSet { objectWillChange.send() }
    }
    @AppStorage("ai.model.ollama") var ollamaModel: String = ""
    @AppStorage("ai.model.lmstudio") var lmStudioModel: String = ""

    @Published private(set) var availability: Availability = .checking
    @Published private(set) var models: [String] = []
    @Published private(set) var running: [UUID: AITask] = [:]
    @Published private(set) var titleSuggestion: [UUID: String] = [:]
    @Published private(set) var tagSuggestion: [UUID: [String]] = [:]
    @Published private(set) var failures: [UUID: [AITask: String]] = [:]
    @Published private(set) var chats: [UUID: [ChatMessage]] = [:]
    @Published private(set) var chatRunning: Set<UUID> = []

    private var tasks: [String: Task<Void, Never>] = [:]

    var provider: AIProviderKind {
        get { AIProviderKind(rawValue: providerRaw) ?? .ollama }
        set { providerRaw = newValue.rawValue; check() }
    }

    var selectedModel: String? {
        switch provider {
        case .ollama: return ollamaModel.isEmpty ? nil : ollamaModel
        case .lmstudio: return lmStudioModel.isEmpty ? nil : lmStudioModel
        case .appleFoundation: return nil
        }
    }

    func setModel(_ model: String) {
        switch provider {
        case .ollama: ollamaModel = model
        case .lmstudio: lmStudioModel = model
        case .appleFoundation: break
        }
        objectWillChange.send()
    }

    var providerName: String { Self.name(provider) }

    static func name(_ kind: AIProviderKind) -> String {
        switch kind {
        case .ollama: return "Ollama"
        case .lmstudio: return "LM Studio"
        case .appleFoundation: return "Apple Foundation Models"
        }
    }

    static var appleModelsSupported: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    // MARK: Availability («Volver a comprobar»)

    func check() {
        availability = .checking
        let provider = self.provider
        Task {
            if provider == .appleFoundation && !Self.appleModelsSupported {
                availability = .unavailable(TXL.t("ai.unavailable.macos", "Necesita macOS 26 o posterior"))
                models = []
                return
            }
            let list = await AISummaryService.shared.availableModels(for: provider)
            models = list
            if let current = selectedModel, !list.isEmpty, !list.contains(current) { setModel(list.first!) }
            if selectedModel == nil, let first = list.first, provider != .appleFoundation { setModel(first) }
            let client = await AISummaryService.shared.client(for: provider, model: selectedModel)
            if client != nil {
                if provider == .lmstudio && list.isEmpty {
                    availability = .unavailable(TXL.t("ai.unavailable.lmstudioNoModel", "LM Studio no tiene ningún modelo cargado"))
                } else {
                    availability = .available
                }
            } else {
                switch provider {
                case .ollama:
                    availability = .unavailable(TXL.t("ai.unavailable.ollama", "Ollama no responde en este Mac. Ábrelo y vuelve a comprobar."))
                case .lmstudio:
                    availability = .unavailable(TXL.t("ai.unavailable.lmstudio", "LM Studio no responde en este Mac. Ábrelo y vuelve a comprobar."))
                case .appleFoundation:
                    availability = .unavailable(TXL.t("ai.unavailable.apple", "Apple Intelligence no está disponible en este Mac"))
                }
            }
        }
    }

    // MARK: Tasks

    /// Entry point from the Transcription menu: shows the inspector tab and runs.
    func run(_ task: AITask, editorFromMenu editor: DocumentEditor?) {
        guard let editor else { return }
        WorkspaceState.shared.showInspector(tab: .ai)
        run(task, editor: editor)
    }

    func run(_ task: AITask, editor: DocumentEditor) {
        let id = editor.id
        let transcript = editor.document.text
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        cancel(task, document: id)
        running[id] = task
        failures[id]?[task] = nil
        let provider = self.provider, model = selectedModel
        let key = "\(id)-\(task.rawValue)"
        tasks[key] = Task { [weak self, weak editor] in
            defer {
                self?.running[id] = nil
                self?.tasks[key] = nil
            }
            guard let client = await AISummaryService.shared.client(for: provider, model: model) else {
                self?.failures[id, default: [:]][task] = TXL.f("ai.failed.unavailable", "%@ no está disponible", Self.name(provider))
                self?.check()
                return
            }
            do {
                let kind: AISummaryService.Kind = task == .title ? .title : (task == .tags ? .tags : .longSummary)
                let text = try await AISummaryService.shared.generate(kind, transcript: transcript, using: client)
                try Task.checkCancellation()
                switch task {
                case .title:
                    let clean = text.trimmingCharacters(in: CharacterSet(charactersIn: "\"«»“” \n"))
                    self?.titleSuggestion[id] = clean
                    editor?.storeAIResult(title: clean)
                case .summary:
                    editor?.storeAIResult(summary: text)
                case .tags:
                    self?.tagSuggestion[id] = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                }
            } catch is CancellationError {
                // Stopped by the user.
            } catch {
                if !Task.isCancelled {
                    self?.failures[id, default: [:]][task] = error.localizedDescription
                }
            }
        }
    }

    func cancel(_ task: AITask, document id: UUID) {
        tasks["\(id)-\(task.rawValue)"]?.cancel()
        tasks["\(id)-\(task.rawValue)"] = nil
        if running[id] == task { running[id] = nil }
    }

    func dismissTitle(_ id: UUID) { titleSuggestion[id] = nil }
    func dismissTags(_ id: UUID) { tagSuggestion[id] = nil }

    // MARK: Chat (kept for this session; not saved with the document)

    func send(_ question: String, editor: DocumentEditor) {
        let id = editor.id
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !chatRunning.contains(id) else { return }
        let author = selectedModel.map { "\(providerName) · \($0)" } ?? providerName
        chats[id, default: []].append(ChatMessage(fromUser: true, author: TXL.t("ai.chat.you", "Tú"), text: trimmed))
        chats[id, default: []].append(ChatMessage(fromUser: false, author: author, text: ""))
        chatRunning.insert(id)
        let transcript = String(editor.document.text.prefix(20000))
        let history = chats[id, default: []].dropLast().suffix(8).map { ($0.fromUser ? "User: " : "Assistant: ") + $0.text }.joined(separator: "\n")
        let provider = self.provider, model = selectedModel
        let key = "\(id)-chat"
        tasks[key] = Task { [weak self] in
            defer { self?.chatRunning.remove(id); self?.tasks[key] = nil }
            guard let client = await AISummaryService.shared.client(for: provider, model: model) else {
                self?.finishChat(id, text: TXL.f("ai.failed.unavailable", "%@ no está disponible", Self.name(provider)), incomplete: true)
                return
            }
            do {
                let answer = try await client.chat(
                    system: "You answer questions about a transcript. Use only its content. Answer in the user's language, concisely.\n\nTranscript:\n\(transcript)",
                    user: history, temperature: 0.3)
                try Task.checkCancellation()
                self?.finishChat(id, text: answer, incomplete: false)
            } catch {
                self?.finishChat(id, text: self?.chats[id]?.last?.text ?? "", incomplete: true)
            }
        }
    }

    func stopChat(_ id: UUID) {
        tasks["\(id)-chat"]?.cancel()
    }

    func retryLast(_ editor: DocumentEditor) {
        guard var list = chats[editor.id], let lastQuestion = list.last(where: \.fromUser) else { return }
        if list.last?.fromUser == false { list.removeLast() }
        list.removeAll { $0.id == lastQuestion.id }
        chats[editor.id] = list
        send(lastQuestion.text, editor: editor)
    }

    private func finishChat(_ id: UUID, text: String, incomplete: Bool) {
        guard var list = chats[id], !list.isEmpty else { return }
        list[list.count - 1].text = text
        list[list.count - 1].incomplete = incomplete
        chats[id] = list
    }
}
