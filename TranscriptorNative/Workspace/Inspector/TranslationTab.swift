import SwiftUI
import Translation

/// Traducción (spec 6.19). Engines: Apple Translation (macOS 15+, pairs macOS supports),
/// whisper --translate (English only, a new job from the original audio), local LLM (any language).
/// Result: read-only text per language, stored with the document (existing format).
struct TranslationTab: View {
    @ObservedObject var editor: DocumentEditor
    @ObservedObject private var controller = TranslationController.shared
    @ObservedObject private var ai = AIController.shared
    @State private var source = ""
    @State private var engine: TranslationController.Engine = TranslationController.Engine.defaultEngine
    @State private var target = "en"
    @State private var appleStatus: [String: TranslationController.PairStatus] = [:]

    private var id: UUID { editor.id }
    private var segments: [TranscriptionSegment] { (editor.document.segments ?? []).filter { !$0.isDeleted } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                row(TXL.t("translation.source", "Origen")) {
                    Picker("", selection: $source) {
                        ForEach(TranscriptionLanguages.codes.filter { $0 != "auto" }, id: \.self) { code in
                            Text(code == editor.document.language
                                 ? TXL.f("translation.detected", "%@ (detectado)", TXFormat.languageName(code))
                                 : TXFormat.languageName(code)).tag(code)
                        }
                    }
                    .labelsHidden()
                }
                row(TXL.t("translation.engine", "Motor")) {
                    Picker("", selection: $engine) {
                        ForEach(TranslationController.Engine.allCases) { e in
                            Text(e.title).tag(e).disabled(!e.isSupportedOnThisMac)
                        }
                    }
                    .labelsHidden()
                    engineNote
                }
                row(TXL.t("translation.target", "Destino")) {
                    Picker("", selection: $target) {
                        ForEach(targets, id: \.self) { code in
                            let unsupported = engine == .apple && appleStatus[code] == .unsupported
                            Text(unsupported ? TXL.f("translation.unsupportedPair", "%@ · No disponible con Apple Translation", TXFormat.languageName(code)) : TXFormat.languageName(code))
                                .tag(code)
                                .disabled(unsupported)
                        }
                    }
                    .labelsHidden()
                    .disabled(engine == .whisper)
                }
                actionArea
                if let langs = editor.document.fullTextTranslations?.keys.sorted(), !langs.isEmpty {
                    TXSeparator()
                    Text(TXL.f("translation.available", "Traducciones guardadas: %@", langs.map { TXFormat.languageName($0) }.joined(separator: ", ")))
                        .font(.system(size: 12))
                        .foregroundStyle(TX.Colors.textSecondary)
                    Text(TXL.t("translation.showHint", "Elige la versión en la cabecera del documento."))
                        .font(.system(size: 11))
                        .foregroundStyle(TX.Colors.textSecondary)
                }
            }
            .padding(TX.Space.s16)
        }
        .onAppear {
            source = editor.document.language == "auto" ? "es" : editor.document.language
            if !engine.isSupportedOnThisMac { engine = .llm }
            refreshAppleStatus()
        }
        .txOnChange(of: source) { _ in refreshAppleStatus() }
        .txOnChange(of: engine) { e in
            if e == .whisper { target = "en" }
            refreshAppleStatus()
        }
    }

    private var targets: [String] {
        switch engine {
        case .whisper: return ["en"]
        default: return TranscriptionLanguages.codes.filter { $0 != "auto" && $0 != source }
        }
    }

    @ViewBuilder private var engineNote: some View {
        switch engine {
        case .apple:
            if TranslationController.Engine.apple.isSupportedOnThisMac {
                note(TXL.t("translation.apple.note", "macOS puede pedirte que descargues el idioma"))
            } else {
                note(TXL.t("translation.apple.unsupported", "Necesita macOS 15 o posterior"))
            }
        case .whisper:
            if editor.document.sourceURL == nil || !(editor.document.sourceURL?.isFileURL ?? false) {
                note(TXL.t("translation.whisper.noAudio", "Necesita el audio original, y este documento no lo tiene"))
            } else {
                note(TXL.t("translation.whisper.note", "Solo traduce al inglés. Crea un trabajo nuevo desde el audio con un modelo multilingüe."))
            }
        case .llm:
            switch ai.availability {
            case .unavailable(let reason): note(reason, warning: true)
            default: note(TXL.f("translation.llm.note", "Usa %@ (pestaña IA). La calidad depende del modelo local.", ai.providerName))
            }
        }
    }

    @ViewBuilder private var actionArea: some View {
        if let progress = controller.progress[id] {
            VStack(alignment: .leading, spacing: 6) {
                Text(progress.total > 0
                     ? TXL.f("translation.progress", "Traduciendo · %d de %d segmentos", progress.done, progress.total)
                     : TXL.t("translation.progress.indeterminate", "Traduciendo…"))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(TX.Colors.textSecondary)
                TXProgressLine(kind: progress.total > 0 ? .determinate(Double(progress.done) / Double(progress.total)) : .indeterminate)
                Button(TXL.t("ai.stop", "Detener")) { controller.cancel(id) }
                    .buttonStyle(TXBorderlessButtonStyle())
            }
        } else {
            if let error = controller.errors[id] {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(TX.Colors.error).accessibilityHidden(true)
                    Text(error).font(.system(size: 12)).foregroundStyle(TX.Colors.textPrimary).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Spacer()
                Button(engine == .whisper ? TXL.t("translation.whisper.button", "Transcribir de nuevo en inglés") : TXL.t("translation.button", "Traducir")) {
                    start()
                }
                .buttonStyle(TXPrimaryButtonStyle())
                .disabled(!canStart)
            }
        }
    }

    private var canStart: Bool {
        guard !editor.document.text.isEmpty else { return false }
        switch engine {
        case .apple: return TranslationController.Engine.apple.isSupportedOnThisMac && appleStatus[target] != .unsupported
        case .whisper: return editor.document.sourceURL?.isFileURL == true && FileManager.default.fileExists(atPath: editor.document.sourceURL!.path)
        case .llm: return ai.availability == .available
        }
    }

    private func start() {
        switch engine {
        case .whisper:
            controller.startWhisper(editor: editor)
        case .llm:
            controller.startLLM(editor: editor, segments: segments, target: target)
        case .apple:
            controller.requestApple(editor: editor, segments: segments, source: source, target: target)
        }
    }

    private func refreshAppleStatus() {
        guard engine == .apple else { return }
        Task {
            var status: [String: TranslationController.PairStatus] = [:]
            for code in targets { status[code] = await TranslationController.pairStatus(from: source, to: code) }
            appleStatus = status
            if status[target] == .unsupported, let first = targets.first(where: { status[$0] != .unsupported }) { target = first }
        }
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(TX.Colors.textSecondary)
            content()
        }
    }

    private func note(_ text: String, warning: Bool = false) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(warning ? TX.Colors.warning : TX.Colors.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Runs and tracks translations; one at a time per document.
@MainActor
final class TranslationController: ObservableObject {
    static let shared = TranslationController()

    enum Engine: String, CaseIterable, Identifiable {
        case apple, whisper, llm
        var id: String { rawValue }
        var title: String {
            switch self {
            case .apple: return "Apple Translation"
            case .whisper: return "whisper"
            case .llm: return TXL.t("translation.engine.llm", "LLM local")
            }
        }
        var isSupportedOnThisMac: Bool {
            if self == .apple { return TranslationService.isSystemTranslationAvailable }
            return true
        }
        static var defaultEngine: Engine { Engine.apple.isSupportedOnThisMac ? .apple : .llm }
    }

    enum PairStatus { case supported, unsupported, unknown }

    struct Progress: Equatable { var done: Int; var total: Int }

    struct AppleRequest: Equatable {
        let id = UUID()
        let documentId: UUID
        let source: String
        let target: String
        let texts: [String]
        static func == (a: Self, b: Self) -> Bool { a.id == b.id }
    }

    @Published private(set) var progress: [UUID: Progress] = [:]
    @Published private(set) var errors: [UUID: String] = [:]
    @Published var appleRequest: AppleRequest?
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private weak var appleEditor: DocumentEditor?

    static func pairStatus(from source: String, to target: String) async -> PairStatus {
        if #available(macOS 15.0, *) {
            let status = await LanguageAvailability().status(from: Locale.Language(identifier: source), to: Locale.Language(identifier: target))
            switch status {
            case .installed, .supported: return .supported
            case .unsupported: return .unsupported
            @unknown default: return .unknown
            }
        }
        return .unsupported
    }

    func cancel(_ id: UUID) {
        tasks[id]?.cancel()
        tasks[id] = nil
        progress[id] = nil
        if appleRequest?.documentId == id { appleRequest = nil }
    }

    // whisper --translate: a new job from the original audio (cannot apply to an existing document).
    func startWhisper(editor: DocumentEditor) {
        guard let url = editor.document.sourceURL, url.isFileURL else { return }
        var settings = QuickSettingsModel.defaultSettings()
        settings.translate = true
        settings.language = editor.document.language
        if ModelCapabilities.isEnglishOnly(settings.selectedModelId) { settings.selectedModelId = "base" }
        let id = JobManager.shared.enqueue(fileURL: url, fileName: editor.document.title + " (English).\(url.pathExtension)",
                                            settings: settings, source: .file, userInitiated: true)
        WorkspaceState.shared.showToast(ToastItem(icon: .info, text: TXL.t("translation.whisper.queued", "Trabajo añadido a la cola"),
                                                  actionTitle: TXL.t("common.show", "Ver"),
                                                  action: { WorkspaceState.shared.open(job: id) }))
    }

    // Local LLM: chunks of segments, one per line, progress counted in segments.
    func startLLM(editor: DocumentEditor, segments: [TranscriptionSegment], target: String) {
        let id = editor.id
        let texts = segments.isEmpty ? [editor.document.text] : segments.map(\.text)
        progress[id] = Progress(done: 0, total: segments.isEmpty ? 0 : texts.count)
        errors[id] = nil
        let provider = AIController.shared.provider, model = AIController.shared.selectedModel
        tasks[id] = Task { [weak self, weak editor] in
            guard let client = await AISummaryService.shared.client(for: provider, model: model) else {
                self?.fail(id, TXL.f("ai.failed.unavailable", "%@ no está disponible", AIController.name(provider)))
                return
            }
            let languageName = Locale(identifier: "en").localizedString(forLanguageCode: target) ?? target
            var output: [String] = []
            var index = 0
            do {
                while index < texts.count {
                    try Task.checkCancellation()
                    var chunk: [String] = []
                    var size = 0
                    while index < texts.count, size + texts[index].count < 3000 || chunk.isEmpty {
                        chunk.append(texts[index].replacingOccurrences(of: "\n", with: " "))
                        size += texts[index].count
                        index += 1
                    }
                    let answer = try await client.chat(
                        system: "You translate transcripts. Translate each input line to \(languageName). Output exactly one line per input line, same order, no numbering, no notes.",
                        user: chunk.joined(separator: "\n"), temperature: 0)
                    output.append(answer.trimmingCharacters(in: .whitespacesAndNewlines))
                    self?.progress[id]?.done = index
                }
                editor?.storeTranslation(output.joined(separator: "\n"), language: target)
                self?.progress[id] = nil
                WorkspaceState.shared.showToast(ToastItem(icon: .success, text: TXL.t("translation.ready", "Traducción lista")))
            } catch is CancellationError {
                self?.progress[id] = nil
            } catch {
                self?.fail(id, error.localizedDescription)
            }
        }
    }

    // Apple Translation: the session only exists inside `.translationTask`; the driver view runs it.
    func requestApple(editor: DocumentEditor, segments: [TranscriptionSegment], source: String, target: String) {
        let texts = segments.isEmpty ? [editor.document.text] : segments.map(\.text)
        appleEditor = editor
        progress[editor.id] = Progress(done: 0, total: segments.isEmpty ? 0 : texts.count)
        errors[editor.id] = nil
        appleRequest = AppleRequest(documentId: editor.id, source: source, target: target, texts: texts)
    }

    func appleProgress(_ id: UUID, done: Int) { progress[id]?.done = done }

    func appleFinished(_ request: AppleRequest, output: [String]) {
        appleEditor?.storeTranslation(output.joined(separator: "\n"), language: request.target)
        progress[request.documentId] = nil
        appleRequest = nil
        WorkspaceState.shared.showToast(ToastItem(icon: .success, text: TXL.t("translation.ready", "Traducción lista")))
    }

    func appleFailed(_ request: AppleRequest, _ message: String) {
        appleRequest = nil
        fail(request.documentId, message)
    }

    private func fail(_ id: UUID, _ message: String) {
        progress[id] = nil
        errors[id] = message
    }
}

@available(macOS 15.0, *)
struct AppleTranslationDriver: View {
    @ObservedObject var controller: TranslationController

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .translationTask(configuration) { session in
                guard let request = controller.appleRequest else { return }
                var output: [String] = []
                do {
                    for (i, text) in request.texts.enumerated() {
                        if controller.appleRequest != request { return }
                        let response = try await session.translate(text)
                        output.append(response.targetText)
                        controller.appleProgress(request.documentId, done: i + 1)
                    }
                    controller.appleFinished(request, output: output)
                } catch {
                    controller.appleFailed(request, error.localizedDescription)
                }
            }
    }

    private var configuration: TranslationSession.Configuration? {
        guard let r = controller.appleRequest else { return nil }
        return TranslationSession.Configuration(source: Locale.Language(identifier: r.source), target: Locale.Language(identifier: r.target))
    }
}
