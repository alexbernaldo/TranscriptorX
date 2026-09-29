import Foundation
import SwiftUI
import AVFoundation
import AppKit
import UniformTypeIdentifiers

// MARK: - Active Transcription Model (for sidebar)
struct ActiveTranscription: Identifiable {
    let id: UUID
    let fileName: String
    let fileURL: URL
    var progress: Int
    var statusMessage: String
    var streamingText: String
    var startTime: Date
    var isCancelled: Bool = false
    
    var elapsedTime: TimeInterval {
        Date().timeIntervalSince(startTime)
    }
    
    var formattedElapsedTime: String {
        let minutes = Int(elapsedTime) / 60
        let seconds = Int(elapsedTime) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

@MainActor
class TranscriptionViewModel: ObservableObject {
    // MARK: - Published Properties
    
    // File
    @Published var selectedFile: AudioFile?
    @Published var selectedFileURL: URL?
    @Published var selectedFileURLs: [URL] = []  // For multi-file drops
    @Published var hasAudioLoaded: Bool = false
    
    // Transcription
    @Published var isTranscribing = false
    @Published var isMinimizedToBackground = false  // Transcription running but user is on Home
    @Published var currentTaskId: String?
    @Published var transcriptionResult: TranscriptionResult?
    @Published var transcriptionText = "" // Computed from result for legacy compatibility
    @Published var progress: Int = 0 {
        didSet { syncActiveTranscriptionProgress() }
    }
    @Published var statusMessage = "" {
        didSet { syncActiveTranscriptionProgress() }
    }
    @Published var steps: [TranscriptionTask.StepProgress] = []
    
    // Active transcriptions (for sidebar with multiple jobs)
    @Published var activeTranscriptions: [ActiveTranscription] = []
    
    // Streaming text (live transcription preview)
    @Published var streamingText: String = "" {
        didSet { syncActiveTranscriptionProgress() }
    }
    @Published var recentTextTimestamp: Date = Date()
    
    // Transcription metrics
    @Published var transcriptionStartTime: Date?
    @Published var processedAudioDuration: TimeInterval = 0
    @Published var totalAudioDuration: TimeInterval = 0
    @Published var processingSpeed: Double = 0 // x realtime
    
    // Library
    @Published var transcriptions: [Transcription] = []
    @Published var selectedTranscription: Transcription?
    
    // Settings
    @Published var settings = TranscriptionSettings.default
    
    // Session-specific prompt (not saved to settings)
    @Published var sessionPrompt: String = ""

    private var appLanguage: AppLanguage {
        UserDefaults.standard.string(forKey: "app_ui_language") == "es" ? .es : .en
    }

    private func localized(_ spanish: String, _ english: String) -> String {
        appLanguage == .es ? spanish : english
    }
    
    // Audio Player
    @Published var isPlaying = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var playbackSpeed: Double = 1.0
    @Published var volume: Float = 1.0
    @Published var isMuted: Bool = false
    
    // UI State
    @Published var toasts: [Toast] = []
    @Published var showAdvancedOptions = false
    @Published var showFavoritesOnly: Bool = false
    @Published var isEditMode: Bool = false
    @Published var activeSegmentIdForActions: UUID?
    
    /// Segments visible in the viewer (hides deleted, optionally favorites-only)
    var visibleSegments: [TranscriptionSegment] {
        guard let result = transcriptionResult else { return [] }
        var segments = result.segments.filter { !$0.isDeleted }
        if showFavoritesOnly {
            segments = segments.filter { $0.isFavorite }
        }
        return segments
    }

    var canUndoLastSegmentEdit: Bool {
        guard isEditMode else { return false }
        guard let id = activeSegmentIdForActions,
              let segment = transcriptionResult?.segments.first(where: { $0.id == id }) else { return false }
        return !segment.editHistory.isEmpty
    }

    var canRestoreOriginalSegmentText: Bool {
        guard isEditMode else { return false }
        guard let id = activeSegmentIdForActions,
              let segment = transcriptionResult?.segments.first(where: { $0.id == id }),
              let original = segment.originalText else { return false }
        return original != segment.text
    }
    
    // MARK: - Private Properties
    
    private var audioPlayer: AVAudioPlayer?
    private var timer: Timer?
    private let service = TranscriptionService.shared
    private let storage = TranscriptionStorage.shared
    private var transcriptionsDidChangeObserver: Any?
    private var transcriptionTask: Task<Void, Never>?
    private var activeTranscriptionSessionId: UUID?
    
    // MARK: - Initialization
    
    init() {
        loadSettings()
        loadTranscriptions()
        observeTranscriptionStorage()
    }

    deinit {
        if let observer = transcriptionsDidChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func observeTranscriptionStorage() {
        transcriptionsDidChangeObserver = NotificationCenter.default.addObserver(
            forName: .transcriptionsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.loadTranscriptions()
            }
        }
    }
    
    // MARK: - Library Management
    
    func loadTranscriptions() {
        transcriptions = storage.loadTranscriptions()
    }
    
    func saveTranscription(_ transcription: Transcription) {
        // Update in-memory array
        if let index = transcriptions.firstIndex(where: { $0.id == transcription.id }) {
            transcriptions[index] = transcription
        } else {
            transcriptions.insert(transcription, at: 0)
        }
        
        // Persist to disk
        storage.saveTranscription(transcription)
    }
    
    func deleteTranscription(_ transcription: Transcription) {
        transcriptions.removeAll { $0.id == transcription.id }
        storage.deleteTranscription(id: transcription.id)
        storage.deleteAudioFile(for: transcription.id)
        
        // Clear selection if deleted
        if selectedTranscription?.id == transcription.id {
            selectedTranscription = nil
            transcriptionResult = nil
            transcriptionText = ""
        }
    }
    
    /// Clear current transcription and return to home state
    func clearTranscription() {
        // Stop audio if playing
        if isPlaying {
            togglePlayback()
        }
        
        // Clear all transcription-related state
        selectedFile = nil
        selectedFileURL = nil
        hasAudioLoaded = false
        transcriptionResult = nil
        transcriptionText = ""
        streamingText = ""
        selectedTranscription = nil
        progress = 0
        statusMessage = ""
        steps = []
        currentTime = 0
        duration = 0
        
        // Clear audio player
        audioPlayer?.stop()
        audioPlayer = nil
        activeSegmentIdForActions = nil
    }
    
    /// Minimize transcription to background (continue processing but show Home)
    func minimizeToBackground() {
        // Add current transcription to active list if not already there
        if let file = selectedFile {
            let activeId = UUID()
            let active = ActiveTranscription(
                id: activeId,
                fileName: file.name,
                fileURL: file.url,
                progress: progress,
                statusMessage: statusMessage,
                streamingText: streamingText,
                startTime: transcriptionStartTime ?? Date()
            )
            
            // Only add if not already in the list (by URL)
            if !activeTranscriptions.contains(where: { $0.fileURL == file.url }) {
                activeTranscriptions.append(active)
            }
        }
        
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            isMinimizedToBackground = true
        }
    }
    
    /// Restore transcription view from background
    func restoreFromBackground() {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            isMinimizedToBackground = false
        }
    }
    
