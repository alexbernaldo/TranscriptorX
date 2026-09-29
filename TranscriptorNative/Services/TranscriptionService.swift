import Foundation
import Combine

/// Native transcription service using whisper.cpp directly
/// 
/// IMPORTANT: For CoreML support, whisper.cpp must be compiled with:
///   cmake -B build -DWHISPER_COREML=1
///   cmake --build build --config Release
///
/// The CoreML encoder files (.mlmodelc folders) are auto-detected by whisper.cpp
/// when placed alongside the model file with the naming convention:
///   ggml-{model}-encoder.mlmodelc
class TranscriptionService: NSObject, ObservableObject {
    static let shared = TranscriptionService()
    
    // Paths
    private let appSupportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Transcriptor")
    
    private var whisperCliPath: URL {
        appSupportDir.appendingPathComponent("whisper.cpp/build/bin/whisper-cli")
    }
    
    private var modelsDir: URL {
        appSupportDir.appendingPathComponent("whisper.cpp/models")
    }
    
    private var vadModelPath: URL {
        modelsDir.appendingPathComponent("ggml-silero-v6.2.0.bin")
    }
    
    private let vadModelDownloadURL = "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v6.2.0.bin"
    
    // Active process for cancellation
    private var activeProcess: Process?
    private let processQueue = DispatchQueue(label: "transcription.process")
    
    @Published var isTranscribing = false
    @Published var progress: Double = 0 // 0.0 to 1.0
    @Published var currentStatus: String = ""
    
    // Download state
    private var downloadProgress: ((Double) -> Void)?
    private var downloadContinuation: CheckedContinuation<URL, Error>?
    private var downloadDestination: URL?
    
    // URLSession for downloads - will be set up with self as delegate
    private var downloadSession: URLSession!
    
    private override init() {
        super.init()
        // Create session with self as delegate
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 14400 // 4 hours for large models
        config.waitsForConnectivity = true
        downloadSession = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        
        // Create models directory if needed
        try? FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
    }
    
    // MARK: - Available Models
    
    struct WhisperModel: Identifiable {
        let id: String
        let name: String
        let filename: String
        let downloadURL: String
        let size: String
        let coreMLSupported: Bool
        let coreMLSize: String?
        
        /// CoreML encoder folder name (e.g., "ggml-base-encoder.mlmodelc")
        var coreMLFolderName: String {
            let baseName = filename.replacingOccurrences(of: ".bin", with: "")
            return "\(baseName)-encoder.mlmodelc"
        }
        
        /// CoreML download URL
        var coreMLDownloadURL: String {
            "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(coreMLFolderName).zip"
        }
        
        var isDownloaded: Bool {
            let path = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Transcriptor/whisper.cpp/models/\(filename)")
            return FileManager.default.fileExists(atPath: path.path)
        }
    }
    
    static let availableModels: [WhisperModel] = [
        WhisperModel(
            id: "tiny",
            name: "Ultra Rápido",
            filename: "ggml-tiny.bin",
            downloadURL: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.bin",
            size: "75 MB",
            coreMLSupported: true,
            coreMLSize: "24 MB"
        ),
        WhisperModel(
            id: "base",
            name: "Rápido",
            filename: "ggml-base.bin",
            downloadURL: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin",
            size: "142 MB",
            coreMLSupported: true,
            coreMLSize: "43 MB"
        ),
        WhisperModel(
            id: "small",
            name: "Equilibrado",
            filename: "ggml-small.bin",
            downloadURL: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin",
            size: "466 MB",
            coreMLSupported: true,
            coreMLSize: "134 MB"
        ),
        WhisperModel(
            id: "medium",
            name: "Preciso",
            filename: "ggml-medium.bin",
            downloadURL: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium.bin",
            size: "1.5 GB",
            coreMLSupported: true,
            coreMLSize: "391 MB"
        ),
        WhisperModel(
            id: "large-v3-turbo",
            name: "Profesional",
            filename: "ggml-large-v3-turbo.bin",
            downloadURL: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin",
            size: "1.6 GB",
            coreMLSupported: true,
            coreMLSize: "475 MB"
        ),
        WhisperModel(
            id: "large-v2",
            name: "Large V2",
            filename: "ggml-large-v2.bin",
            downloadURL: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v2.bin",
            size: "2.9 GB",
            coreMLSupported: true,
            coreMLSize: "636 MB"
        ),
        WhisperModel(
            id: "large-v3",
            name: "Máxima Calidad",
            filename: "ggml-large-v3.bin",
            downloadURL: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3.bin",
            size: "2.9 GB",
            coreMLSupported: true,
            coreMLSize: "636 MB"
        )
    ]
    
    // MARK: - Model Management
    
    func getModelPath(for modelId: String) -> URL? {
        guard let model = Self.availableModels.first(where: { $0.id == modelId }) else {
            return nil
        }
        return modelsDir.appendingPathComponent(model.filename)
    }
    
