import Foundation

// MARK: - Job Status

/// Status of a transcription job in the queue
enum JobStatus: String, CaseIterable, Codable {
    case queued       // Waiting in queue
    case waitingModel // Waiting for its model to finish downloading
    case processing   // Downloading, preprocessing or transcribing
    case completed    // Successfully finished (moves to history)
    case failed       // Error occurred (stays until Retry or Remove)
    case cancelled    // User cancelled (leaves the list)
    case recoverable  // Did not finish last time the app ran (crash recovery)

    var icon: String {
        switch self {
        case .queued: return "clock"
        case .waitingModel: return "arrow.down.circle"
        case .processing: return "arrow.triangle.2.circlepath"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .cancelled: return "xmark.circle.fill"
        case .recoverable: return "arrow.counterclockwise"
        }
    }

    var color: String {
        switch self {
        case .queued, .waitingModel, .cancelled: return "textMuted"
        case .processing: return "accentPrimary"
        case .completed: return "successGreen"
        case .failed: return "errorRed"
        case .recoverable: return "warning"
        }
    }

    var displayName: String {
        switch self {
        case .queued: return "En espera"
        case .waitingModel: return "Esperando modelo"
        case .processing: return "Procesando"
        case .completed: return "Completado"
        case .failed: return "Error"
        case .cancelled: return "Cancelado"
        case .recoverable: return "Recuperable"
        }
    }

    var isFinished: Bool {
        self == .completed || self == .failed || self == .cancelled
    }

    /// Still visible in «En proceso».
    var isInProcessSection: Bool {
        self != .completed && self != .cancelled
    }
}

// MARK: - Job source (icon and status-line context in the queue)

enum JobSource: Equatable {
    case file
    case url(String)
    case recording(microphone: Bool)
    case watchedFolder(name: String)
    case cli
    case recovered

    var systemImage: String {
        switch self {
        case .file, .cli: return "doc"
        case .url: return "link"
        case .recording: return "mic"
        case .watchedFolder: return "folder"
        case .recovered: return "arrow.counterclockwise"
        }
    }
}

/// How a link is resolved (only YouTube offers the subtitles method).
enum URLJobMethod: String, Equatable {
    /// Download the audio with yt-dlp and transcribe it on this Mac.
    case audio
    /// Use the video's own subtitles (youtube-transcript-api / Innertube); no audio, no timestamps.
    case subtitles
}

// MARK: - Phase (what the process is doing right now, spec 8.1)

enum JobPhase: Equatable {
    case queued
    case waitingModel
    case downloading(received: Int64?, total: Int64?, fraction: Double?)
    case retryingDownload
    case fetchingSubtitles
    case loadingModel
    case preprocessing(detail: String?)
    case transcribing
    /// First use of «Identificar hablantes»: the speaker models are downloaded once.
    case downloadingSpeakerModels(fraction: Double?)
    case detectingSpeakers(fraction: Double?)
    case finishing
}

/// Structured error kept with the job so the views can show title, explanation,
/// action and folded technical details (spec 8.3 and 8.4).
struct JobError: Equatable {
    enum Kind: Equatable {
        case link(URLTranscriptionService.TranscriptionError)
        case missingDependency(String)
        case unreadableFile
        case engine
        case modelDownload(String)
        case other
    }
    var kind: Kind
    var message: String
    var technicalDetails: String?
}

extension URLTranscriptionService.TranscriptionError: Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.errorDescription == rhs.errorDescription
    }
}

/// A segment received while the engine is still running (F04, streaming).
struct StreamSegment: Identifiable, Equatable {
    let id = UUID()
    let start: TimeInterval
    let end: TimeInterval
    let text: String
}

// MARK: - Transcription Job

/// A single transcription job in the queue
struct TranscriptionJob: Identifiable, Equatable {
    let id: UUID
    /// Local file to transcribe. For link jobs this is the remote URL until the audio is downloaded.
    var fileURL: URL
    var fileName: String
    var fileDuration: TimeInterval?
    var source: JobSource

    // Status
    var status: JobStatus
    var phase: JobPhase
    var progress: Int  // 0-100
    /// Whether `progress` comes from the engine (never simulate a percentage).
    var hasMeasuredProgress: Bool
    var statusMessage: String
    var streamingText: String
    var streamSegments: [StreamSegment]

    // Timestamps
    let createdAt: Date
    var startedAt: Date?
    var completedAt: Date?

    // Retry logic
    var retryCount: Int
    static let maxRetries = 3

    // Error info
    var errorMessage: String?
    var error: JobError?

    // Result (only when completed)
    var result: TranscriptionResult?
    /// History id written on completion (same as `id`).
    var historyId: UUID? { status == .completed ? id : nil }