    /// Restore a specific transcription from the sidebar
    func restoreTranscription(_ active: ActiveTranscription) {
        // Log the restoration for diagnostics
        AppLogger.shared.log("Restoring transcription from sidebar: \(active.fileName)", category: .transcription)
        // For now, just restore the view (single transcription support)
        // In future, this could switch to that specific transcription
        restoreFromBackground()
    }
    
    /// Cancel a specific active transcription
    func cancelActiveTranscription(_ id: UUID) {
        if let index = activeTranscriptions.firstIndex(where: { $0.id == id }) {
            activeTranscriptions[index].isCancelled = true
            
            // If this is the current transcription, cancel it
            if activeTranscriptions.count == 1 {
                cancelTranscription()
            }
            
            // Remove from list with animation
            withAnimation(.smooth(duration: 0.3)) {
                activeTranscriptions.removeAll { $0.id == id }
            }
            
            // If no more active transcriptions, exit minimized state
            if activeTranscriptions.isEmpty {
                isMinimizedToBackground = false
                isTranscribing = false
            }
        }
    }
    
    /// Cancel all active transcriptions
    func cancelAllTranscriptions() {
        // Cancel the current transcription
        cancelTranscription()
        
        // Clear all active transcriptions
        withAnimation(.smooth(duration: 0.3)) {
            activeTranscriptions.removeAll()
        }
        
        isMinimizedToBackground = false
    }
    
    /// Update the current active transcription's progress (called during transcription)
    func updateActiveTranscriptionProgress() {
        syncActiveTranscriptionProgress()
    }

    private func syncActiveTranscriptionProgress() {
        guard isMinimizedToBackground, let file = selectedFile,
              let index = activeTranscriptions.firstIndex(where: { $0.fileURL == file.url }) else { return }
        activeTranscriptions[index].progress = progress
        activeTranscriptions[index].statusMessage = statusMessage
        activeTranscriptions[index].streamingText = streamingText
    }
    
    func toggleFavorite(_ transcription: Transcription) {
        if let updated = storage.toggleFavorite(id: transcription.id),
           let index = transcriptions.firstIndex(where: { $0.id == transcription.id }) {
            transcriptions[index] = updated
            
            if selectedTranscription?.id == transcription.id {
                selectedTranscription = updated
            }
        }
    }
    
    func selectTranscription(_ transcription: Transcription) {
        selectedTranscription = transcription
        activeSegmentIdForActions = nil
        
        // Load the transcription result
        if let segments = transcription.segments {
            transcriptionResult = TranscriptionResult(segments: segments)
        } else {
            transcriptionResult = TranscriptionResult(plainText: transcription.text)
        }
        transcriptionText = transcription.text
        
        // Load audio if available
        if let url = transcription.sourceURL, FileManager.default.fileExists(atPath: url.path) {
            loadFile(url: url)
        }
    }