    func isModelDownloaded(_ modelId: String) -> Bool {
        guard let path = getModelPath(for: modelId) else {
            print("DEBUG: isModelDownloaded - model '\(modelId)' not found in available models")
            return false
        }
        let exists = FileManager.default.fileExists(atPath: path.path)
        print("DEBUG: isModelDownloaded - model '\(modelId)' at \(path.path) exists: \(exists)")
        return exists
    }
    
    func downloadModel(_ modelId: String, progress: @escaping (Double) -> Void) async throws {
        guard let model = Self.availableModels.first(where: { $0.id == modelId }) else {
            throw TranscriptionError.modelNotFound
        }
        
        guard let url = URL(string: model.downloadURL) else {
            throw TranscriptionError.invalidURL
        }
        
        // Ensure models directory exists
        try? FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        
        let destinationPath = modelsDir.appendingPathComponent(model.filename)
        
        // If already exists, return
        if FileManager.default.fileExists(atPath: destinationPath.path) {
            progress(1.0)
            return
        }
        
        // Store progress callback and destination
        self.downloadProgress = progress
        self.downloadDestination = destinationPath
        
        // Use continuation for async/await with delegate
        let tempURL: URL = try await withCheckedThrowingContinuation { continuation in
            self.downloadContinuation = continuation
            let request = URLRequest(url: url)
            let task = downloadSession.downloadTask(with: request)
            task.resume()
            
            print("DEBUG: Started download for \(model.filename) from \(url)")
        }
        
        // Move file to final destination
        if FileManager.default.fileExists(atPath: destinationPath.path) {
            try FileManager.default.removeItem(at: destinationPath)
        }
        
        try FileManager.default.moveItem(at: tempURL, to: destinationPath)
        print("DEBUG: Model saved to \(destinationPath.path)")
        
        // Ensure final progress 100%
        DispatchQueue.main.async {
            progress(1.0)
        }
        
        // Cleanup
        self.downloadProgress = nil
        self.downloadContinuation = nil
        self.downloadDestination = nil
    }
    
    // MARK: - CoreML Management
    
    /// Check if a model supports CoreML acceleration
    func isCoreMLSupported(for modelId: String) -> Bool {
        guard let model = Self.availableModels.first(where: { $0.id == modelId }) else {
            return false
        }
        return model.coreMLSupported
    }
    
    /// Get CoreML encoder folder path (active state)
    private func coreMLPath(for modelId: String) -> URL? {
        guard let model = Self.availableModels.first(where: { $0.id == modelId }) else {
            return nil
        }
        return modelsDir.appendingPathComponent(model.coreMLFolderName)
    }
    
    /// Get CoreML encoder folder path (disabled state with .off suffix)
    private func coreMLDisabledPath(for modelId: String) -> URL? {
        guard let model = Self.availableModels.first(where: { $0.id == modelId }) else {
            return nil
        }
        return modelsDir.appendingPathComponent(model.coreMLFolderName + ".off")
    }
    
    /// Check CoreML status for a model
    enum CoreMLStatus {
        case notSupported           // Model doesn't support CoreML
        case notDownloaded          // CoreML not downloaded yet
        case ready                  // CoreML downloaded and active
        case disabled               // CoreML downloaded but renamed to .off
    }
    
    func getCoreMLStatus(for modelId: String) -> CoreMLStatus {
        guard let model = Self.availableModels.first(where: { $0.id == modelId }) else {
            return .notSupported
        }
        
        guard model.coreMLSupported else {
            return .notSupported
        }
        
        guard let activePath = coreMLPath(for: modelId),
              let disabledPath = coreMLDisabledPath(for: modelId) else {
            return .notSupported
        }
        
        if FileManager.default.fileExists(atPath: activePath.path) {
            return .ready
        } else if FileManager.default.fileExists(atPath: disabledPath.path) {
            return .disabled
        } else {
            return .notDownloaded
        }
    }
    
    /// Get CoreML size for display
    func getCoreMLSize(for modelId: String) -> String? {
        guard let model = Self.availableModels.first(where: { $0.id == modelId }) else {
            return nil
        }
        return model.coreMLSize
    }
    
    /// Enable CoreML by renaming .off folder back to original name
    func enableCoreML(for modelId: String) throws {
        guard let activePath = coreMLPath(for: modelId),
              let disabledPath = coreMLDisabledPath(for: modelId) else {
            return
        }
        
        if FileManager.default.fileExists(atPath: disabledPath.path) {
            try FileManager.default.moveItem(at: disabledPath, to: activePath)
            print("DEBUG: CoreML enabled for \(modelId)")
        }
    }
    
    /// Disable CoreML by renaming folder to .off (whisper.cpp won't find it)
    func disableCoreML(for modelId: String) throws {
        guard let activePath = coreMLPath(for: modelId),
              let disabledPath = coreMLDisabledPath(for: modelId) else {
            return
        }
        
        if FileManager.default.fileExists(atPath: activePath.path) {
            // Remove disabled path if exists
            if FileManager.default.fileExists(atPath: disabledPath.path) {
                try FileManager.default.removeItem(at: disabledPath)
            }
            try FileManager.default.moveItem(at: activePath, to: disabledPath)
            print("DEBUG: CoreML disabled for \(modelId)")
        }
    }
    
