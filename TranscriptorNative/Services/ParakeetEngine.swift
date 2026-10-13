import Foundation
import AVFoundation
import CoreML
import FluidAudio
import NaturalLanguage

/// Bloquea la red de FluidAudio salvo durante una descarga que ha pedido el usuario.
///
/// FluidAudio descarga por su cuenta cuando falta un archivo (`downloadAndLoad`, `loadModels`
/// con recuperación, reparación del tokenizer…). Con `ModelHub.offlineMode` activado esas rutas
/// lanzan `networkDisabled` / `modelMissing` en lugar de conectarse. Solo `withUserDownload`
/// lo abre, y únicamente mientras dura la descarga explícita.
enum FluidNetworkGate {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var permits = 0

    /// Se llama al arrancar, antes de tocar cualquier cargador de FluidAudio.
    static func lockDown() {
        lock.lock(); defer { lock.unlock() }
        if permits == 0 { ModelHub.offlineMode = true }
    }

    static func withUserDownload<T>(_ body: () async throws -> T) async rethrows -> T {
        lock.lock(); permits += 1; ModelHub.offlineMode = false; lock.unlock()
        AppLogger.shared.log("FluidAudio network opened for a user download", category: .model)
        defer {
            lock.lock(); permits -= 1
            if permits == 0 { ModelHub.offlineMode = true }
            lock.unlock()
            AppLogger.shared.log("FluidAudio network closed", category: .model)
        }
        return try await body()
    }
}

