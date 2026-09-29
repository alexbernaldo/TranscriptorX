import Foundation

/// Audio preprocessing pipeline for transcription
/// Handles conversion, noise reduction, voice isolation, and normalization
///
/// Pipeline de procesamiento:
/// 1. Conversión a WAV (siempre)
/// 2. DeepFilterNet - reducción de ruido (opcional)
/// 3. HTDemucs - aislamiento de voz (opcional)
/// 4. EBU R128 - normalización (opcional)
///
class AudioPreprocessor {
    
    // MARK: - Singleton
    static let shared = AudioPreprocessor()
    
    // MARK: - Audio Engine
    private let audioEngine = AudioEngineManager.shared
    
    // MARK: - Cancellation Support
    private var isCancelled = false
    private var activeProcess: Process?
    
    // MARK: - Paths
    private var ffmpegPath: String {
        // Try common locations
        let paths = [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/usr/bin/ffmpeg"
        ]
        return paths.first { FileManager.default.fileExists(atPath: $0) } ?? "ffmpeg"
    }
    
    // MARK: - Preprocessing Options
    struct Options {
        var isolateVoice: Bool = false    // HTDemucs - voice separation
        var denoise: Bool = false         // DeepFilterNet - noise reduction
        var normalize: Bool = false       // EBU R128 normalization
        var useVAD: Bool = false          // Voice Activity Detection for segmentation
        
        static let `default` = Options()
    }
    
    // MARK: - Status
    
    /// Verifica qué procesadores avanzados están disponibles
    var advancedProcessorsAvailable: AudioEngineManager.AvailableProcessors {
        audioEngine.availableProcessors
    }
    
    // MARK: - Cancellation
    
    /// Cancel any ongoing preprocessing
    func cancel() {
        isCancelled = true
        activeProcess?.terminate()
        activeProcess = nil
        AppLogger.shared.log("AudioPreprocessor cancelled", category: .transcription)
    }
    
    /// Reset cancellation state for new processing
    func resetCancellation() {
        isCancelled = false
        activeProcess = nil
    }
    
    // MARK: - Progress Callback
    typealias ProgressCallback = (Double, String) -> Void
    
    // MARK: - Main Pipeline
    
    /// Process audio file through the preprocessing pipeline
    /// - Parameters:
    ///   - inputFile: Original audio file (any format)
    ///   - options: Preprocessing options selected by user
    ///   - onProgress: Progress callback (0.0-1.0, status message)
    /// - Returns: URL to the processed WAV file ready for Whisper
    func process(
        inputFile: URL,
        options: Options,
        onProgress: @escaping ProgressCallback
    ) async throws -> URL {
        
        let processId = UUID().uuidString.prefix(8)
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcriptor_\(processId)")
        
        // Create temp directory
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        print("DEBUG AudioPreprocessor: Starting pipeline for \(inputFile.lastPathComponent)")
        print("DEBUG AudioPreprocessor: Temp directory: \(tempDir.path)")
        print("DEBUG AudioPreprocessor: Options - isolateVoice: \(options.isolateVoice), denoise: \(options.denoise), normalize: \(options.normalize), useVAD: \(options.useVAD)")
        
        var currentFile = inputFile
        var stepProgress: Double = 0
        let totalSteps = calculateTotalSteps(options: options)
        var currentStep = 0
        
        // Helper to update progress
        func updateProgress(_ message: String) {
            currentStep += 1
            stepProgress = Double(currentStep) / Double(totalSteps)
            DispatchQueue.main.async {
                onProgress(stepProgress * 0.3, message) // Pre-processing is 30% of total
            }
        }
        
        // STEP 1: Convert to WAV (Always required)
        onProgress(0.05, "Convirtiendo audio...")
        let baseWav = tempDir.appendingPathComponent("temp_base.wav")
        try await convertToWav(input: currentFile, output: baseWav)
        currentFile = baseWav
        updateProgress("Audio convertido")
        
        // STEP 2: Advanced Audio Processing (DeepFilter + HTDemucs)
        if options.denoise || options.isolateVoice {
            // Inicializar AudioEngine si es necesario
            if !audioEngine.isInitialized {
                do {
                    try await audioEngine.initialize()
                } catch {
                    print("DEBUG AudioPreprocessor: AudioEngine initialization failed: \(error.localizedDescription)")
                }
            }
            
            // Procesar con AudioEngine
            do {
                currentFile = try await audioEngine.processForTranscription(
                    currentFile,
                    reduceNoise: options.denoise,
                    isolateVoice: options.isolateVoice
                ) { progress, status in
                    DispatchQueue.main.async {
                        onProgress(0.05 + progress * 0.2, status)
                    }
                }
                
                if options.denoise {
                    updateProgress("Ruido eliminado")
                }
                if options.isolateVoice {
                    updateProgress("Voz aislada")
                }
            } catch {
                print("DEBUG AudioPreprocessor: Advanced processing failed: \(error.localizedDescription)")
                // Continue with original audio if processing fails
            }
        }
        
        // STEP 3: Normalization (EBU R128) - Optional
        if options.normalize {
            onProgress(stepProgress * 0.3, "Normalizando volumen...")
            let normalizedWav = tempDir.appendingPathComponent("temp_normalized.wav")
            try await normalizeAudio(input: currentFile, output: normalizedWav)
            currentFile = normalizedWav
            updateProgress("Audio normalizado")
        }
        
        print("DEBUG AudioPreprocessor: Pipeline complete, output: \(currentFile.path)")
        onProgress(0.3, "Preprocesamiento completado")
        
        return currentFile
    }
    