    /// Download CoreML encoder for a model
    func downloadCoreML(for modelId: String, progress: @escaping (Double) -> Void) async throws {
        guard let model = Self.availableModels.first(where: { $0.id == modelId }),
              model.coreMLSupported else {
            throw TranscriptionError.coreMLNotSupported
        }
        
        guard let downloadURL = URL(string: model.coreMLDownloadURL) else {
            throw TranscriptionError.invalidURL
        }
        
        let destinationPath = modelsDir.appendingPathComponent(model.coreMLFolderName)
        
        // If already exists (active or disabled), just ensure it's active
        if FileManager.default.fileExists(atPath: destinationPath.path) {
            progress(1.0)
            return
        }
        
        // Check if disabled version exists
        let disabledPath = modelsDir.appendingPathComponent(model.coreMLFolderName + ".off")
        if FileManager.default.fileExists(atPath: disabledPath.path) {
            try FileManager.default.moveItem(at: disabledPath, to: destinationPath)
            progress(1.0)
            return
        }
        
        print("DEBUG: Downloading CoreML encoder from \(downloadURL)")
        
        // Store progress callback
        self.downloadProgress = progress
        
        // Download ZIP file
        let zipURL: URL = try await withCheckedThrowingContinuation { continuation in
            self.downloadContinuation = continuation
            let request = URLRequest(url: downloadURL)
            let task = downloadSession.downloadTask(with: request)
            task.resume()
        }
        
        print("DEBUG: CoreML ZIP downloaded to \(zipURL.path)")
        
        // Unzip to models directory
        try await unzipCoreML(zipURL: zipURL, destinationFolder: destinationPath)
        
        // Clean up ZIP
        try? FileManager.default.removeItem(at: zipURL)
        
        DispatchQueue.main.async {
            progress(1.0)
        }
        
        self.downloadProgress = nil
        self.downloadContinuation = nil
        
        print("DEBUG: CoreML encoder ready at \(destinationPath.path)")
    }
    