/// Motor de transcripción local basado en NVIDIA Parakeet (TDT 0.6B) sobre CoreML y Neural Engine vía FluidAudio.
actor ParakeetEngine {
    static let shared = ParakeetEngine()

    enum ParakeetError: LocalizedError {
        case unsupportedModel(String)
        case unsupportedPlatform(String)
        case transcriptionFailed(String)
        case modelNotFound(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedModel(let id):
                return "Modelo Parakeet no admitido: \(id)"
            case .unsupportedPlatform(let reason):
                return reason
            case .transcriptionFailed(let detail):
                return "Fallo en la transcripción Parakeet: \(detail)"
            case .modelNotFound(let id):
                return "El modelo \(id) no está descargado."
            }
        }
    }

    private var currentVersion: AsrModelVersion?
    private var currentModels: AsrModels?
    private var currentManager: AsrManager?

    private init() {
        Task { @MainActor in
            ModelMemoryManager.shared.registerUnloadHandler { [weak self] in
                await self?.cleanup()
            }
        }
    }

    // MARK: - Versión del modelo

    static func asrModelVersion(for modelId: String) -> AsrModelVersion? {
        switch modelId {
        case "parakeet-tdt-0.6b-v3": return .v3
        case "parakeet-tdt-0.6b-v2": return .v2
        case "parakeet-ultra": return .ultra
        case "parakeet-redux": return .redux
        default: return nil
        }
    }

    static func modelId(for version: AsrModelVersion) -> String {
        switch version {
        case .v2: return "parakeet-tdt-0.6b-v2"
        case .ultra: return "parakeet-ultra"
        case .redux: return "parakeet-redux"
        default: return "parakeet-tdt-0.6b-v3"
        }
    }

    /// Parakeet no informa del idioma: se deduce del texto con NaturalLanguage, en este Mac.
    static func detectLanguage(of text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = ModelCatalog.languagesParakeetV3.map { NLLanguage(rawValue: $0) }
        recognizer.processString(text)
        return recognizer.dominantLanguage?.rawValue
    }

    // MARK: - Soporte de plataforma y versión

    static func checkPlatformSupport(for version: AsrModelVersion) throws {
        if version == .redux {
            let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
            guard major >= 15 else {
                throw ParakeetError.unsupportedPlatform("Parakeet Redux requiere macOS 15 o superior.")
            }
        }
    }

    // MARK: - Descarga y carga

    func isDownloaded(version: AsrModelVersion) -> Bool {
        AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: version), version: version)
    }

    func download(
        version: AsrModelVersion,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try Self.checkPlatformSupport(for: version)
        try await FluidNetworkGate.withUserDownload {
            _ = try await AsrModels.download(
                version: version,
                progressHandler: { p in
                    progress(p.fractionCompleted)
                }
            )
        }
        ModelStorageService.shared.notifyChanged()
    }

    func loadManager(
        for version: AsrModelVersion,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> AsrManager {
        if let currentManager, currentVersion == version {
            return currentManager
        }

        try Self.checkPlatformSupport(for: version)

        let handler: ProgressHandler? = progress.map { cb in
            { @Sendable p in cb(p.fractionCompleted) }
        }

        // Nunca descarga aquí: sin archivos, error y la UI ofrece «Descargar».
        guard isDownloaded(version: version) else {
            throw ParakeetError.modelNotFound(Self.modelId(for: version))
        }
        await cleanup()
        let models = try await AsrModels.loadFromCache(
            version: version,
            progressHandler: handler
        )

        let manager = AsrManager(config: .default, models: models)
        self.currentVersion = version
        self.currentModels = models
        self.currentManager = manager

        return manager
    }

    // MARK: - Transcripción

    func transcribe(
        file: URL,
        modelId: String,
        settings: TranscriptionSettings,
        preprocessOptions: AudioPreprocessor.Options = .default,
        onProgress: @escaping (Double, String) -> Void,
        onSegment: ((TranscriptionService.LiveSegment) -> Void)? = nil,
        onPhase: ((JobPhase) -> Void)? = nil
    ) async throws -> TranscriptionResult {
        guard let version = Self.asrModelVersion(for: modelId) else {
            throw ParakeetError.unsupportedModel(modelId)
        }

        await ModelMemoryManager.shared.notifyModelInUse(modelId)

        // Preprocesado de audio
        let preprocessor = AudioPreprocessor.shared
        preprocessor.resetCancellation()

        var preprocessDetail: [String] = []
        if preprocessOptions.denoise { preprocessDetail.append("DeepFilter") }
        if preprocessOptions.isolateVoice { preprocessDetail.append("Demucs") }
        onPhase?(.preprocessing(detail: preprocessDetail.isEmpty ? nil : preprocessDetail.joined(separator: " + ")))

        let processedFile = try await preprocessor.process(
            inputFile: file,
            options: preprocessOptions,
            onProgress: { p, s in
                onProgress(p * 0.15, s)
            }
        )

        defer {
            if processedFile != file && processedFile.path != file.path {
                try? FileManager.default.removeItem(at: processedFile)
            }
        }

        // Carga o reutilización del motor ASR
        onPhase?(.loadingModel)
        onProgress(0.18, "Cargando motor Parakeet…")

        let manager = try await loadManager(for: version) { fraction in
            onProgress(0.18 + fraction * 0.12, "Preparando modelo…")
        }

        onPhase?(.transcribing)
        onProgress(0.30, "Transcribiendo con Parakeet…")

        // Tarea de escucha de progreso interno
        let progressTask = Task { [weak manager] in
            guard let manager else { return }
            do {
                for try await p in await manager.transcriptionProgressStream {
                    let overall = 0.30 + (p * 0.55)
                    onProgress(overall, "Transcribiendo…")
                }
            } catch {}
        }

        // Ejecución de transcripción
        var decoderState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let asrLanguage: Language? = (settings.language != "auto" && !settings.language.isEmpty)
            ? Language(rawValue: settings.language)
            : nil

        let asrResult: ASRResult
        do {
            asrResult = try await manager.transcribeDiskBacked(
                processedFile,
                decoderState: &decoderState,
                language: asrLanguage
            )
        } catch {
            progressTask.cancel()
            throw ParakeetError.transcriptionFailed(error.localizedDescription)
        }
        progressTask.cancel()

        onProgress(0.85, "Procesando texto y marcas de tiempo…")

        // Segmentación y timestamps por palabra
        var segments = buildSegments(from: asrResult)

        // Notificación de segmentos en vivo si la UI escucha
        for seg in segments {
            onSegment?(TranscriptionService.LiveSegment(startTime: seg.startTime, endTime: seg.endTime, text: seg.text))
        }

        // Diarización de hablantes si se ha solicitado
        var speakerError: String? = nil
        if settings.enableDiarization {
            onPhase?(.detectingSpeakers(fraction: nil))
            onProgress(0.88, "Identificando hablantes…")
            do {
                let turns = try await SpeakerDiarizationService.shared.diarize(file: processedFile) { p in
                    if case .analysing(let frac) = p, let f = frac {
                        onProgress(0.88 + f * 0.10, "Analizando hablantes…")
                    }
                }
                segments = SpeakerAssignment.assign(segments, turns: turns)
            } catch {
                speakerError = error.localizedDescription
                AppLogger.shared.logError(error, context: "Parakeet diarization failed", category: .transcription)
            }
        }

        onProgress(1.0, "Completado")

        var result = TranscriptionResult(segments: segments, showTimestamps: true)
        result.speakerDetectionError = speakerError
        return result
    }

    // MARK: - Construcción de segmentos

    private func buildSegments(from asrResult: ASRResult) -> [TranscriptionSegment] {
        let rawTimings = asrResult.tokenTimings ?? []
        let wordTimings = buildWordTimings(from: rawTimings)

        guard !wordTimings.isEmpty else {
            // Sin timestamps por palabra: generamos un único segmento con la duración completa
            let trimmed = asrResult.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return [] }
            return [
                TranscriptionSegment(
                    startTime: 0,
                    endTime: max(0.1, asrResult.duration),
                    text: trimmed,
                    words: nil
                )
            ]
        }

        // Agrupación en frases según puntuación (. ? !) o pausas de más de 1.2 segundos
        var segments: [TranscriptionSegment] = []
        var currentWords: [TranscriptionSegment.WordTimestamp] = []
        var currentTokens: [String] = []

        let sentenceTerminators: Set<Character> = [".", "?", "!", ";"]

        for w in wordTimings {
            let wordText = w.word.trimmingCharacters(in: .whitespaces)
            guard !wordText.isEmpty else { continue }

            // Si hay un silencio largo respecto al final de la palabra anterior, cerramos segmento
            if let lastEnd = currentWords.last?.end, (w.startTime - lastEnd) > 1.2, !currentWords.isEmpty {
                let segText = currentTokens.joined(separator: " ")
                segments.append(TranscriptionSegment(
                    startTime: currentWords.first?.start ?? 0,
                    endTime: currentWords.last?.end ?? w.startTime,
                    text: segText,
                    words: currentWords
                ))
                currentWords = []
                currentTokens = []
            }

            let wordTimestamp = TranscriptionSegment.WordTimestamp(
                start: w.startTime,
                end: w.endTime,
                text: " " + wordText
            )
            currentWords.append(wordTimestamp)
            currentTokens.append(wordText)

            // Si la palabra termina en punto, cierre de interrogación o exclamación, cerramos frase
            if let lastChar = wordText.last, sentenceTerminators.contains(lastChar), currentWords.count >= 3 {
                let segText = currentTokens.joined(separator: " ")
                segments.append(TranscriptionSegment(
                    startTime: currentWords.first?.start ?? 0,
                    endTime: currentWords.last?.end ?? w.endTime,
                    text: segText,
                    words: currentWords
                ))
                currentWords = []
                currentTokens = []
            }
        }

        // Segmento final sobrante
        if !currentWords.isEmpty {
            let segText = currentTokens.joined(separator: " ")
            segments.append(TranscriptionSegment(
                startTime: currentWords.first?.start ?? 0,
                endTime: currentWords.last?.end ?? asrResult.duration,
                text: segText,
                words: currentWords
            ))
        }

        return segments
    }

    // MARK: - Liberación de recursos

    func cleanup() async {
        await currentManager?.cleanup()
        currentManager = nil
        currentModels = nil
        currentVersion = nil
    }
}