    /// Open a job result from the queue panel into the main viewer.
    /// Jobs are persisted to history using the job id as the transcription id.
    func openTranscriptionJob(_ job: TranscriptionJob) {
        switch job.status {
        case .completed:
            // Ensure in-memory history is up to date (jobs write directly to storage)
            loadTranscriptions()

            if let transcription = transcriptions.first(where: { $0.id == job.id }) {
                selectTranscription(transcription)
                return
            }

            // Fallback: open the in-memory job result if the history record isn't available
            if let result = job.result {
                transcriptionResult = result
                transcriptionText = result.plainText
                streamingText = result.plainText
                selectedTranscription = nil

                Task {
                    await loadFileAsync(url: job.fileURL)
                }
                return
            }

            showToast(localized("No se pudo abrir la transcripción", "Could not open transcription"), type: .error)

        case .failed:
            if let message = job.errorMessage, !message.isEmpty {
                showToast(message, type: .error)
            } else {
                showToast(localized("El trabajo falló", "Job failed"), type: .error)
            }

        default:
            break
        }
    }
    
    // MARK: - File Handling
    
    func openFilePicker() {
        guard let url = FileInputService.pickSingleFile() else { return }
        NotificationCenter.default.post(
            name: .openNewTranscriptionWithFile,
            object: nil,
            userInfo: ["fileURL": url]
        )
    }
    
    func loadFile(url: URL) {
        Task {
            await loadFileAsync(url: url)
        }
    }
    
    /// Async version of loadFile that can be awaited
    func loadFileAsync(url: URL) async {
        do {
            // Verify file exists first
            guard FileManager.default.fileExists(atPath: url.path) else {
                AppLogger.shared.log("File does not exist at: \(url.path)", level: .error, category: .transcription)
                showToast(localized("El archivo no existe", "File does not exist"), type: .error)
                return
            }
            
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let size = attributes[.size] as? Int64 ?? 0
            
            AppLogger.shared.log("Loading file: \(url.lastPathComponent), size: \(size) bytes", level: .info, category: .transcription)
            
            var file = AudioFile(url: url, name: url.lastPathComponent, size: size)
            
            // Get duration asynchronously
            let asset = AVURLAsset(url: url)
            let durationValue = try await asset.load(.duration)
            file.duration = CMTimeGetSeconds(durationValue)
            
            AppLogger.shared.log("File duration: \(file.duration ?? 0) seconds", level: .info, category: .transcription)
            
            // Track the loaded file URL for downstream features (history persistence, UI flows)
            selectedFileURL = url
            selectedFile = file
            hasAudioLoaded = true
            duration = file.duration ?? 0
            
            // Setup audio player
            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.prepareToPlay()
            
            showToast(localized("Archivo cargado correctamente", "File loaded successfully"), type: .success)
        } catch {
            AppLogger.shared.logError(error, context: "Failed to load file: \(url.path)", category: .transcription)
            showToast(localized("Error al cargar el archivo: ", "Error loading file: ") + error.localizedDescription, type: .error)
        }
    }
    
    func removeFile() {
        selectedFile = nil
        selectedFileURL = nil
        hasAudioLoaded = false
        transcriptionResult = nil
        transcriptionText = ""
        audioPlayer?.stop()
        audioPlayer = nil
        stopTimer()
    }
    
    // MARK: - Transcription
    
    /// Reference to job manager for queue-based transcription
    private let jobManager = JobManager.shared
    
    /// Request to start transcription - checks model availability first
    /// - Parameter useQueue: If true, enqueue via JobManager; if false, start directly
    func requestTranscription(useQueue: Bool = true) {
        guard selectedFile != nil else {
            AppLogger.shared.log("requestTranscription - no file selected", level: .warning, category: .transcription)
            return
        }
        
        let modelId = settings.selectedModelId
        AppLogger.shared.log("requestTranscription - checking model: \(modelId)", level: .debug, category: .transcription)
        
        // Check if model is downloaded using the new service
        if !service.isModelDownloaded(modelId) {
            // Find model name
            let modelName = ModelInfo.allModels.first { $0.id == modelId }?.localizedName(appLanguage) ?? modelId
            
            AppLogger.shared.log("Model not downloaded, showing download sheet for: \(modelName)", level: .info, category: .model)
            
            // Post notification to show download sheet
            NotificationCenter.default.post(
                name: .needsModelDownload,
                object: nil,
                userInfo: ["modelId": modelId, "modelName": modelName]
            )
            return
        }
        
        AppLogger.shared.log("Model available, starting transcription", level: .info, category: .transcription)
        
        if useQueue {
            // Enqueue via JobManager
            enqueueTranscription()
        } else {
            // Legacy: start directly (for backward compatibility)
            startTranscription()
        }
    }
    
