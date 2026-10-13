import AppIntents
import Foundation

// MARK: - Entidad de modelo para Atajos

struct ModelAppEntity: AppEntity {
    static var defaultQuery = ModelAppEntityQuery()
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Modelo de transcripción")

    var id: String
    var name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(id)")
    }
}

struct ModelAppEntityQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [ModelAppEntity] {
        ModelCatalog.all
            .filter { identifiers.contains($0.id) }
            .map { ModelAppEntity(id: $0.id, name: $0.displayName) }
    }

    func suggestedEntities() async throws -> [ModelAppEntity] {
        ModelCatalog.visible(showExperimental: false).map {
            ModelAppEntity(id: $0.id, name: $0.displayName)
        }
    }
}

// MARK: - Intención: Transcribir archivo

/// Transcribe an audio/video file and return the plain text.
struct TranscribeFileIntent: AppIntent {
    static var title: LocalizedStringResource = "Transcribe file"
    static var description = IntentDescription("Transcribes an audio or video file with your current settings and returns the text.")

    @Parameter(title: "Audio or video file")
    var file: IntentFile

    @Parameter(title: "Modelo de transcripción")
    var model: ModelAppEntity?

    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let data = file.data
        guard !data.isEmpty else {
            throw $file.needsValueError("Pick an audio or video file.")
        }
        let ext = URL(fileURLWithPath: file.filename).pathExtension
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("intent_\(UUID().uuidString).\(ext.isEmpty ? "m4a" : ext)")
        try data.write(to: tmp)

        guard FileInputService.isSupported(tmp) else {
            throw $file.needsValueError("Unsupported media type.")
        }

        let settings = TranscriptionSettings.default
        let chosenModelId = model?.id ?? settings.selectedModelId

        let preprocessOptions = AudioPreprocessor.Options(
            isolateVoice: settings.isolateVoice, denoise: settings.deepfilter,
            normalize: settings.normalize, useVAD: settings.useVAD)
        let result = try await TranscriptionService.shared.transcribe(
            file: tmp, modelId: chosenModelId, settings: settings,
            preprocessOptions: preprocessOptions, onProgress: { _, _ in },
            onSegment: { _ in })
        try? FileManager.default.removeItem(at: tmp)
        return .result(value: result.plainText)
    }
}

// MARK: - Intención: Obtener modelos disponibles

struct GetAvailableModelsIntent: AppIntent {
    static var title: LocalizedStringResource = "Obtener modelos disponibles"
    static var description = IntentDescription("Devuelve la lista de modelos de transcripción con su nombre de interfaz e identificador técnico.")

    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[ModelAppEntity]> {
        let entities = ModelCatalog.visible(showExperimental: false).map {
            ModelAppEntity(id: $0.id, name: $0.displayName)
        }
        return .result(value: entities)
    }
}
