import Foundation
import Combine

/// Manages the queue of transcription jobs
/// Processes jobs serially (one at a time) to avoid GPU/memory overload
@MainActor
final class JobManager: ObservableObject {
    
    // MARK: - Singleton
    static let shared = JobManager()
    
    // MARK: - Published State
    @Published private(set) var jobs: [TranscriptionJob] = []
    @Published private(set) var isProcessing = false
    
    // MARK: - Services
    private let transcriptionService = TranscriptionService.shared
    private let preprocessor = AudioPreprocessor.shared
    private let storage = TranscriptionStorage.shared
    
    // MARK: - Worker State
    private var workerTask: Task<Void, Never>?
    private var currentJobId: UUID?
    private var cancellationRequested = false

    private var isSpanishUI: Bool {
        UserDefaults.standard.string(forKey: "app_ui_language") == "es"
    }
    
    // MARK: - Computed Properties
    
    var currentJob: TranscriptionJob? {
        jobs.first { $0.status == .processing }
    }
    
    var queuedJobs: [TranscriptionJob] {
        jobs.filter { $0.status == .queued }
    }
    
    var completedJobs: [TranscriptionJob] {
        jobs.filter { $0.status == .completed }
    }
    
    var failedJobs: [TranscriptionJob] {
        jobs.filter { $0.status == .failed }
    }
    
    var stats: JobQueueStats {
        JobQueueStats(jobs: jobs)
    }
    
    // MARK: - Initialization
    
    private init() {
        AppLogger.shared.log("JobManager initialized", category: .transcription)
    }
    
    // MARK: - Public API
    
    /// Add a single file to the queue
    @discardableResult
    func enqueue(
        fileURL: URL,
        fileName: String,
        fileDuration: TimeInterval? = nil,
        settings: TranscriptionSettings
    ) -> UUID {
        let job = TranscriptionJob(
            fileURL: fileURL,
            fileName: fileName,
            fileDuration: fileDuration,
            settings: settings
        )
        
        jobs.append(job)
        AppLogger.shared.log("Job enqueued: \(fileName) (ID: \(job.id))", category: .transcription)
        
        // Start worker if not already running
        startWorkerIfNeeded()
        
        return job.id
    }
    
    /// Add multiple files to the queue
    @discardableResult
    func enqueue(
        files: [(url: URL, name: String, duration: TimeInterval?)],
        settings: TranscriptionSettings
    ) -> [UUID] {
        let ids = files.map { file in
            enqueue(
                fileURL: file.url,
                fileName: file.name,
                fileDuration: file.duration,
                settings: settings
            )
        }
        return ids
    }
    