    /// Enqueue transcription via JobManager
    func enqueueTranscription() {
        guard let file = selectedFile else { return }
        
        // Create effective settings with session prompt if provided
        var effectiveSettings = settings
        if !sessionPrompt.isEmpty {
            effectiveSettings.initialPrompt = sessionPrompt
        }
        
        // Clear session prompt after using it
        sessionPrompt = ""
        
        // Enqueue job
        let jobId = jobManager.enqueue(
            fileURL: file.url,
            fileName: file.name,
            fileDuration: file.duration,
            settings: effectiveSettings
        )
        
        AppLogger.shared.log("Job enqueued: \(file.name) (ID: \(jobId))", category: .transcription)
        
        // Show toast
        showToast(localized("Añadido a la cola", "Added to queue"), type: .success)
        
        // Clear selection for next file
        selectedFile = nil
        selectedFileURL = nil
        hasAudioLoaded = false
    }
    
    /// Start transcription (assumes model is available)
    func startTranscription() {
        guard let file = selectedFile else { return }

        transcriptionTask?.cancel()
        let sessionId = UUID()
        activeTranscriptionSessionId = sessionId
        
        isTranscribing = true
        progress = 0
        statusMessage = localized("Iniciando transcripción...", "Starting transcription...")
        transcriptionResult = nil
        transcriptionText = ""
        streamingText = ""
        recentTextTimestamp = Date()
        transcriptionStartTime = Date()
        processedAudioDuration = 0
        totalAudioDuration = file.duration ?? 0
        processingSpeed = 0
        
        // Build preprocessing options from settings
        let preprocessOptions = AudioPreprocessor.Options(
            isolateVoice: settings.isolateVoice,
            denoise: settings.deepfilter,
            normalize: settings.normalize,
            useVAD: settings.useVAD
        )
        
        // Create effective settings with session prompt if provided
        var effectiveSettings = settings
        if !sessionPrompt.isEmpty {
            effectiveSettings.initialPrompt = sessionPrompt
        }
        
        // Clear session prompt after using it
        let promptUsed = sessionPrompt
        sessionPrompt = ""
        
        // Complete debug output for all settings
        printFullSettingsDebug(file: file)
        if !promptUsed.isEmpty {
            print("   Using session prompt: '\(promptUsed)'")
        }
        
        transcriptionTask = Task {
            do {
                // Use native whisper.cpp transcription with preprocessing
                let result = try await service.transcribe(
                    file: file.url,
                    modelId: effectiveSettings.selectedModelId,
                    settings: effectiveSettings,
                    preprocessOptions: preprocessOptions,
                    onProgress: { [weak self] progressValue, status in
                        Task { @MainActor in
                            guard let self = self else { return }
                            guard self.activeTranscriptionSessionId == sessionId, self.isTranscribing else { return }
                            self.progress = Int(progressValue * 100)
                            self.statusMessage = status
                            
                            // Update processed audio duration
                            self.processedAudioDuration = self.totalAudioDuration * progressValue
                            
                            // Calculate processing speed
                            if let startTime = self.transcriptionStartTime {
                                let elapsedTime = Date().timeIntervalSince(startTime)
                                if elapsedTime > 0 && self.processedAudioDuration > 0 {
                                    self.processingSpeed = self.processedAudioDuration / elapsedTime
                                }
                            }
                        }
                    },
                    onSegment: { [weak self] segment in
                        Task { @MainActor in
                            guard let self = self else { return }
                            guard self.activeTranscriptionSessionId == sessionId, self.isTranscribing else { return }
                            // Append new segment to streaming text
                            if self.streamingText.isEmpty {
                                self.streamingText = segment.text
                            } else {
                                self.streamingText += " " + segment.text
                            }
                            self.recentTextTimestamp = Date()
                            
                            // Update processed duration based on segment end time
                            self.processedAudioDuration = segment.endTime
                        }
                    }
                )

                guard self.activeTranscriptionSessionId == sessionId, self.isTranscribing else {
                    return
                }
                
                transcriptionResult = result
                transcriptionText = result.plainText
                streamingText = result.plainText
                isTranscribing = false
                activeTranscriptionSessionId = nil
                transcriptionTask = nil
                
                // Save to history automatically
                saveToHistory(result: result)
                
                showToast(localized("Transcripción completada", "Transcription completed"), type: .success)
                
            } catch {
                guard self.activeTranscriptionSessionId == sessionId else { return }
                activeTranscriptionSessionId = nil
                transcriptionTask = nil
                isTranscribing = false
                if isCancellationError(error) {
                    statusMessage = localized("Transcripción cancelada", "Transcription cancelled")
                    return
                }
                showToast("Error: \(error.localizedDescription)", type: .error)
            }
        }
    }

    /// Start transcription immediately for a specific file/settings pair.
    /// Useful for single-file UX where user expects to see the loading/progress screen right away.
    func startTranscription(fileURL: URL, settings overrideSettings: TranscriptionSettings) {
        let previousSettings = settings
        settings = overrideSettings

        Task {
            defer { self.settings = previousSettings }

            await loadFileAsync(url: fileURL)
            guard selectedFile != nil else { return }
            startTranscription()
        }
    }
    
