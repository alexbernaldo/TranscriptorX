import Foundation

// MARK: - Job Status

/// Status of a transcription job in the queue
enum JobStatus: String, CaseIterable, Codable {
    case queued      // 🕒 Waiting in queue
    case processing  // 🔵 Currently transcribing
    case completed   // 🟢 Successfully finished
    case failed      // 🔴 Error occurred
    case cancelled   // ⚫ User cancelled
    
    var icon: String {
        switch self {
        case .queued: return "clock"
        case .processing: return "arrow.triangle.2.circlepath"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .cancelled: return "xmark.circle.fill"
        }
    }
    
    var color: String {
        switch self {
        case .queued: return "textMuted"
        case .processing: return "accentPrimary"
        case .completed: return "successGreen"
        case .failed: return "errorRed"
        case .cancelled: return "textMuted"
        }
    }
    
    var displayName: String {
        switch self {
        case .queued: return "En espera"
        case .processing: return "Procesando"
        case .completed: return "Completado"
        case .failed: return "Error"
        case .cancelled: return "Cancelado"
        }
    }
    
    var isFinished: Bool {
        self == .completed || self == .failed || self == .cancelled
    }
}

// MARK: - Transcription Job

/// A single transcription job in the queue
struct TranscriptionJob: Identifiable, Equatable {
    let id: UUID
    let fileURL: URL
    let fileName: String
    let fileDuration: TimeInterval?
    
    // Status
    var status: JobStatus
    var progress: Int  // 0-100
    var statusMessage: String
    var streamingText: String
    
    // Timestamps
    let createdAt: Date
    var startedAt: Date?
    var completedAt: Date?
    
    // Retry logic
    var retryCount: Int
    static let maxRetries = 3
    
    // Error info
    var errorMessage: String?
    
    // Result (only when completed)
    var result: TranscriptionResult?
    
    // Settings snapshot (frozen at queue time)
    let settings: TranscriptionSettings
    
    // MARK: - Initialization
    
    init(
        fileURL: URL,
        fileName: String,
        fileDuration: TimeInterval? = nil,
        settings: TranscriptionSettings
    ) {
        self.id = UUID()
        self.fileURL = fileURL
        self.fileName = fileName
        self.fileDuration = fileDuration
        self.status = .queued
        self.progress = 0
        self.statusMessage = "En cola"
        self.streamingText = ""
        self.createdAt = Date()
        self.startedAt = nil
        self.completedAt = nil
        self.retryCount = 0
        self.errorMessage = nil
        self.result = nil
        self.settings = settings
    }
    
    // MARK: - Computed Properties
    
    var canRetry: Bool {
        status == .failed && retryCount < Self.maxRetries
    }
    
    var canCancel: Bool {
        status == .queued || status == .processing
    }
    
    var elapsedTime: TimeInterval? {
        guard let start = startedAt else { return nil }
        let end = completedAt ?? Date()
        return end.timeIntervalSince(start)
    }
    
    var formattedElapsedTime: String {
        guard let elapsed = elapsedTime else { return "--:--" }
        let minutes = Int(elapsed) / 60
        let seconds = Int(elapsed) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
    
    var formattedDuration: String {
        guard let duration = fileDuration else { return "--:--" }
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
    
    // MARK: - Mutations
    
    mutating func markProcessing() {
        status = .processing
        startedAt = Date()
        statusMessage = "Iniciando..."
        progress = 0
    }
    
    mutating func updateProgress(_ newProgress: Int, message: String) {
        progress = min(100, max(0, newProgress))
        statusMessage = message
    }
    
    mutating func appendStreamingText(_ text: String) {
        streamingText += text
    }
    
    mutating func markCompleted(with result: TranscriptionResult) {
        status = .completed
        completedAt = Date()
        progress = 100
        statusMessage = "Completado"
        self.result = result
    }
    
    mutating func markFailed(error: String) {
        status = .failed
        completedAt = Date()
        errorMessage = error
        statusMessage = "Error"
    }
    
    mutating func markCancelled() {
        status = .cancelled
        completedAt = Date()
        statusMessage = "Cancelado"
    }
    
    mutating func prepareForRetry() {
        guard canRetry else { return }
        retryCount += 1
        status = .queued
        progress = 0
        statusMessage = "Reintentando (\(retryCount)/\(Self.maxRetries))"
        streamingText = ""
        startedAt = nil
        completedAt = nil
        errorMessage = nil
        result = nil
    }
    
    // MARK: - Equatable
    
    static func == (lhs: TranscriptionJob, rhs: TranscriptionJob) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Job Queue Statistics

struct JobQueueStats {
    let total: Int
    let queued: Int
    let processing: Int
    let completed: Int
    let failed: Int
    
    init(jobs: [TranscriptionJob]) {
        self.total = jobs.count
        self.queued = jobs.filter { $0.status == .queued }.count
        self.processing = jobs.filter { $0.status == .processing }.count
        self.completed = jobs.filter { $0.status == .completed }.count
        self.failed = jobs.filter { $0.status == .failed }.count
    }
    
    var hasActiveJobs: Bool {
        queued > 0 || processing > 0
    }
    
    var summary: String {
        if processing > 0 {
            return "Procesando \(processing), \(queued) en cola"
        } else if queued > 0 {
            return "\(queued) en cola"
        } else if completed > 0 {
            return "\(completed) completados"
        } else {
            return "Sin trabajos"
        }
    }
}