    /// Cancel a job
    func cancel(jobId: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == jobId }) else { return }
        
        let job = jobs[index]
        
        switch job.status {
        case .queued:
            // Simply remove from queue
            jobs.remove(at: index)
            AppLogger.shared.log("Queued job removed: \(job.fileName)", category: .transcription)
            
        case .processing:
            // Signal cancellation to worker
            cancellationRequested = true
            transcriptionService.cancel()
            preprocessor.cancel()
            jobs[index].markCancelled()
            AppLogger.shared.log("Processing job cancelled: \(job.fileName)", category: .transcription)
            
        default:
            // Already finished, do nothing
            break
        }
    }
    
    /// Retry a failed job
    func retry(jobId: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == jobId }),
              jobs[index].canRetry else { return }
        
        jobs[index].prepareForRetry()
        AppLogger.shared.log("Job queued for retry: \(jobs[index].fileName) (attempt \(jobs[index].retryCount))", category: .transcription)
        
        // Start worker if needed
        startWorkerIfNeeded()
    }
    
    /// Remove a finished job from the list
    func remove(jobId: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == jobId }),
              jobs[index].status.isFinished else { return }
        
        let job = jobs.remove(at: index)
        AppLogger.shared.log("Job removed: \(job.fileName)", category: .transcription)
    }
    
    /// Clear all finished jobs
    func clearFinished() {
        jobs.removeAll { $0.status.isFinished }
        AppLogger.shared.log("Cleared all finished jobs", category: .transcription)
    }
    
    // MARK: - Worker
    
    private func startWorkerIfNeeded() {
        guard workerTask == nil || workerTask?.isCancelled == true else { return }
        
        workerTask = Task {
            await processQueue()
        }
    }
    
    private func processQueue() async {
        isProcessing = true
        
        while let nextJob = queuedJobs.first {
            // Check for cancellation
            if Task.isCancelled { break }
            
            await processJob(id: nextJob.id)
        }
        
        isProcessing = false
        workerTask = nil
        AppLogger.shared.log("Queue processing complete", category: .transcription)
    }
    
    private func processJob(id: UUID) async {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        
        currentJobId = id
        cancellationRequested = false
        preprocessor.resetCancellation()
        
        // Mark as processing
        jobs[index].markProcessing()
        
        let job = jobs[index]
        AppLogger.shared.log("Processing job: \(job.fileName)", category: .transcription)
        
        do {
            // Build preprocess options from job settings
            let preprocessOptions = AudioPreprocessor.Options(
                isolateVoice: job.settings.isolateVoice,
                denoise: job.settings.deepfilter,
                normalize: job.settings.normalize,
                useVAD: job.settings.useVAD
            )
            
            // Run transcription
            let result = try await transcriptionService.transcribe(
                file: job.fileURL,
                modelId: job.settings.selectedModelId,
                settings: job.settings,
                preprocessOptions: preprocessOptions,
                onProgress: { [weak self] progress, message in
                    Task { @MainActor in
                        self?.updateJobProgress(id: id, progress: Int(progress * 100), message: message)
                    }
                },
                onSegment: { [weak self] segment in
                    Task { @MainActor in
                        self?.appendJobStreamingText(id: id, text: segment.text + " ")
                    }
                }
            )
            
            // Check if cancelled during processing
            if cancellationRequested {
                if let idx = jobs.firstIndex(where: { $0.id == id }) {
                    jobs[idx].markCancelled()
                }
            } else {
                // Mark completed
                if let idx = jobs.firstIndex(where: { $0.id == id }) {
                    jobs[idx].markCompleted(with: result)
                    
                    // Save to history
                    await saveJobToHistory(job: jobs[idx])
                }
            }
            
        } catch {
            // Handle error
            if let idx = jobs.firstIndex(where: { $0.id == id }) {
                if cancellationRequested {
                    jobs[idx].markCancelled()
                } else {
                    jobs[idx].markFailed(error: error.localizedDescription)
                    AppLogger.shared.logError(error, context: "Job failed: \(job.fileName)", category: .transcription)
                }
            }
        }
        
        currentJobId = nil
    }
    
    // MARK: - Helpers
    
    private func updateJobProgress(id: UUID, progress: Int, message: String) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].updateProgress(progress, message: message)
    }
    
    private func appendJobStreamingText(id: UUID, text: String) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].appendStreamingText(text)
    }
    
    private func saveJobToHistory(job: TranscriptionJob) async {
        guard let result = job.result else { return }
        
        // Generate title
        let title: String
        let cleanedTitle = job.fileName
            .replacingOccurrences(of: "\\.[^.]+$", with: "", options: .regularExpression)
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespaces)
        title = cleanedTitle.isEmpty ? (isSpanishUI ? "Transcripción" : "Transcription") : String(cleanedTitle.prefix(50))
        
        // Persist audio
        let transcriptionId = job.id
        let persistedAudioURL: URL?
        if job.settings.keepAudioFileInHistory {
            persistedAudioURL = storage.persistAudioFile(from: job.fileURL, for: transcriptionId)
        } else {
            persistedAudioURL = nil
            // Defensive cleanup in case a file already exists for this job id.
            storage.deleteAudioFile(for: transcriptionId)
        }
        
        // Create transcription record
        let transcription = Transcription(
            id: transcriptionId,
            title: title,
            text: result.plainText,
            language: job.settings.language,
            duration: job.fileDuration ?? 0,
            createdAt: Date(),
            sourceURL: persistedAudioURL,
            segments: result.segments
        )
        
        storage.saveTranscription(transcription)
        AppLogger.shared.log("Job saved to history: \(title)", category: .transcription)
    }
}