    /// Save completed transcription to history
    private func saveToHistory(result: TranscriptionResult) {
        // Generate title from filename or first words
        let title: String
        if let fileName = selectedFile?.name {
            // Remove extension and clean up
            let cleanedTitle = fileName
                .replacingOccurrences(of: "\\.[^.]+$", with: "", options: .regularExpression)
                .replacingOccurrences(of: "_", with: " ")
                .replacingOccurrences(of: "-", with: " ")
                .prefix(50)
                .trimmingCharacters(in: .whitespaces)
            title = cleanedTitle.isEmpty ? localized("Transcripción", "Transcription") : String(cleanedTitle)
        } else {
            // Use first words of transcription
            let words = result.plainText.split(separator: " ").prefix(6).joined(separator: " ")
            title = words.isEmpty ? localized("Transcripción", "Transcription") : String(words.prefix(50))
        }
        
        // Persist audio file if available
        var persistedAudioURL: URL? = nil
        let transcriptionId = UUID()
        
        if settings.keepAudioFileInHistory, let sourceURL = selectedFile?.url {
            persistedAudioURL = storage.persistAudioFile(from: sourceURL, for: transcriptionId)
        } else {
            // Defensive cleanup in case a stale file exists for this id.
            storage.deleteAudioFile(for: transcriptionId)
        }
        
        // Create transcription record
        let transcription = Transcription(
            id: transcriptionId,
            title: title,
            text: result.plainText,
            language: settings.language,
            duration: duration,
            createdAt: Date(),
            isFavorite: false,
            sourceURL: persistedAudioURL,
            segments: result.segments.isEmpty ? nil : result.segments
        )
        
        // Save to storage
        saveTranscription(transcription)
        selectedTranscription = transcription
        
        AppLogger.shared.log("Saved transcription to history: \(title)", category: .transcription)
    }
    
    func cancelTranscription() {
        activeTranscriptionSessionId = nil
        transcriptionTask?.cancel()
        transcriptionTask = nil
        service.cancel()
        isTranscribing = false
        currentTaskId = nil
        statusMessage = localized("Transcripción cancelada", "Transcription cancelled")
        steps = []
        
        // Clear active transcription cards
        withAnimation(.smooth(duration: 0.3)) {
            activeTranscriptions.removeAll()
        }
        isMinimizedToBackground = false
        
        showToast(localized("Transcripción cancelada", "Transcription cancelled"), type: .info)
    }

    private func isCancellationError(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let transcriptionError = error as? TranscriptionError {
            switch transcriptionError {
            case .cancelled:
                return true
            case .processError(let code):
                return code == 15
            default:
                break
            }
        }
        if let preprocessorError = error as? PreprocessorError,
           case .cancelled = preprocessorError {
            return true
        }
        let message = error.localizedDescription.lowercased()
        return message.contains("cancel") || message.contains("cancelad")
    }
    
    // MARK: - Audio Playback
    
    func togglePlayback() {
        if isPlaying {
            audioPlayer?.pause()
            stopTimer()
        } else {
            audioPlayer?.play()
            startTimer()
        }
        isPlaying.toggle()
    }
    
    func seek(to time: TimeInterval) {
        audioPlayer?.currentTime = time
        currentTime = time
    }
    func setPlaybackSpeed(_ speed: Double) {
        playbackSpeed = speed
        audioPlayer?.rate = Float(speed)
        // Enable rate adjustment if player exists
        audioPlayer?.enableRate = true
    }
    
    func setVolume(_ newVolume: Float) {
        volume = max(0, min(1, newVolume))
        audioPlayer?.volume = isMuted ? 0 : volume
    }
    
    func toggleMute() {
        isMuted.toggle()
        audioPlayer?.volume = isMuted ? 0 : volume
    }
    
    func skipBackward(seconds: TimeInterval = 10) {
        let newTime = max(0, (audioPlayer?.currentTime ?? 0) - seconds)
        seek(to: newTime)
    }
    
