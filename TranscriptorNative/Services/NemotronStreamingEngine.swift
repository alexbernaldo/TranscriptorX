import Foundation
import AVFoundation
import CoreML
import FluidAudio

/// Motor de transcripción en tiempo real y streaming basado en NVIDIA Nemotron 0.6B sobre CoreML y Neural Engine vía FluidAudio.
actor NemotronStreamingEngine {
    static let shared = NemotronStreamingEngine()

    enum NemotronError: LocalizedError {
        case unsupportedModel(String)
        case unsupportedPlatform(String)
        case transcriptionFailed(String)
        case modelNotFound(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedModel(let id):
                return "Modelo Nemotron no admitido: \(id)"
            case .unsupportedPlatform(let reason):
                return reason
            case .transcriptionFailed(let detail):
                return "Fallo en la transcripción en tiempo real de Nemotron: \(detail)"
            case .modelNotFound(let id):
                return "El modelo \(id) no está descargado."
            }
        }
    }

    static let multilingualId = "nemotron-streaming-multilingual-0.6b"
    static let englishId = "nemotron-streaming-en-0.6b"

    private var currentModelId: String?
    private var currentChunkMs: Int?
    private var currentVariantDir: URL?
    private var currentMultilingualManager: StreamingNemotronMultilingualAsrManager?
    private var currentEnglishManager: StreamingNemotronAsrManager?

    private init() {
        Task { @MainActor in
            ModelMemoryManager.shared.registerUnloadHandler { [weak self] in
                await self?.cleanup()
            }
        }
    }

    // MARK: - Soporte de plataforma

    static func checkPlatformSupport() throws {
        guard SystemInfo.isAppleSilicon else {
            throw NemotronError.unsupportedPlatform(
                "Los modelos Nemotron en tiempo real requieren Apple Silicon (Neural Engine). Los Mac con Intel no son compatibles."
            )
        }
    }

    // MARK: - Variantes en disco

    /// Tramos que ofrece cada modelo (el inglés no tiene 4480 ms).
    static func supportedChunks(modelId: String) -> [Int] {
        modelId == englishId ? [560, 1120, 2240] : [560, 1120, 2240, 4480]
    }

    private static var modelsBaseDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FluidAudio/Models", isDirectory: true)
    }

    /// Carpetas posibles de un modelo y tramo en la caché de FluidAudio.
    /// Multilingüe: `nemotron-multilingual/{latin|multilingual}/<tramo>ms`; inglés: `nemotron-streaming/<tramo>ms`.
    static func variantDirectories(modelId: String, chunkMs: Int) -> [URL] {
        switch modelId {
        case multilingualId:
            let repo = modelsBaseDir.appendingPathComponent(Repo.nemotronMultilingual.folderName)
            return ["multilingual", "latin"].map { repo.appendingPathComponent("\($0)/\(chunkMs)ms") }
        case englishId:
            guard let size = NemotronChunkSize(rawValue: chunkMs) else { return [] }
            return [modelsBaseDir.appendingPathComponent(size.repo.folderName)]
        default:
            return []
        }
    }

    /// Variante descargada para el idioma (la de alfabeto latino, más ligera, si existe), o `nil`.
    static func installedVariant(modelId: String, chunkMs: Int, language: String? = nil) -> URL? {
        let fm = FileManager.default
        let candidates = variantDirectories(modelId: modelId, chunkMs: chunkMs).filter { dir in
            if modelId == englishId {
                return fm.fileExists(atPath: dir.appendingPathComponent("encoder/encoder_int8.mlmodelc").path)
                    && fm.fileExists(atPath: dir.appendingPathComponent(ModelNames.NemotronStreaming.tokenizer).path)
            }
            return fm.fileExists(atPath: dir.appendingPathComponent(ModelNames.NemotronMultilingualStreaming.metadata).path)
        }
        if let language, StreamingNemotronMultilingualAsrManager.languageDirectory(for: language) == "latin",
           let latin = candidates.first(where: { $0.path.contains("/latin/") }) {
            return latin
        }
        return candidates.first { !$0.path.contains("/latin/") } ?? (language == nil ? candidates.first : nil)
    }

    func isDownloaded(modelId: String, chunkMs: Int) -> Bool {
        Self.installedVariant(modelId: modelId, chunkMs: chunkMs) != nil
    }

    // MARK: - Descarga (solo por acción del usuario)

    /// Descarga el tramo elegido. El multilingüe baja la variante completa, que cubre sus 8 idiomas.
    func download(
        modelId: String,
        chunkMs: Int,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try Self.checkPlatformSupport()
        let progressHandler: ProgressHandler = { p in progress(p.fractionCompleted) }
        try await FluidNetworkGate.withUserDownload {
            switch modelId {
            case Self.multilingualId:
                _ = try await StreamingNemotronMultilingualAsrManager.downloadVariant(
                    languageCode: "auto", chunkMs: chunkMs, progressHandler: progressHandler)
            case Self.englishId:
                let size = NemotronChunkSize(rawValue: chunkMs) ?? .ms2240
                let manager = StreamingNemotronAsrManager(requestedChunkSize: size)
                try await manager.loadModels(progressHandler: progressHandler)
                await manager.cleanup()
            default:
                throw NemotronError.unsupportedModel(modelId)
            }
        }
        ModelStorageService.shared.notifyChanged()
    }

    // MARK: - Carga (nunca descarga)

    private func loadMultilingual(language: String, chunkMs: Int) async throws -> StreamingNemotronMultilingualAsrManager {
        try Self.checkPlatformSupport()
        guard let dir = Self.installedVariant(modelId: Self.multilingualId, chunkMs: chunkMs, language: language) else {
            throw NemotronError.modelNotFound(Self.multilingualId)
        }
        let hint = language == "auto" ? nil : language
        if let current = currentMultilingualManager, currentVariantDir == dir {
            await current.setLanguage(hint)
            return current
        }
        await cleanup()
        let manager = StreamingNemotronMultilingualAsrManager()
        try await manager.loadModels(from: dir)
        await manager.setLanguage(hint)
        currentModelId = Self.multilingualId
        currentChunkMs = chunkMs
        currentVariantDir = dir
        currentMultilingualManager = manager
        return manager
    }

    private func loadEnglish(chunkMs: Int) async throws -> StreamingNemotronAsrManager {
        try Self.checkPlatformSupport()
        guard let dir = Self.installedVariant(modelId: Self.englishId, chunkMs: chunkMs) else {
            throw NemotronError.modelNotFound(Self.englishId)
        }
        if let current = currentEnglishManager, currentVariantDir == dir { return current }
        await cleanup()
        let manager = StreamingNemotronAsrManager(requestedChunkSize: NemotronChunkSize(rawValue: chunkMs))
        try await manager.loadModels(from: dir)
        currentModelId = Self.englishId
        currentChunkMs = chunkMs
        currentVariantDir = dir
        currentEnglishManager = manager
        return manager
    }

    // MARK: - Sesión en vivo (grabación)

    private var liveModelId: String?

    /// Prepara una sesión en vivo. Lanza `modelNotFound` si el tramo elegido no está descargado.
    func startLiveSession(modelId: String, language: String, chunkMs: Int) async throws {
        await ModelMemoryManager.shared.notifyModelInUse(modelId)
        if modelId == Self.englishId {
            let m = try await loadEnglish(chunkMs: chunkMs)
            await m.reset()
        } else {
            let m = try await loadMultilingual(language: language, chunkMs: chunkMs)
            await m.reset()
        }
        liveModelId = modelId
    }

    /// Añade audio de la grabación y devuelve el texto acumulado de la sesión.
    func feed(_ buffer: AVAudioPCMBuffer) async throws -> String {
        guard let liveModelId else { return "" }
        await ModelMemoryManager.shared.notifyModelInUse(liveModelId)
        if liveModelId == Self.englishId, let m = currentEnglishManager {
            _ = try await m.process(audioBuffer: buffer)
            return await m.getPartialTranscript()
        } else if let m = currentMultilingualManager {
            _ = try await m.process(audioBuffer: buffer)
            return await m.getPartialTranscript()
        }
        return ""
    }

    /// Cierra la sesión y devuelve el texto final (el modelo sigue en memoria hasta que lo libere el gestor).
    func endLiveSession() async -> String {
        defer { liveModelId = nil }
        if liveModelId == Self.englishId, let m = currentEnglishManager {
            let partial = await m.getPartialTranscript()
            let text = (try? await m.finish()) ?? partial
            await m.reset()
            return text
        } else if liveModelId != nil, let m = currentMultilingualManager {
            let partial = await m.getPartialTranscript()
            let text = (try? await m.finish()) ?? partial
            await m.reset()
            return text
        }
        return ""
    }

    // MARK: - Transcripción

    func transcribe(
        file: URL,
        modelId: String,
        settings: TranscriptionSettings,
        preprocessOptions: AudioPreprocessor.Options = .default,
        chunkMs: Int = 2240,
        onProgress: @escaping (Double, String) -> Void,
        onSegment: ((TranscriptionService.LiveSegment) -> Void)? = nil,
        onPhase: ((JobPhase) -> Void)? = nil
    ) async throws -> TranscriptionResult {
        try Self.checkPlatformSupport()
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

        onPhase?(.loadingModel)
        onProgress(0.18, "Cargando motor Nemotron Streaming…")

        let isMultilingual = modelId == Self.multilingualId
        let audioFile = try AVAudioFile(forReading: processedFile)
        let sampleRate = audioFile.processingFormat.sampleRate
        let totalFrames = audioFile.length
        let totalDuration = Double(totalFrames) / sampleRate

        let converter = AudioConverter()
        let blockSeconds: Double = Double(chunkMs) / 1000.0 * 2.0 // Lote de lectura por trozos
        let blockFrames = AVAudioFrameCount(sampleRate * blockSeconds)

        var finalTranscript = ""
        var rawTimings: [TokenTiming] = []
        var emitted = ""
        /// Texto nuevo respecto a lo ya emitido (el gestor devuelve la transcripción acumulada).
        func delta(_ partial: String) -> String {
            defer { emitted = partial }
            guard partial.hasPrefix(emitted) else { return partial }
            return String(partial.dropFirst(emitted.count)).trimmingCharacters(in: .whitespaces)
        }

        onPhase?(.transcribing)
        onProgress(0.25, "Transcribiendo en vivo…")

        if isMultilingual {
            let manager = try await loadMultilingual(
                language: settings.language.isEmpty ? "auto" : settings.language,
                chunkMs: chunkMs
            )

            while audioFile.framePosition < audioFile.length {
                let remaining = AVAudioFrameCount(audioFile.length - audioFile.framePosition)
                let thisFrames = min(blockFrames, remaining)
                guard let block = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: thisFrames) else {
                    break
                }
                try audioFile.read(into: block, frameCount: thisFrames)
                let blockSamples = try converter.resampleBuffer(block)
                _ = try await manager.process(samples: blockSamples)
                let chunkText = delta(await manager.getPartialTranscript())

                let currentPos = Double(audioFile.framePosition) / sampleRate
                let fraction = totalDuration > 0 ? min(0.85, 0.25 + (currentPos / totalDuration) * 0.60) : 0.5
                onProgress(fraction, "Transcribiendo…")

                if !chunkText.isEmpty {
                    let seg = TranscriptionService.LiveSegment(
                        startTime: max(0, currentPos - blockSeconds),
                        endTime: currentPos,
                        text: chunkText
                    )
                    onSegment?(seg)
                    Task { @MainActor in
                        LiveCaptionCenter.shared.emitLiveSegment(chunkText)
                    }
                }
            }

            let finishResult = try await manager.finishWithTokenTimings()
            finalTranscript = finishResult.text
            rawTimings = finishResult.timings
            await manager.reset()

        } else {
            let manager = try await loadEnglish(chunkMs: chunkMs)

            while audioFile.framePosition < audioFile.length {
                let remaining = AVAudioFrameCount(audioFile.length - audioFile.framePosition)
                let thisFrames = min(blockFrames, remaining)
                guard let block = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: thisFrames) else {
                    break
                }
                try audioFile.read(into: block, frameCount: thisFrames)
                _ = try await manager.process(audioBuffer: block)
                let chunkText = delta(await manager.getPartialTranscript())

                let currentPos = Double(audioFile.framePosition) / sampleRate
                let fraction = totalDuration > 0 ? min(0.85, 0.25 + (currentPos / totalDuration) * 0.60) : 0.5
                onProgress(fraction, "Transcribiendo…")

                if !chunkText.isEmpty {
                    let seg = TranscriptionService.LiveSegment(
                        startTime: max(0, currentPos - blockSeconds),
                        endTime: currentPos,
                        text: chunkText
                    )
                    onSegment?(seg)
                    Task { @MainActor in
                        LiveCaptionCenter.shared.emitLiveSegment(chunkText)
                    }
                }
            }

            let finishResult = try await manager.finishWithTokenTimings()
            finalTranscript = finishResult.text
            rawTimings = finishResult.timings
            await manager.reset()
        }

        onProgress(0.86, "Procesando marcas de tiempo…")

        var segments = buildSegments(from: finalTranscript, timings: rawTimings, duration: totalDuration)

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
                AppLogger.shared.logError(error, context: "Nemotron diarization failed", category: .transcription)
            }
        }

        onProgress(1.0, "Completado")

        var result = TranscriptionResult(segments: segments, showTimestamps: true)
        result.speakerDetectionError = speakerError
        return result
    }

    // MARK: - Construcción de segmentos

    private func buildSegments(from text: String, timings: [TokenTiming], duration: Double) -> [TranscriptionSegment] {
        let wordTimings = buildWordTimings(from: timings)

        guard !wordTimings.isEmpty else {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return [] }
            return [
                TranscriptionSegment(
                    startTime: 0,
                    endTime: max(0.1, duration),
                    text: trimmed,
                    words: nil
                )
            ]
        }

        var segments: [TranscriptionSegment] = []
        var currentWords: [TranscriptionSegment.WordTimestamp] = []
        var currentTokens: [String] = []

        let sentenceTerminators: Set<Character> = [".", "?", "!", ";", "。"]

        for w in wordTimings {
            let wordText = w.word.trimmingCharacters(in: .whitespaces)
            guard !wordText.isEmpty else { continue }

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

        if !currentWords.isEmpty {
            let segText = currentTokens.joined(separator: " ")
            segments.append(TranscriptionSegment(
                startTime: currentWords.first?.start ?? 0,
                endTime: currentWords.last?.end ?? duration,
                text: segText,
                words: currentWords
            ))
        }

        return segments
    }

    // MARK: - Liberación de recursos

    func cleanup() async {
        await currentMultilingualManager?.cleanup()
        await currentEnglishManager?.cleanup()
        currentMultilingualManager = nil
        currentEnglishManager = nil
        currentModelId = nil
        currentChunkMs = nil
        currentVariantDir = nil
        liveModelId = nil
    }
}