    // MARK: - Cleanup
    
    /// Clean up temporary files after transcription
    func cleanup(tempDir: URL) {
        do {
            if tempDir.path.contains("transcriptor_") {
                try FileManager.default.removeItem(at: tempDir)
                print("DEBUG AudioPreprocessor: Cleaned up \(tempDir.path)")
            }
        } catch {
            print("DEBUG AudioPreprocessor: Cleanup failed: \(error.localizedDescription)")
        }
    }
    
    /// Clean up all transcriptor temp files
    func cleanupAll() {
        let tempDir = FileManager.default.temporaryDirectory
        do {
            let contents = try FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
            for item in contents where item.lastPathComponent.hasPrefix("transcriptor_") {
                try FileManager.default.removeItem(at: item)
            }
            print("DEBUG AudioPreprocessor: Cleaned up all temp files")
        } catch {
            print("DEBUG AudioPreprocessor: Cleanup all failed: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Private Methods
    
    private func calculateTotalSteps(options: Options) -> Int {
        var steps = 1 // Base conversion is always required
        if options.isolateVoice { steps += 1 }
        if options.denoise { steps += 1 }
        if options.normalize { steps += 1 }
        return steps
    }
    
    /// Convert any audio format to WAV (16kHz, Mono, PCM)
    private func convertToWav(input: URL, output: URL) async throws {
        if isCancelled {
            throw PreprocessorError.cancelled
        }
        print("DEBUG AudioPreprocessor: Converting \(input.path) to WAV")
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        
        // FFmpeg arguments for Whisper-compatible WAV:
        // -i: input file
        // -ar 16000: 16kHz sample rate (Whisper requirement)
        // -ac 1: mono channel
        // -c:a pcm_s16le: 16-bit PCM encoding
        // -y: overwrite output
        process.arguments = [
            "-i", input.path,
            "-ar", "16000",
            "-ac", "1",
            "-c:a", "pcm_s16le",
            "-y",
            output.path
        ]
        
        // Set environment
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        process.environment = env
        
        // Capture output
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = FileHandle.nullDevice
        
        activeProcess = process
        defer {
            if activeProcess === process {
                activeProcess = nil
            }
        }

        try process.run()
        process.waitUntilExit()
        
        if process.terminationStatus != 0 {
            if isCancelled || process.terminationStatus == 15 {
                throw PreprocessorError.cancelled
            }
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            print("DEBUG AudioPreprocessor: FFmpeg error: \(errorMessage)")
            throw PreprocessorError.conversionFailed(errorMessage)
        }
        
        // Verify output exists
        guard FileManager.default.fileExists(atPath: output.path) else {
            throw PreprocessorError.outputNotFound
        }
        
        print("DEBUG AudioPreprocessor: Conversion successful: \(output.path)")
    }
    
    /// Normalize audio using FFmpeg's loudnorm filter (EBU R128)
    private func normalizeAudio(input: URL, output: URL) async throws {
        if isCancelled {
            throw PreprocessorError.cancelled
        }
        print("DEBUG AudioPreprocessor: Normalizing \(input.path)")
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        
        // Two-pass loudnorm for EBU R128 compliance
        // Target: -16 LUFS (good for speech)
        process.arguments = [
            "-i", input.path,
            "-af", "loudnorm=I=-16:TP=-1.5:LRA=11",
            "-ar", "16000",
            "-ac", "1",
            "-c:a", "pcm_s16le",
            "-y",
            output.path
        ]
        
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        process.environment = env
        
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = FileHandle.nullDevice
        
        activeProcess = process
        defer {
            if activeProcess === process {
                activeProcess = nil
            }
        }

        try process.run()
        process.waitUntilExit()
        
        if process.terminationStatus != 0 {
            if isCancelled || process.terminationStatus == 15 {
                throw PreprocessorError.cancelled
            }
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            print("DEBUG AudioPreprocessor: Normalization error: \(errorMessage)")
            throw PreprocessorError.normalizationFailed(errorMessage)
        }
        
        print("DEBUG AudioPreprocessor: Normalization successful: \(output.path)")
    }
}

// MARK: - Errors

enum PreprocessorError: LocalizedError {
    case conversionFailed(String)
    case normalizationFailed(String)
    case voiceIsolationFailed(String)
    case denoiserFailed(String)
    case outputNotFound
    case ffmpegNotFound
    case cancelled

    private var isSpanishUI: Bool {
        UserDefaults.standard.string(forKey: "app_ui_language") == "es"
    }

    private func localized(_ spanish: String, _ english: String) -> String {
        isSpanishUI ? spanish : english
    }
    
    var errorDescription: String? {
        switch self {
        case .conversionFailed(let msg):
            return localized("Error al convertir audio: \(msg)", "Audio conversion failed: \(msg)")
        case .normalizationFailed(let msg):
            return localized("Error al normalizar audio: \(msg)", "Audio normalization failed: \(msg)")
        case .voiceIsolationFailed(let msg):
            return localized("Error al aislar voz: \(msg)", "Voice isolation failed: \(msg)")
        case .denoiserFailed(let msg):
            return localized("Error al eliminar ruido: \(msg)", "Noise reduction failed: \(msg)")
        case .outputNotFound:
            return localized("No se generó el archivo de salida", "No output file was generated")
        case .ffmpegNotFound:
            return localized("FFmpeg no encontrado", "FFmpeg not found")
        case .cancelled:
            return localized("Preprocesamiento cancelado", "Preprocessing cancelled")
        }
    }
}