    // Settings snapshot (frozen at queue time)
    var settings: TranscriptionSettings
    var urlMethod: URLJobMethod?
    /// The video had no subtitles: the audio is transcribed instead (warning, not an error).
    var subtitlesFallback = false
    /// Preset name shown in the job summary («Clase», «Podcast», «Entrevista» or nil for custom).
    var presetName: String?
    /// Aviso o idioma detectado en proceso (p. ej. "Idioma detectado: ko").
    var languageNotice: String?

    // MARK: - Initialization

    init(
        id: UUID = UUID(),
        fileURL: URL,
        fileName: String,
        fileDuration: TimeInterval? = nil,
        settings: TranscriptionSettings,
        source: JobSource = .file,
        urlMethod: URLJobMethod? = nil,
        presetName: String? = nil
    ) {
        self.id = id
        self.fileURL = fileURL
        self.fileName = fileName
        self.fileDuration = fileDuration
        self.source = source
        self.status = .queued
        self.phase = .queued
        self.progress = 0
        self.hasMeasuredProgress = false
        self.statusMessage = "En cola"
        self.streamingText = ""
        self.streamSegments = []
        self.createdAt = Date()
        self.startedAt = nil
        self.completedAt = nil
        self.retryCount = 0
        self.errorMessage = nil
        self.error = nil
        self.result = nil
        self.settings = settings
        self.urlMethod = urlMethod
        self.presetName = presetName
    }

    // MARK: - Computed Properties

    var isLink: Bool {
        if case .url = source { return true }
        return false
    }

    var canRetry: Bool {
        (status == .failed && retryCount < Self.maxRetries) || status == .recoverable
    }

    var canCancel: Bool {
        status == .queued || status == .processing || status == .waitingModel
    }

    /// A cancelled job can be queued again only if its input still exists.
    var canRequeueAfterCancel: Bool {
        isLink || FileManager.default.fileExists(atPath: fileURL.path)
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

    /// Display title: file name without extension, or the link while it is downloading.
    var displayTitle: String {
        if isLink, !fileURL.isFileURL, case .url(let link) = source { return link }
        let base = (fileName as NSString).deletingPathExtension
        return base.isEmpty ? fileName : base
    }

    // MARK: - Mutations

    mutating func markProcessing() {
        status = .processing
        startedAt = Date()
        statusMessage = "Iniciando..."
        progress = 0
        hasMeasuredProgress = false
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
        phase = .finishing
        completedAt = Date()
        progress = 100
        statusMessage = "Completado"
        self.result = result
    }

    mutating func markFailed(error: String, info: JobError? = nil) {
        status = .failed
        completedAt = Date()
        errorMessage = error
        self.error = info ?? JobError(kind: .other, message: error, technicalDetails: nil)
        statusMessage = "Error"
    }

    mutating func markCancelled() {
        status = .cancelled
        completedAt = Date()
        statusMessage = "Cancelado"
    }

    mutating func prepareForRetry() {
        guard canRetry else { return }
        if status == .failed { retryCount += 1 }
        status = .queued
        phase = .queued
        progress = 0
        hasMeasuredProgress = false
        statusMessage = "En cola"
        streamingText = ""
        streamSegments = []
        startedAt = nil
        completedAt = nil
        errorMessage = nil
        error = nil
        result = nil
    }

    // MARK: - Equatable

    /// Compares everything the interface shows. SwiftUI skips redrawing views whose `job`
    /// input is equal, so an id-only comparison froze rows and the job view on «En cola».
    static func == (lhs: TranscriptionJob, rhs: TranscriptionJob) -> Bool {
        lhs.id == rhs.id
            && lhs.status == rhs.status
            && lhs.phase == rhs.phase
            && lhs.progress == rhs.progress
            && lhs.hasMeasuredProgress == rhs.hasMeasuredProgress
            && lhs.statusMessage == rhs.statusMessage
            && lhs.streamSegments.count == rhs.streamSegments.count
            && lhs.fileName == rhs.fileName
            && lhs.fileURL == rhs.fileURL
            && lhs.fileDuration == rhs.fileDuration
            && lhs.error == rhs.error
            && lhs.errorMessage == rhs.errorMessage
            && lhs.retryCount == rhs.retryCount
            && lhs.startedAt == rhs.startedAt
            && lhs.completedAt == rhs.completedAt
            && lhs.urlMethod == rhs.urlMethod
            && lhs.subtitlesFallback == rhs.subtitlesFallback
            && lhs.settings.selectedModelId == rhs.settings.selectedModelId
            && lhs.presetName == rhs.presetName
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
        self.queued = jobs.filter { $0.status == .queued || $0.status == .waitingModel }.count
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