    func skipForward(seconds: TimeInterval = 10) {
        let newTime = min(duration, (audioPlayer?.currentTime ?? 0) + seconds)
        seek(to: newTime)
    }
    
    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.currentTime = self?.audioPlayer?.currentTime ?? 0
            }
        }
    }
    
    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
    
    // MARK: - Export
    
    func copyTranscription() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transcriptionText, forType: .string)
        showToast(localized("Texto copiado al portapapeles", "Text copied to clipboard"), type: .success)
    }
    
    // MARK: - Segment Copy Mode
    
    enum SegmentCopyMode {
        case textOnly
        case withTimestamp
        case withTimestampAndSpeaker
    }

    func setActiveSegmentForActions(_ id: UUID) {
        activeSegmentIdForActions = id
    }

    private func visibleText(from segments: [TranscriptionSegment]) -> String {
        segments
            .filter { !$0.isDeleted }
            .map { $0.text }
            .joined(separator: " ")
    }
    
    /// Update a specific segment's text (for inline editing)
    func updateSegmentText(segmentId: UUID, newText: String) {
        guard isEditMode else { return }
        guard var result = transcriptionResult,
              let index = result.segments.firstIndex(where: { $0.id == segmentId }) else { return }
        guard newText != result.segments[index].text else { return }

        result.segments[index] = result.segments[index].withText(newText)
        transcriptionResult = result
        transcriptionText = visibleText(from: result.segments)
        
        persistSegmentChanges()
        showToast(localized("Texto actualizado", "Text updated"), type: .success)
    }
    
    /// Soft-delete a segment with 5-second undo window
    func deleteSegment(id: UUID) {
        guard isEditMode else { return }
        guard var result = transcriptionResult,
              let index = result.segments.firstIndex(where: { $0.id == id }) else { return }
        
        guard !result.segments[index].isDeleted else { return }
        result.segments[index].isDeleted = true
        transcriptionResult = result
        transcriptionText = visibleText(from: result.segments)
        
        persistSegmentChanges()
        
        // Show undo toast (5s)
        let undoToast = Toast(
            message: localized("Segmento eliminado", "Segment deleted"),
            type: .info,
            action: Toast.ToastAction(
                label: localized("Deshacer", "Undo"),
                handler: { [weak self] in
                    self?.restoreDeletedSegment(id: id)
                }
            )
        )
        toasts.append(undoToast)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.toasts.removeAll { $0.id == undoToast.id }
        }
    }
    
    /// Restore a soft-deleted segment
    func restoreDeletedSegment(id: UUID) {
        guard isEditMode else { return }
        guard var result = transcriptionResult,
              let index = result.segments.firstIndex(where: { $0.id == id }) else { return }
        
        guard result.segments[index].isDeleted else { return }
        result.segments[index].isDeleted = false
        transcriptionResult = result
        transcriptionText = visibleText(from: result.segments)
        
        persistSegmentChanges()
        showToast(localized("Segmento restaurado", "Segment restored"), type: .success)
    }
    
    /// Toggle favorite on a segment
    func toggleSegmentFavorite(id: UUID) {
        guard isEditMode else { return }
        guard var result = transcriptionResult,
              let index = result.segments.firstIndex(where: { $0.id == id }) else { return }
        
        result.segments[index].isFavorite.toggle()
        transcriptionResult = result
        
        persistSegmentChanges()
    }

    /// Revert segment text to its original text (first version before edits)
    func restoreOriginalSegmentText(id: UUID) {
        guard isEditMode else { return }
        guard var result = transcriptionResult,
              let index = result.segments.firstIndex(where: { $0.id == id }),
              let original = result.segments[index].originalText else { return }
        guard original != result.segments[index].text else { return }

        result.segments[index] = result.segments[index].withText(original)
        transcriptionResult = result
        transcriptionText = visibleText(from: result.segments)

        persistSegmentChanges()
        showToast(localized("Texto original restaurado", "Original text restored"), type: .success)
    }

    /// Undo the most recent segment edit using the stored edit history.
    func undoLastSegmentEdit(id: UUID) {
        guard isEditMode else { return }
        guard var result = transcriptionResult,
              let index = result.segments.firstIndex(where: { $0.id == id }),
              !result.segments[index].editHistory.isEmpty else { return }

        let previousText = result.segments[index].editHistory.removeLast()
        result.segments[index].text = previousText
        transcriptionResult = result
        transcriptionText = visibleText(from: result.segments)

        persistSegmentChanges()
        showToast(localized("Última edición deshecha", "Last edit undone"), type: .success)
    }

    func undoLastSegmentEditOnActiveSegment() {
        guard isEditMode else { return }
        guard let id = activeSegmentIdForActions else { return }
        undoLastSegmentEdit(id: id)
    }

    func restoreOriginalTextOnActiveSegment() {
        guard isEditMode else { return }
        guard let id = activeSegmentIdForActions else { return }
        restoreOriginalSegmentText(id: id)
    }
    
    /// Copy a segment to clipboard in the specified mode
    func copySegment(id: UUID, mode: SegmentCopyMode) {
        guard let result = transcriptionResult,
              let segment = result.segments.first(where: { $0.id == id }) else { return }
        
        let text: String
        switch mode {
        case .textOnly:
            text = segment.text
        case .withTimestamp:
            text = "[\(segment.formattedStartTime)] \(segment.text)"
        case .withTimestampAndSpeaker:
            let speakerLabel = segment.speaker.map { "Speaker \($0 + 1)" } ?? ""
            if speakerLabel.isEmpty {
                text = "[\(segment.formattedStartTime)] \(segment.text)"
            } else {
                text = "[\(segment.formattedStartTime)] [\(speakerLabel)] \(segment.text)"
            }
        }
        
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        showToast(localized("Copiado al portapapeles", "Copied to clipboard"), type: .success)
    }
    
    /// Persist current segment state to storage
    private func persistSegmentChanges() {
        guard let result = transcriptionResult,
              var transcription = selectedTranscription else { return }
        
        transcription.segments = result.segments
        transcription.text = visibleText(from: result.segments)
        selectedTranscription = transcription
        saveTranscription(transcription)
    }
    
    func exportTranscription(format: ExportFormat) {
        // Build the intermediate document
        let document = ExportDocument.from(
            transcription: selectedTranscription,
            result: transcriptionResult,
            settings: settings,
            fileName: selectedFile?.name
        )
        
        // Validate: no empty exports
        guard !document.isEmpty else {
            showToast(localized("No hay contenido para exportar", "No content to export"), type: .warning)
            return
        }
        
        // Validate: segment-dependent formats
        if format.requiresSegments && document.segments.isEmpty {
            showToast(
                localized(
                    "No hay segmentos con tiempo para exportar a \(format.rawValue.uppercased())",
                    "No timed segments to export as \(format.rawValue.uppercased())"
                ),
                type: .warning
            )
            return
        }
        
        // PDF is async — handle separately
        if format == .pdf {
            exportPDF(document: document)
            return
        }
        
        // Show save panel
        let panel = NSSavePanel()
        if let type = UTType(filenameExtension: format.rawValue) {
            panel.allowedContentTypes = [type]
        } else {
            panel.allowedContentTypes = [.plainText]
        }
        let baseName = appLanguage == .es ? "transcripcion" : "transcription"
        panel.nameFieldStringValue = "\(baseName).\(format.rawValue)"
        
        guard panel.runModal() == .OK, let url = panel.url else { return }
        
        do {
            switch format {
            // Legacy string-based formats
            case .txt:
                // transcriptionText is always up-to-date (recalculated on every edit/delete)
                let content = transcriptionText
                try content.write(to: url, atomically: true, encoding: .utf8)
                
            case .srt:
                let content = transcriptionResult?.toSRT() ?? ""
                try content.write(to: url, atomically: true, encoding: .utf8)
                
            case .vtt:
                let content = transcriptionResult?.toVTT() ?? ""
                try content.write(to: url, atomically: true, encoding: .utf8)
                
            case .md:
                let content = transcriptionResult?.toMarkdown() ?? transcriptionText
                try content.write(to: url, atomically: true, encoding: .utf8)
                
            // New data-based formats
            case .csv:
                let data = try CSVExportGenerator(includeTimestamps: true).generate(from: document)
                try data.write(to: url)
                
            case .html:
                let data = try HTMLExportGenerator().generate(from: document)
                try data.write(to: url)
                
            case .docx:
                let data = try DOCXExportGenerator().generate(from: document)
                try data.write(to: url)
                
            case .pdf:
                break // handled above
            }
            
            showToast(localized("Archivo guardado", "File saved"), type: .success)
            // Open in external app
            NSWorkspace.shared.open(url)
            
        } catch {
            showToast(localized("Error al guardar: ", "Error saving: ") + error.localizedDescription, type: .error)
        }
    }
    
    /// Export CSV in simple text-only mode (no timestamps/speakers)
    func exportCSVSimple() {
        let document = ExportDocument.from(
            transcription: selectedTranscription,
            result: transcriptionResult,
            settings: settings,
            fileName: selectedFile?.name
        )
        guard !document.isEmpty else {
            showToast(localized("No hay contenido para exportar", "No content to export"), type: .warning)
            return
        }
        
        let panel = NSSavePanel()
        if let type = UTType(filenameExtension: "csv") { panel.allowedContentTypes = [type] }
        let baseName = appLanguage == .es ? "transcripcion_simple" : "transcription_simple"
        panel.nameFieldStringValue = "\(baseName).csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        
        do {
            let data = try CSVExportGenerator(includeTimestamps: false).generate(from: document)
            try data.write(to: url)
            showToast(localized("Archivo guardado", "File saved"), type: .success)
            NSWorkspace.shared.open(url)
        } catch {
            showToast(localized("Error al guardar: ", "Error saving: ") + error.localizedDescription, type: .error)
        }
    }
    
    /// Async PDF export using WKWebView rendering
    private func exportPDF(document: ExportDocument) {
        Task {
            do {
                let pdfData = try await PDFExportGenerator().generate(from: document)
                
                // Show save panel on main thread
                let panel = NSSavePanel()
                panel.allowedContentTypes = [.pdf]
                let baseName = appLanguage == .es ? "transcripcion" : "transcription"
                panel.nameFieldStringValue = "\(baseName).pdf"
                
                guard panel.runModal() == .OK, let url = panel.url else { return }
                
                try pdfData.write(to: url)
                showToast(localized("PDF guardado", "PDF saved"), type: .success)
                NSWorkspace.shared.open(url)
                
            } catch {
                showToast(localized("Error al generar PDF: ", "Error generating PDF: ") + error.localizedDescription, type: .error)
            }
        }
    }
    
    // MARK: - Settings Persistence
    
    private func loadSettings() {
        guard let data = UserDefaults.standard.data(forKey: "transcription_settings") else { return }

        let decoder = JSONDecoder()
        if let saved = try? decoder.decode(TranscriptionSettings.self, from: data) {
            settings = saved
            return
        }

        // Migration fallback: inject missing keys from defaults (e.g. newly added settings)
        guard var raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }

        if raw["keepAudioFileInHistory"] == nil {
            raw["keepAudioFileInHistory"] = TranscriptionSettings.default.keepAudioFileInHistory
        }

        guard let migratedData = try? JSONSerialization.data(withJSONObject: raw),
              let migrated = try? decoder.decode(TranscriptionSettings.self, from: migratedData) else {
            return
        }

        settings = migrated
        saveSettings()
    }
    
    func saveSettings() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: "transcription_settings")
        }
    }
    
    // MARK: - Debug
    
    private func printFullSettingsDebug(file: AudioFile) {
        print("")
        print("╔══════════════════════════════════════════════════════════════╗")
        print("║           TRANSCRIPTION CONFIGURATION DEBUG                  ║")
        print("╠══════════════════════════════════════════════════════════════╣")
        print("║ FILE INFO                                                    ║")
        print("╟──────────────────────────────────────────────────────────────╢")
        print("║  Name: \(file.name)")
        print("║  Size: \(file.formattedSize)")
        print("║  Duration: \(file.formattedDuration)")
        print("║  Path: \(file.url.path)")
        print("╠══════════════════════════════════════════════════════════════╣")
        print("║ BASIC SETTINGS                                               ║")
        print("╟──────────────────────────────────────────────────────────────╢")
        print("║  Language: \(settings.language)")
        print("║  Model: \(settings.selectedModelId)")
        print("║  GPU Acceleration: Metal (always active on Apple Silicon)")
        print("║  Timestamps: \(settings.timestamps ? "✓ ENABLED" : "✗ Disabled")")
        print("║  Translate to English: \(settings.translate ? "✓ ENABLED" : "✗ Disabled")")
        print("║  Keep audio in history: \(settings.keepAudioFileInHistory ? "✓ ENABLED" : "✗ Disabled")")
        print("╠══════════════════════════════════════════════════════════════╣")
        print("║ PREPROCESSING OPTIONS                                        ║")
        print("╟──────────────────────────────────────────────────────────────╢")
        print("║  Normalize Audio (EBU R128): \(settings.normalize ? "✓ ENABLED" : "✗ Disabled")")
        print("╠══════════════════════════════════════════════════════════════╣")
        print("║ VAD (Voice Activity Detection)                               ║")
        print("╟──────────────────────────────────────────────────────────────╢")
        print("║  VAD Enabled: \(settings.useVAD ? "✓ ENABLED" : "✗ Disabled")")
        if settings.useVAD {
            print("║  VAD Threshold: \(String(format: "%.2f", settings.vadThreshold))")
            print("║  Min Silence Duration: \(settings.vadMinSilenceDuration) ms")
            print("║  Min Speech Duration: \(settings.vadMinSpeechDuration) ms")
            print("║  Speech Padding: \(settings.vadSpeechPad) ms")
        }
        print("╠══════════════════════════════════════════════════════════════╣")
        print("║ WHISPER DECODING PARAMETERS                                  ║")
        print("╟──────────────────────────────────────────────────────────────╢")
        print("║  Temperature: \(String(format: "%.2f", settings.temperature)) \(settings.temperature == 0 ? "(deterministic)" : "(creative)")")
        print("║  Beam Size: \(settings.beamSize)")
        print("║  Best Of: \(settings.bestOf)")
        print("║  Entropy Threshold: \(String(format: "%.2f", settings.entropyThreshold))")
        print("║  No Speech Threshold: \(String(format: "%.2f", settings.noSpeechThreshold))")
        print("║  Suppress Non-Speech: \(settings.suppressNonSpeech ? "✓ ENABLED" : "✗ Disabled")")
        print("╠══════════════════════════════════════════════════════════════╣")
        print("║ DIARIZATION & CONTEXT                                        ║")
        print("╟──────────────────────────────────────────────────────────────╢")
        print("║  Speaker Diarization: \(settings.enableDiarization ? "✓ ENABLED" : "✗ Disabled")")
        print("║  Initial Prompt: \(settings.initialPrompt.isEmpty ? "(none)" : "\"\(settings.initialPrompt)\"")")
        print("╚══════════════════════════════════════════════════════════════╝")
        print("")
    }
    
    // MARK: - Toasts
    
    func showToast(_ message: String, type: Toast.ToastType) {
        let toast = Toast(message: message, type: type)
        toasts.append(toast)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.toasts.removeAll { $0.id == toast.id }
        }
    }
}

// MARK: - Toast Model

struct Toast: Identifiable {
    let id = UUID()
    let message: String
    let type: ToastType
    var action: ToastAction? = nil
    
    struct ToastAction {
        let label: String
        let handler: () -> Void
    }
    
    enum ToastType {
        case success, error, warning, info
        
        var color: Color {
            switch self {
            case .success: return .success
            case .error: return .error
            case .warning: return .warning
            case .info: return .accentPrimary
            }
        }
        
        var icon: String {
            switch self {
            case .success: return "checkmark.circle.fill"
            case .error: return "xmark.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .info: return "info.circle.fill"
            }
        }
    }
}
