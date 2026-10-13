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

    private var currentModelId: String?
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

    // MARK: - Descarga y verificación

    func isDownloaded(modelId: String, chunkMs: Int = 2240) -> Bool {
        return ModelStorageService.shared.isDownloaded(modelId)
    }

    func download(
        modelId: String,
        chunkMs: Int = 2240,
        language: String = "auto",
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try Self.checkPlatformSupport()

        let progressHandler: ProgressHandler = { p in
            progress(p.fractionCompleted)
        }

        switch modelId {
        case "nemotron-streaming-multilingual-0.6b":
            _ = try await StreamingNemotronMultilingualAsrManager.downloadVariant(
                languageCode: language,
                chunkMs: chunkMs,
                progressHandler: progressHandler
            )
        case "nemotron-streaming-en-0.6b":
            let manager = StreamingNemotronAsrManager(
                requestedChunkSize: chunkMs == 560 ? .ms560 : (chunkMs == 1120 ? .ms1120 : .ms2240)
            )
            try await manager.loadModels(progressHandler: progressHandler)
        default:
            throw NemotronError.unsupportedModel(modelId)
        }

        ModelStorageService.shared.notifyChanged()
    }

    // MARK: - Carga de modelos

    private func loadMultilingual(
        language: String = "auto",
        chunkMs: Int = 2240,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> StreamingNemotronMultilingualAsrManager {
        if let current = currentMultilingualManager, currentModelId == "nemotron-streaming-multilingual-0.6b" {
            await current.setLanguage(language)
            return current
        }

        try Self.checkPlatformSupport()

        let progressHandler: ProgressHandler? = progress.map { cb in
            { @Sendable p in cb(p.fractionCompleted) }
        }

        let variantDir = try await StreamingNemotronMultilingualAsrManager.downloadVariant(
            languageCode: language,
            chunkMs: chunkMs,
            progressHandler: progressHandler
        )

        let manager = StreamingNemotronMultilingualAsrManager()
        try await manager.loadModels(from: variantDir)
        await manager.setLanguage(language)

        self.currentModelId = "nemotron-streaming-multilingual-0.6b"
        self.currentMultilingualManager = manager
        self.currentEnglishManager = nil

        return manager
    }

    private func loadEnglish(
        chunkMs: Int = 2240,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> StreamingNemotronAsrManager {
        if let current = currentEnglishManager, currentModelId == "nemotron-streaming-en-0.6b" {
            return current
        }

        try Self.checkPlatformSupport()

        let progressHandler: ProgressHandler? = progress.map { cb in
            { @Sendable p in cb(p.fractionCompleted) }
        }

        let manager = StreamingNemotronAsrManager(
            requestedChunkSize: chunkMs == 560 ? .ms560 : (chunkMs == 1120 ? .ms1120 : .ms2240)
        )
        try await manager.loadModels(progressHandler: progressHandler)

        self.currentModelId = "nemotron-streaming-en-0.6b"
        self.currentEnglishManager = manager
        self.currentMultilingualManager = nil

        return manager
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

        let isMultilingual = modelId == "nemotron-streaming-multilingual-0.6b"
        let audioFile = try AVAudioFile(forReading: processedFile)
        let sampleRate = audioFile.processingFormat.sampleRate
        let totalFrames = audioFile.length
        let totalDuration = Double(totalFrames) / sampleRate

        let converter = AudioConverter()
        let blockSeconds: Double = Double(chunkMs) / 1000.0 * 2.0 // Lote de lectura por trozos
        let blockFrames = AVAudioFrameCount(sampleRate * blockSeconds)

        var finalTranscript = ""
        var rawTimings: [TokenTiming] = []

        onPhase?(.transcribing)
        onProgress(0.25, "Transcribiendo en vivo…")

        if isMultilingual {
            let manager = try await loadMultilingual(
                language: settings.language.isEmpty ? "auto" : settings.language,
                chunkMs: chunkMs
            ) { fraction in
                onProgress(0.18 + fraction * 0.07, "Descargando componentes…")
            }

            while audioFile.framePosition < audioFile.length {
                let remaining = AVAudioFrameCount(audioFile.length - audioFile.framePosition)
                let thisFrames = min(blockFrames, remaining)
                guard let block = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: thisFrames) else {
                    break
                }
                try audioFile.read(into: block, frameCount: thisFrames)
                let blockSamples = try converter.resampleBuffer(block)
                let chunkText = try await manager.process(samples: blockSamples)

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
            let manager = try await loadEnglish(chunkMs: chunkMs) { fraction in
                onProgress(0.18 + fraction * 0.07, "Descargando componentes…")
            }

            while audioFile.framePosition < audioFile.length {
                let remaining = AVAudioFrameCount(audioFile.length - audioFile.framePosition)
                let thisFrames = min(blockFrames, remaining)
                guard let block = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: thisFrames) else {
                    break
                }
                try audioFile.read(into: block, frameCount: thisFrames)
                let chunkText = try await manager.process(audioBuffer: block)

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
        currentMultilingualManager = nil
        currentEnglishManager = nil
        currentModelId = nil
    }
}