    /// Unzip CoreML encoder
    private func unzipCoreML(zipURL: URL, destinationFolder: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    // Create destination if needed
                    try FileManager.default.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
                    
                    // Use ditto to unzip (better for macOS bundles)
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                    process.arguments = ["-xk", zipURL.path, self.modelsDir.path]
                    
                    try process.run()
                    process.waitUntilExit()
                    
                    if process.terminationStatus == 0 {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: TranscriptionError.coreMLUnzipFailed)
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    /// Ensure CoreML is ready before transcription (JIT download)
    /// Returns true if CoreML is ready to use, false if fallback needed
    func ensureCoreMLReady(
        for modelId: String,
        enabled: Bool,
        onProgress: @escaping (Double, String) -> Void
    ) async -> Bool {
        guard enabled else { return false }
        
        let status = getCoreMLStatus(for: modelId)
        
        switch status {
        case .notSupported:
            return false
            
        case .ready:
            return true
            
        case .disabled:
            // Re-enable by renaming
            do {
                try enableCoreML(for: modelId)
                return true
            } catch {
                print("DEBUG: Failed to enable CoreML: \(error)")
                return false
            }
            
        case .notDownloaded:
            // JIT download
            do {
                onProgress(0, "Optimizando motor de IA...")
                try await downloadCoreML(for: modelId) { progress in
                    DispatchQueue.main.async {
                        onProgress(progress * 0.15, "Descargando acelerador Neural...")
                    }
                }
                return true
            } catch {
                print("DEBUG: CoreML download failed, using fallback: \(error)")
                DispatchQueue.main.async {
                    onProgress(0, "Usando modo estándar...")
                }
                return false
            }
        }
    }

    // MARK: - VAD Model Management
    
    /// Check if the Silero VAD model is downloaded
    func isVADModelDownloaded() -> Bool {
        FileManager.default.fileExists(atPath: vadModelPath.path)
    }
    
    /// Download the Silero VAD model for voice activity detection
    func downloadVADModel(progress: @escaping (Double) -> Void) async throws {
        // If already exists, return
        if isVADModelDownloaded() {
            progress(1.0)
            return
        }
        
        guard let url = URL(string: vadModelDownloadURL) else {
            throw TranscriptionError.invalidURL
        }
        
        // Ensure models directory exists
        try? FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        
        // Store progress callback and destination
        self.downloadProgress = progress
        self.downloadDestination = vadModelPath
        
        // Use continuation for async/await with delegate
        let tempURL: URL = try await withCheckedThrowingContinuation { continuation in
            self.downloadContinuation = continuation
            let request = URLRequest(url: url)
            let task = downloadSession.downloadTask(with: request)
            task.resume()
            
            print("DEBUG: Started VAD model download from \(url)")
        }
        
        // Move file to final destination
        if FileManager.default.fileExists(atPath: vadModelPath.path) {
            try FileManager.default.removeItem(at: vadModelPath)
        }
        
        try FileManager.default.moveItem(at: tempURL, to: vadModelPath)
        print("DEBUG: VAD model saved to \(vadModelPath.path)")
        
        // Ensure final progress 100%
        DispatchQueue.main.async {
            progress(1.0)
        }
        
        // Cleanup
        self.downloadProgress = nil
        self.downloadContinuation = nil
        self.downloadDestination = nil
    }
    
    /// Ensure VAD model is ready before transcription (JIT download)
    /// Returns true if VAD model is ready, false if unavailable
    func ensureVADModelReady(
        onProgress: @escaping (Double, String) -> Void
    ) async -> Bool {
        if isVADModelDownloaded() {
            return true
        }
        
        // JIT download
        do {
            onProgress(0, "Descargando modelo VAD...")
            try await downloadVADModel { progress in
                DispatchQueue.main.async {
                    onProgress(progress * 0.05, "Descargando detector de voz...")
                }
            }
            print("DEBUG: VAD model downloaded successfully")
            return true
        } catch {
            print("DEBUG: VAD model download failed: \(error)")
            DispatchQueue.main.async {
                onProgress(0, "VAD no disponible, continuando sin detección de voz...")
            }
            return false
        }
    }

    // MARK: - Segment Streaming
    
    /// Represents a live segment from whisper-cli stdout
    struct LiveSegment {
        let startTime: TimeInterval
        let endTime: TimeInterval
        let text: String
    }
    
    /// Parse a single line from whisper-cli stdout into a LiveSegment
    /// Format: "[00:00:00.000 --> 00:00:02.500]  Hello world"
    private func parseLiveSegment(_ line: String) -> LiveSegment? {
        // Match pattern: [HH:MM:SS.mmm --> HH:MM:SS.mmm]  text
        let pattern = #"\[(\d{2}:\d{2}:\d{2}\.\d{3})\s*-->\s*(\d{2}:\d{2}:\d{2}\.\d{3})\]\s*(.+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              match.numberOfRanges >= 4 else {
            return nil
        }
        
        guard let startRange = Range(match.range(at: 1), in: line),
              let endRange = Range(match.range(at: 2), in: line),
              let textRange = Range(match.range(at: 3), in: line) else {
            return nil
        }
        
        let startTime = parseTimestampLive(String(line[startRange]))
        let endTime = parseTimestampLive(String(line[endRange]))
        let text = String(line[textRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        
        return LiveSegment(startTime: startTime, endTime: endTime, text: text)
    }
    
    /// Parse timestamp format "HH:MM:SS.mmm" to TimeInterval
    private func parseTimestampLive(_ timestamp: String) -> TimeInterval {
        let parts = timestamp.split(separator: ":")
        guard parts.count == 3 else { return 0 }
        
        let hours = Double(parts[0]) ?? 0
        let minutes = Double(parts[1]) ?? 0
        let secondsParts = parts[2].split(separator: ".")
        let seconds = Double(secondsParts[0]) ?? 0
        let milliseconds = secondsParts.count > 1 ? (Double(secondsParts[1]) ?? 0) / 1000.0 : 0
        
        return hours * 3600 + minutes * 60 + seconds + milliseconds
    }
    
    // MARK: - Transcription
    
    /// Full transcription pipeline with preprocessing - returns structured result
    /// - Parameters:
    ///   - onSegment: Called for each segment as it's transcribed (for live streaming)
    func transcribe(
        file: URL,
        modelId: String,
        settings: TranscriptionSettings,
        preprocessOptions: AudioPreprocessor.Options = .default,
        onProgress: @escaping (Double, String) -> Void,
        onSegment: ((LiveSegment) -> Void)? = nil
    ) async throws -> TranscriptionResult {
        
        guard let modelPath = getModelPath(for: modelId),
              FileManager.default.fileExists(atPath: modelPath.path) else {
            throw TranscriptionError.modelNotFound
        }
        
        guard FileManager.default.fileExists(atPath: whisperCliPath.path) else {
            throw TranscriptionError.whisperNotInstalled
        }
        
        // STEP 0a: Ensure VAD model is ready if VAD is enabled
        var effectiveUseVAD = settings.useVAD
        if settings.useVAD {
            let vadReady = await ensureVADModelReady(onProgress: onProgress)
            if !vadReady {
                print("DEBUG: VAD model not available, disabling VAD for this transcription")
                effectiveUseVAD = false
            }
        }
        
        // STEP 0b: Handle CoreML state
        // Ensure correct CoreML state based on user preference
        if settings.useCoreML && isCoreMLSupported(for: modelId) {
            // User wants CoreML - ensure it's ready (JIT download if needed)
            let coreMLReady = await ensureCoreMLReady(
                for: modelId,
                enabled: true,
                onProgress: onProgress
            )
            
            if !coreMLReady {
                // Failed to get CoreML ready, notify user
                DispatchQueue.main.async {
                    onProgress(0, "No se pudo optimizar, usando modo estándar...")
                }
            }
        } else if !settings.useCoreML {
            // User doesn't want CoreML - ensure it's disabled (rename to .off)
            do {
                try disableCoreML(for: modelId)
            } catch {
                print("DEBUG: Failed to disable CoreML: \(error)")
            }
        }
        
        // STEP 1: Preprocess audio (convert to WAV, apply filters)
        let preprocessor = AudioPreprocessor.shared
        preprocessor.resetCancellation()
        let processedFile: URL
        
        do {
            processedFile = try await preprocessor.process(
                inputFile: file,
                options: preprocessOptions,
                onProgress: { progress, status in
                    // Preprocessing is 0-30% of total progress
                    onProgress(progress, status)
                }
            )
        } catch {
            print("DEBUG: Preprocessing failed: " + error.localizedDescription)
            throw error
        }
        
        // STEP 2: Run Whisper transcription
        defer {
            // Cleanup temp files after transcription
            let tempDir = processedFile.deletingLastPathComponent()
            preprocessor.cleanup(tempDir: tempDir)
        }
        
        // Create effective settings with resolved VAD state
        var effectiveSettings = settings
        effectiveSettings.useVAD = effectiveUseVAD
        
        return try await runWhisperTranscription(
            file: processedFile,
            modelPath: modelPath,
            settings: effectiveSettings,
            onProgress: { progress, status in
                // Transcription is 30-100% of total progress
                let adjustedProgress = 0.3 + (progress * 0.7)
                onProgress(adjustedProgress, status)
            },
            onSegment: onSegment
        )
    }
    
    /// Legacy method that returns plain text (for backward compatibility)
    func transcribePlainText(
        file: URL,
        modelId: String,
        settings: TranscriptionSettings,
        preprocessOptions: AudioPreprocessor.Options = .default,
        onProgress: @escaping (Double, String) -> Void
    ) async throws -> String {
        let result = try await transcribe(
            file: file,
            modelId: modelId,
            settings: settings,
            preprocessOptions: preprocessOptions,
            onProgress: onProgress
        )
        return result.plainText
    }
    
    /// Detect language from audio file using whisper.cpp
    private func detectLanguage(
        file: URL,
        modelPath: URL
    ) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            processQueue.async { [weak self] in
                guard let self = self else {
                    continuation.resume(returning: "en")
                    return
                }
                
                print("DEBUG: Detecting language for file: \(file.lastPathComponent)")
                
                let process = Process()
                process.executableURL = self.whisperCliPath
                process.arguments = [
                    "-m", modelPath.path,
                    "-f", file.path,
                    "-l", "auto",
                    "--detect-language"
                ]
                
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")
                process.environment = env
                
                let outputPipe = Pipe()
                let errorPipe = Pipe()
                process.standardOutput = outputPipe
                process.standardError = errorPipe
                
                do {
                    try process.run()
                    process.waitUntilExit()
                    
                    let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: outputData, encoding: .utf8) ?? ""
                    let errorOutput = String(data: errorData, encoding: .utf8) ?? ""
                    
                    print("DEBUG: Language detection output: \(output)")
                    print("DEBUG: Language detection stderr: \(errorOutput)")
                    
                    // Parse detected language from output
                    // Format: "auto-detected language: en (p = 0.99)"
                    let combined = output + errorOutput
                    if let match = combined.range(of: "auto-detected language:\\s*(\\w+)", options: .regularExpression) {
                        let langPart = combined[match]
                        if let langMatch = langPart.range(of: ":\\s*(\\w+)", options: .regularExpression) {
                            var lang = String(langPart[langMatch])
                            lang = lang.replacingOccurrences(of: ":", with: "").trimmingCharacters(in: .whitespaces)
                            print("DEBUG: Detected language: '\(lang)'")
                            continuation.resume(returning: lang)
                            return
                        }
                    }
                    
                    // Fallback: look for language probabilities
                    // Format: "whisper_full: language = en, prob = 0.99"
                    if let match = combined.range(of: "language\\s*=\\s*(\\w+)", options: .regularExpression) {
                        var lang = String(combined[match])
                        lang = lang.replacingOccurrences(of: "language", with: "")
                            .replacingOccurrences(of: "=", with: "")
                            .trimmingCharacters(in: .whitespaces)
                        print("DEBUG: Detected language (fallback): '\(lang)'")
                        continuation.resume(returning: lang)
                        return
                    }
                    
                    print("DEBUG: Could not detect language, defaulting to 'en'")
                    continuation.resume(returning: "en")
                    
                } catch {
                    print("DEBUG: Language detection failed: \(error)")
                    continuation.resume(returning: "en")
                }
            }
        }
    }
    
    /// Run whisper-cli on a preprocessed WAV file
    private func runWhisperTranscription(
        file: URL,
        modelPath: URL,
        settings: TranscriptionSettings,
        onProgress: @escaping (Double, String) -> Void,
        onSegment: ((LiveSegment) -> Void)? = nil
    ) async throws -> TranscriptionResult {
        
        // If language is "auto", detect it first and use consistently
        var effectiveLanguage = settings.language
        if settings.language == "auto" {
            onProgress(0.01, "Detectando idioma...")
            effectiveLanguage = try await detectLanguage(file: file, modelPath: modelPath)
            print("DEBUG: Auto-detected language '\(effectiveLanguage)' - will use for entire transcription")
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            processQueue.async { [weak self] in
                guard let self = self else {
                    continuation.resume(throwing: TranscriptionError.cancelled)
                    return
                }
                
                let process = Process()
                process.executableURL = self.whisperCliPath
                
                print("╔════════════════════════════════════════════════════════════╗")
                print("║        WHISPER CLI EXECUTION                               ║")
                print("╟────────────────────────────────────────────────────────────╢")
                print("║ Language: '\(effectiveLanguage)' \(settings.language == "auto" ? "(auto-detected)" : "(user selected)")")
                print("║ Model: \(modelPath.lastPathComponent)")
                print("║ File: \(file.lastPathComponent)")
                print("╚════════════════════════════════════════════════════════════╝")
                
                // Build arguments based on settings
                var args = [
                    "-m", modelPath.path,
                    "-f", file.path,
                    "-l", effectiveLanguage,
                    "-pp",   // Print progress
                    "-oj",   // Output JSON for structured parsing with timestamps
                ]
                
                // Timestamps - always enabled for interactive viewer
                // If user explicitly disabled, we still generate JSON with timestamps
                // but can hide them in display
                
                // Translation
                if settings.translate {
                    args.append("--translate")
                }
                
                // Temperature (0 = deterministic, reduces hallucination)
                args.append(contentsOf: ["--temperature", String(format: "%.2f", settings.temperature)])
                
                // Decoding parameters for better accuracy
                args.append(contentsOf: ["--beam-size", String(settings.beamSize)])
                args.append(contentsOf: ["--best-of", String(settings.bestOf)])
                args.append(contentsOf: ["--entropy-thold", String(format: "%.2f", settings.entropyThreshold)])
                args.append(contentsOf: ["--no-speech-thold", String(format: "%.2f", settings.noSpeechThreshold)])
                
                // Suppress non-speech tokens (reduces "uh", "um", etc.)
                if settings.suppressNonSpeech {
                    args.append("--suppress-nst")
                }
                
                // Diarization (speaker detection)
                if settings.enableDiarization {
                    args.append("-tdrz")
                }
                
                // VAD options
                if settings.useVAD {
                    args.append("--vad")
                    // Use Silero VAD model
                    if FileManager.default.fileExists(atPath: self.vadModelPath.path) {
                        args.append(contentsOf: ["--vad-model", self.vadModelPath.path])
                    }
                    args.append(contentsOf: ["--vad-threshold", String(format: "%.2f", settings.vadThreshold)])
                    args.append(contentsOf: ["--vad-min-silence-duration-ms", String(settings.vadMinSilenceDuration)])
                    args.append(contentsOf: ["--vad-min-speech-duration-ms", String(settings.vadMinSpeechDuration)])
                    args.append(contentsOf: ["--vad-speech-pad-ms", String(settings.vadSpeechPad)])
                }
                
                // Initial prompt for context (helps with technical vocabulary)
                if !settings.initialPrompt.isEmpty {
                    args.append(contentsOf: ["--prompt", settings.initialPrompt])
                }
                
                // Use temporary output file
                let tempDir = FileManager.default.temporaryDirectory
                let outputBase = tempDir.appendingPathComponent(UUID().uuidString)
                args.append(contentsOf: ["-of", outputBase.path])
                
                process.arguments = args
                
                // Set up environment with proper PATH
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")
                process.environment = env
                
                // Capture stderr for progress
                let errorPipe = Pipe()
                var stderrOutput = ""
                process.standardError = errorPipe
                
                // Capture stdout for live segment streaming
                let outputPipe = Pipe()
                var stdoutBuffer = ""
                process.standardOutput = outputPipe
                
                // Read segments from stdout in real-time
                outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                    let data = handle.availableData
                    if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                        stdoutBuffer += text
                        
                        // Process complete lines
                        let lines = stdoutBuffer.components(separatedBy: .newlines)
                        for (index, line) in lines.enumerated() {
                            // Keep last incomplete line in buffer
                            if index == lines.count - 1 && !text.hasSuffix("\n") {
                                stdoutBuffer = line
                                break
                            }
                            
                            // Parse segment and notify
                            if let segment = self?.parseLiveSegment(line) {
                                DispatchQueue.main.async {
                                    onSegment?(segment)
                                }
                            }
                        }
                        
                        // Clear buffer if we processed all lines
                        if text.hasSuffix("\n") {
                            stdoutBuffer = ""
                        }
                    }
                }
                
                // Read progress from stderr
                errorPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                        stderrOutput += text
                        // Parse whisper.cpp progress output
                        // Format: "whisper_print_progress: progress = XX%"
                        if let match = text.range(of: "progress\\s*=\\s*(\\d+)%", options: .regularExpression) {
                            let progressStr = text[match]
                            if let numMatch = progressStr.range(of: "\\d+", options: .regularExpression) {
                                if let percent = Int(progressStr[numMatch]) {
                                    DispatchQueue.main.async {
                                        onProgress(Double(percent) / 100.0, "Transcribiendo...")
                                    }
                                }
                            }
                        }
                    }
                }
                
                self.activeProcess = process
                
                DispatchQueue.main.async {
                    self.isTranscribing = true
                    self.currentStatus = "Iniciando transcripción..."
                    onProgress(0, "Iniciando transcripción...")
                }
                
                do {
                    print("DEBUG: Running whisper-cli at: " + self.whisperCliPath.path)
                    print("DEBUG: With args: " + args.joined(separator: " "))
                    try process.run()
                    process.waitUntilExit()
                    
                    // Clean up pipe handlers
                    errorPipe.fileHandleForReading.readabilityHandler = nil
                    outputPipe.fileHandleForReading.readabilityHandler = nil
                    
                    print("DEBUG: whisper-cli exited with status: " + String(process.terminationStatus))
                    print("DEBUG: Full stderr output: " + stderrOutput)
                    
                    DispatchQueue.main.async {
                        self.isTranscribing = false
                        self.activeProcess = nil
                    }
                    
                    if process.terminationStatus == 0 {
                        // Read JSON output file
                        let outputFile = URL(fileURLWithPath: outputBase.path + ".json")
                        print("DEBUG: Looking for JSON output at: " + outputFile.path)
                        
                        if FileManager.default.fileExists(atPath: outputFile.path) {
                            do {
                                let jsonData = try Data(contentsOf: outputFile)
                                let result = try self.parseWhisperJSON(jsonData, showTimestamps: settings.timestamps)
                                print("DEBUG: Parsed \(result.segments.count) segments from JSON")
                                
                                // Clean up temp file
                                try? FileManager.default.removeItem(at: outputFile)
                                
                                continuation.resume(returning: result)
                            } catch {
                                print("DEBUG: Failed to parse JSON: \(error)")
                                continuation.resume(throwing: TranscriptionError.parseError)
                            }
                        } else {
                            // Fallback: try txt output
                            let txtFile = URL(fileURLWithPath: outputBase.path + ".txt")
                            if FileManager.default.fileExists(atPath: txtFile.path) {
                                do {
                                    let text = try String(contentsOf: txtFile, encoding: .utf8)
                                    print("DEBUG: Fallback to txt, length: \(text.count) chars")
                                    try? FileManager.default.removeItem(at: txtFile)
                                    
                                    // Create simple result without timestamps
                                    let result = TranscriptionResult(
                                        segments: [TranscriptionSegment(
                                            startTime: 0,
                                            endTime: 0,
                                            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                                            speaker: nil
                                        )],
                                        showTimestamps: false
                                    )
                                    continuation.resume(returning: result)
                                } catch {
                                    continuation.resume(throwing: TranscriptionError.noOutput)
                                }
                            } else {
                                print("DEBUG: No output file found!")
                                continuation.resume(throwing: TranscriptionError.noOutput)
                            }
                        }
                    } else {
                        if process.terminationStatus == 15 {
                            continuation.resume(throwing: TranscriptionError.cancelled)
                            return
                        }
                        print("DEBUG: whisper-cli failed with code: " + String(process.terminationStatus))
                        print("DEBUG: stderr was: " + stderrOutput)
                        continuation.resume(throwing: TranscriptionError.processError(process.terminationStatus))
                    }
                } catch {
                    print("DEBUG: Failed to run whisper-cli: " + error.localizedDescription)
                    DispatchQueue.main.async {
                        self.isTranscribing = false
                        self.activeProcess = nil
                    }
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    // MARK: - Cancel
    
    func cancel() {
        processQueue.async { [weak self] in
            self?.activeProcess?.terminate()
            self?.activeProcess = nil
            
            // Also cancel the preprocessor (FFmpeg, audio engine)
            AudioPreprocessor.shared.cancel()
            
            DispatchQueue.main.async {
                self?.isTranscribing = false
            }
        }
    }
    
    // MARK: - JSON Parsing
    
    /// Parse whisper.cpp JSON output into TranscriptionResult
    private func parseWhisperJSON(_ data: Data, showTimestamps: Bool) throws -> TranscriptionResult {
        // whisper.cpp JSON format:
        // {
        //   "transcription": [
        //     { "timestamps": { "from": "00:00:00,000", "to": "00:00:05,000" }, "text": "Hello" },
        //     ...
        //   ]
        // }
        
        struct WhisperJSON: Codable {
            let transcription: [WhisperSegment]
        }
        
        struct WhisperSegment: Codable {
            let timestamps: WhisperTimestamps
            let text: String
        }
        
        struct WhisperTimestamps: Codable {
            let from: String
            let to: String
        }
        
        let decoder = JSONDecoder()
        let whisperOutput = try decoder.decode(WhisperJSON.self, from: data)
        
        var segments: [TranscriptionSegment] = []
        var currentSpeaker = 0
        
        for segment in whisperOutput.transcription {
            let startTime = parseTimestamp(segment.timestamps.from)
            let endTime = parseTimestamp(segment.timestamps.to)
            var text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Check for speaker turn marker from -tdrz (tinydiarize)
            // Format: [SPEAKER_TURN] or similar marker
            var speaker: Int? = nil
            if text.contains("[SPEAKER_TURN]") {
                currentSpeaker += 1
                text = text.replacingOccurrences(of: "[SPEAKER_TURN]", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                speaker = currentSpeaker
            } else if currentSpeaker > 0 {
                speaker = currentSpeaker
            }
            
            if !text.isEmpty {
                segments.append(TranscriptionSegment(
                    startTime: startTime,
                    endTime: endTime,
                    text: text,
                    speaker: speaker
                ))
            }
        }
        
        return TranscriptionResult(segments: segments, showTimestamps: showTimestamps)
    }
    
    /// Parse timestamp string "HH:MM:SS,mmm" to TimeInterval
    private func parseTimestamp(_ timestamp: String) -> TimeInterval {
        // Format: "00:00:05,000" or "00:00:05.000"
        let clean = timestamp.replacingOccurrences(of: ",", with: ".")
        let parts = clean.components(separatedBy: ":")
        
        guard parts.count == 3 else { return 0 }
        
        let hours = Double(parts[0]) ?? 0
        let minutes = Double(parts[1]) ?? 0
        
        // Handle seconds and milliseconds
        let secondsParts = parts[2].components(separatedBy: ".")
        let seconds = Double(secondsParts[0]) ?? 0
        let milliseconds = secondsParts.count > 1 ? (Double(secondsParts[1]) ?? 0) / 1000.0 : 0
        
        return hours * 3600 + minutes * 60 + seconds + milliseconds
    }
}

// MARK: - Errors

enum TranscriptionError: LocalizedError {
    case modelNotFound
    case whisperNotInstalled
    case invalidURL
    case cancelled
    case noOutput
    case parseError
    case processError(Int32)
    case uploadFailed
    case invalidResponse
    case serverError(String)
    case downloadFailed(String)
    case coreMLNotSupported
    case coreMLUnzipFailed

    private var isSpanishUI: Bool {
        UserDefaults.standard.string(forKey: "app_ui_language") == "es"
    }

    private func localized(_ spanish: String, _ english: String) -> String {
        isSpanishUI ? spanish : english
    }
    
    var errorDescription: String? {
        switch self {
        case .modelNotFound:
            return localized("Modelo no encontrado. Descarga un modelo primero.", "Model not found. Download a model first.")
        case .whisperNotInstalled:
            return localized("whisper.cpp no está instalado", "whisper.cpp is not installed")
        case .invalidURL:
            return localized("URL de descarga inválida", "Invalid download URL")
        case .cancelled:
            return localized("Transcripción cancelada", "Transcription cancelled")
        case .noOutput:
            return localized("No se generó salida de transcripción", "No transcription output was generated")
        case .parseError:
            return localized("Error al parsear la salida de transcripción", "Could not parse transcription output")
        case .processError(let code):
            return localized("Error de transcripción (código: \(code))", "Transcription error (code: \(code))")
        case .uploadFailed:
            return localized("Error al procesar el archivo", "Error while processing the file")
        case .invalidResponse:
            return localized("Respuesta inválida", "Invalid response")
        case .serverError(let message):
            return message
        case .downloadFailed(let message):
            return localized("Error de descarga: \(message)", "Download error: \(message)")
        case .coreMLNotSupported:
            return localized("Este modelo no soporta aceleración CoreML", "This model does not support CoreML acceleration")
        case .coreMLUnzipFailed:
            return localized("Error al descomprimir el acelerador Neural", "Failed to unzip Neural accelerator")
        }
    }
}

// MARK: - URLSessionDownloadDelegate

extension TranscriptionService: URLSessionDownloadDelegate {
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        print("DEBUG: Download finished to temp location: \(location.path)")
        
        // Copy to a safe location before the temp file is deleted
        let tempCopy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bin")
        do {
            try FileManager.default.copyItem(at: location, to: tempCopy)
            downloadContinuation?.resume(returning: tempCopy)
        } catch {
            downloadContinuation?.resume(throwing: TranscriptionError.downloadFailed(error.localizedDescription))
        }
        downloadContinuation = nil
    }
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        
        let p = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        
        // Throttle UI updates
        DispatchQueue.main.async { [weak self] in
            self?.downloadProgress?(p)
        }
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            print("DEBUG: Download failed with error: \(error.localizedDescription)")
            downloadContinuation?.resume(throwing: TranscriptionError.downloadFailed(error.localizedDescription))
            downloadContinuation = nil
        }
    }
}
