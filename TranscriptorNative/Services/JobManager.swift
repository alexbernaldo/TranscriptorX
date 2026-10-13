import Foundation
import Combine
import AVFoundation

/// A job that just moved from «En proceso» to the history.
struct JobCompletion: Identifiable, Equatable {
    let id: UUID          // job id == history id
    let title: String
    let date: Date
}

/// Undo information for a cancelled job («Trabajo cancelado · Deshacer»).
struct CancelledJob {
    let job: TranscriptionJob
    let index: Int
}

/// Manages the queue of transcription jobs.
/// Processes jobs serially (one at a time) to avoid GPU/memory overload.
/// The sidebar section «En proceso», the job view and the menu-bar summary
/// are all representations of `jobs` (single source of truth, spec 4.2).
@MainActor
final class JobManager: ObservableObject {

    // MARK: - Singleton
    static let shared = JobManager()

    // MARK: - Published State
    @Published private(set) var jobs: [TranscriptionJob] = []
    @Published private(set) var isProcessing = false
    /// Completions of this session, newest first (menu bar «Última», «Lista» tag for 4 s).
    @Published private(set) var completions: [JobCompletion] = []

    /// Emits when a job finishes and its document is in the history.
    let completed = PassthroughSubject<JobCompletion, Never>()
    /// Emits phase changes worth announcing to VoiceOver («Clase_04, transcribiendo»).
    let phaseAnnouncements = PassthroughSubject<String, Never>()
    /// Live captions and other listeners of streamed segments.
    var onStreamSegment: ((UUID, StreamSegment) -> Void)?
    var onJobFinished: ((UUID) -> Void)?

    // MARK: - Services
    private let transcriptionService = TranscriptionService.shared
    private let preprocessor = AudioPreprocessor.shared
    private let storage = TranscriptionStorage.shared
    private let urlService = URLTranscriptionService.shared

    // MARK: - Worker State
    private var workerTask: Task<Void, Never>?
    private var currentJobId: UUID?
    private var cancellationRequested = false
    private var linkObservers = Set<AnyCancellable>()

    private var isSpanishUI: Bool {
        UserDefaults.standard.string(forKey: "app_ui_language") == "es"
    }

    private func localized(_ es: String, _ en: String) -> String { isSpanishUI ? es : en }

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

    /// Jobs shown in «En proceso»: the active one first, then the waiting order.
    var inProcessJobs: [TranscriptionJob] {
        let visible = jobs.filter { $0.status.isInProcessSection }
        return visible.filter { $0.status == .processing } + visible.filter { $0.status != .processing }
    }

    /// Number of jobs waiting or running (toolbar «2 en cola», menu bar state).
    var activeCount: Int {
        jobs.filter { $0.status == .processing || $0.status == .queued || $0.status == .waitingModel }.count
    }

    var recoverableJobs: [TranscriptionJob] { jobs.filter { $0.status == .recoverable } }

    /// 1-based position among jobs waiting for their turn («En cola · 2.º»).
    func queuePosition(of id: UUID) -> Int? {
        let waiting = jobs.filter { $0.status == .queued || $0.status == .processing }
        guard let idx = waiting.firstIndex(where: { $0.id == id }) else { return nil }
        return idx + (waiting.contains { $0.status == .processing } ? 0 : 1)
    }

    /// Model actually loaded in a running whisper process or retained in memory by FluidAudio (sidebar footer, spec 8.6).
    var modelInUse: String? {
        if let memoryModel = ModelMemoryManager.shared.activeModelId {
            return memoryModel
        }
        guard let job = currentJob else { return nil }
        switch job.phase {
        case .loadingModel, .transcribing: return job.settings.selectedModelId
        default: return nil
        }
    }

    func job(_ id: UUID) -> TranscriptionJob? { jobs.first { $0.id == id } }

    var stats: JobQueueStats {
        JobQueueStats(jobs: jobs)
    }

    // MARK: - Initialization

    private init() {
        AppLogger.shared.log("JobManager initialized", category: .transcription)
    }

    // MARK: - Public API

    /// Add a single file to the queue.
    /// - Parameters:
    ///   - atFront: «Transcribir antes que los demás» (right after the active job).
    ///   - userInitiated: only explicit user actions start a missing model download.
    @discardableResult
    func enqueue(
        fileURL: URL,
        fileName: String,
        fileDuration: TimeInterval? = nil,
        settings: TranscriptionSettings,
        source: JobSource = .file,
        presetName: String? = nil,
        atFront: Bool = false,
        userInitiated: Bool = false
    ) -> UUID {
        let task: ModelTask
        if case .recording = source { task = .recording } else { task = .files }
        var job = TranscriptionJob(
            fileURL: fileURL,
            fileName: fileName,
            fileDuration: fileDuration,
            settings: settings,
            source: source,
            presetName: presetName
        )
        applyModelSelection(to: &job, task: task)
        applyModelAvailability(to: &job, userInitiated: userInitiated)
        insert(job, atFront: atFront)
        AppLogger.shared.log("Job enqueued: \(fileName) (ID: \(job.id))", category: .transcription)
        if job.fileDuration == nil { loadDuration(for: job.id, url: fileURL) }
        startWorkerIfNeeded()
        return job.id
    }

    /// Add multiple files to the queue (CLI, legacy callers).
    @discardableResult
    func enqueue(
        files: [(url: URL, name: String, duration: TimeInterval?)],
        settings: TranscriptionSettings,
        source: JobSource = .file
    ) -> [UUID] {
        files.map { file in
            enqueue(fileURL: file.url, fileName: file.name, fileDuration: file.duration,
                    settings: settings, source: source)
        }
    }

    /// Add a link. The audio (or the YouTube subtitles) is fetched when the job reaches the front.
    @discardableResult
    func enqueueLink(
        _ link: String,
        method: URLJobMethod,
        settings: TranscriptionSettings,
        presetName: String? = nil
    ) -> UUID {
        let url = URL(string: link) ?? URL(fileURLWithPath: "/")
        var job = TranscriptionJob(
            fileURL: url,
            fileName: url.host ?? link,
            settings: settings,
            source: .url(link),
            urlMethod: method,
            presetName: presetName
        )
        applyModelSelection(to: &job, task: .files)
        if method == .audio { applyModelAvailability(to: &job, userInitiated: true) }
        insert(job, atFront: false)
        startWorkerIfNeeded()
        return job.id
    }

    /// Cancel a job. Returns undo information when the job can be queued again.
    @discardableResult
    func cancel(jobId: UUID) -> CancelledJob? {
        guard let index = jobs.firstIndex(where: { $0.id == jobId }) else { return nil }
        let job = jobs[index]
        let snapshot = CancelledJob(job: job, index: index)

        switch job.status {
        case .queued, .waitingModel, .recoverable:
            jobs.remove(at: index)
            AppLogger.shared.log("Queued job removed: \(job.fileName)", category: .transcription)
        case .processing:
            cancellationRequested = true
            if job.isLink { urlService.cancel() }
            transcriptionService.cancel()
            preprocessor.cancel()
            jobs[index].markCancelled()
            AppLogger.shared.log("Processing job cancelled: \(job.fileName)", category: .transcription)
        default:
            return nil
        }
        return job.canRequeueAfterCancel ? snapshot : nil
    }

    /// Undo of a cancellation: the job goes back to its previous place, from the start.
    func requeue(_ cancelled: CancelledJob) {
        var job = cancelled.job
        jobs.removeAll { $0.id == job.id }
        job.status = .queued
        job.phase = .queued
        job.progress = 0
        job.hasMeasuredProgress = false
        job.streamingText = ""
        job.streamSegments = []
        job.startedAt = nil
        job.completedAt = nil
        let waitingStart = jobs.firstIndex { $0.status != .processing } ?? jobs.count
        jobs.insert(job, at: min(max(cancelled.index, waitingStart), jobs.count))
        startWorkerIfNeeded()
    }

    /// Retry a failed job, or resume a recoverable one.
    func retry(jobId: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == jobId }),
              jobs[index].canRetry else { return }
        jobs[index].prepareForRetry()
        var job = jobs[index]
        applyModelAvailability(to: &job, userInitiated: true)
        jobs[index] = job
        AppLogger.shared.log("Job queued for retry: \(jobs[index].fileName) (attempt \(jobs[index].retryCount))", category: .transcription)
        startWorkerIfNeeded()
    }

    /// Retry with another model («Probar con otro modelo»).
    func retry(jobId: UUID, modelId: String) {
        guard let index = jobs.firstIndex(where: { $0.id == jobId }) else { return }
        jobs[index].settings.selectedModelId = modelId
        jobs[index].presetName = nil
        jobs[index].modelWasAutomatic = false
        jobs[index].modelNotice = nil
        retry(jobId: jobId)
    }

    /// Replace the link of a failed link job («Cambiar enlace»).
    func changeLink(jobId: UUID, to link: String) {
        guard let index = jobs.firstIndex(where: { $0.id == jobId }), let url = URL(string: link) else { return }
        jobs[index].source = .url(link)
        jobs[index].fileURL = url
        jobs[index].fileName = url.host ?? link
        jobs[index].retryCount = 0
        if jobs[index].status == .failed { retry(jobId: jobId) }
    }

    func resumeAllRecoverable() {
        for job in recoverableJobs { retry(jobId: job.id) }
    }

    /// Remove a finished/failed/recoverable job from the list («Quitar de la cola», «Descartar»).
    func remove(jobId: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == jobId }),
              jobs[index].status.isFinished || jobs[index].status == .recoverable else { return }
        let job = jobs.remove(at: index)
        AppLogger.shared.log("Job removed: \(job.fileName)", category: .transcription)
    }

    /// Clear all finished jobs
    func clearFinished() {
        jobs.removeAll { $0.status.isFinished }
        AppLogger.shared.log("Cleared all finished jobs", category: .transcription)
    }

    // MARK: Priority (the active job cannot move)

    enum Move { case top, up, down, bottom }

    func canMove(_ id: UUID, _ move: Move) -> Bool {
        let waiting = waitingIndices
        guard let pos = waiting.firstIndex(where: { jobs[$0].id == id }) else { return false }
        switch move {
        case .top, .up: return pos > 0
        case .down, .bottom: return pos < waiting.count - 1
        }
    }

    func move(_ id: UUID, _ move: Move) {
        var order = waitingIndices.map { jobs[$0] }
        guard let pos = order.firstIndex(where: { $0.id == id }) else { return }
        let job = order.remove(at: pos)
        let target: Int
        switch move {
        case .top: target = 0
        case .up: target = max(0, pos - 1)
        case .down: target = min(order.count, pos + 1)
        case .bottom: target = order.count
        }
        order.insert(job, at: target)
        applyWaitingOrder(order)
    }

    /// Drag and drop reorder within the waiting jobs.
    func moveWaiting(fromOffsets source: IndexSet, toOffset destination: Int) {
        var order = waitingIndices.map { jobs[$0] }
        let moving = source.map { order[$0] }
        let adjusted = destination - source.filter { $0 < destination }.count
        order.remove(atOffsets: source)
        order.insert(contentsOf: moving, at: min(max(adjusted, 0), order.count))
        applyWaitingOrder(order)
    }

    private var waitingIndices: [Int] {
        jobs.indices.filter { jobs[$0].status == .queued || jobs[$0].status == .waitingModel || jobs[$0].status == .recoverable || jobs[$0].status == .failed }
    }

    private func applyWaitingOrder(_ order: [TranscriptionJob]) {
        let fixed = jobs.filter { !(order.map(\.id).contains($0.id)) }
        jobs = fixed.filter { $0.status == .processing } + order + fixed.filter { $0.status != .processing }
    }

    // MARK: Models

    /// «Automático» (o un modelo que no admite el idioma) pasa a un modelo concreto antes de
    /// entrar en la cola. Si el modelo cambia, un banner lo explica (nunca una alerta modal).
    private func applyModelSelection(to job: inout TranscriptionJob, task: ModelTask) {
        let prepared = ModelSelection.prepare(job.settings, task: task,
                                              filesAssignment: TaskModelPreferences.shared.filesAssignment)
        job.settings = prepared.settings
        job.modelWasAutomatic = prepared.wasAutomatic
        job.modelNotice = prepared.notice
        if case .incompatible(let requested, let used, let reason)? = prepared.notice {
            WorkspaceState.shared.post(BannerItem(
                key: "model-switch:\(job.id)", kind: .info,
                title: ModelNoticeText.switched(requested: requested, used: used, reason: reason, language: job.settings.language),
                message: nil, details: nil))
        }
    }

    private func applyModelAvailability(to job: inout TranscriptionJob, userInitiated: Bool) {
        if job.isLink && job.urlMethod == .subtitles { return }
        let modelId = job.settings.selectedModelId
        guard !transcriptionService.isModelDownloaded(modelId) else { return }
        job.status = .waitingModel
        job.phase = .waitingModel
        // Lanzar una función sin modelo descarga el elegido, o el de Automático (decisión del usuario).
        if userInitiated { ModelDownloadCenter.shared.download(modelId) }
    }

    func modelBecameAvailable(_ modelId: String) {
        for i in jobs.indices where jobs[i].status == .waitingModel && jobs[i].settings.selectedModelId == modelId {
            jobs[i].status = .queued
            jobs[i].phase = .queued
        }
        startWorkerIfNeeded()
    }

    func modelDownloadCancelled(_ modelId: String) {
        // Jobs keep waiting; their row offers «Descargar» again.
        objectWillChange.send()
    }

    // MARK: Recovery

    /// Adds jobs that did not finish the last time (crash recovery, spec 6.26).
    func restoreRecoverable(_ items: [RecoveryManager.RecoveredItem], defaults: TranscriptionSettings) {
        for item in items {
            guard !jobs.contains(where: { $0.id == item.id }) else { continue }
            let input: URL
            switch item.type {
            case .audio: input = item.fileURL
            case .transcription:
                guard let source = item.sourceAudioURL, FileManager.default.fileExists(atPath: source.path) else { continue }
                input = source
            }
            var settings = defaults
            if let model = item.modelId { settings.selectedModelId = model }
            var job = TranscriptionJob(id: item.id, fileURL: input, fileName: input.lastPathComponent,
                                       fileDuration: item.duration, settings: settings, source: .recovered)
            job.status = .recoverable
            job.phase = .queued
            jobs.append(job)
        }
    }

    // MARK: - Worker

    private func insert(_ job: TranscriptionJob, atFront: Bool) {
        if atFront {
            let index = jobs.firstIndex { $0.status != .processing } ?? jobs.count
            jobs.insert(job, at: index)
        } else {
            jobs.append(job)
        }
    }

    private func loadDuration(for id: UUID, url: URL) {
        guard url.isFileURL else { return }
        Task {
            let asset = AVURLAsset(url: url)
            guard let d = try? await asset.load(.duration) else { return }
            let seconds = CMTimeGetSeconds(d)
            guard seconds.isFinite, seconds > 0, let i = jobs.firstIndex(where: { $0.id == id }) else { return }
            jobs[i].fileDuration = seconds
        }
    }

    private func startWorkerIfNeeded() {
        guard workerTask == nil || workerTask?.isCancelled == true else { return }
        guard jobs.contains(where: { $0.status == .queued }) else { return }

        workerTask = Task {
            await processQueue()
        }
    }

    private func processQueue() async {
        isProcessing = true

        while let nextJob = jobs.first(where: { $0.status == .queued }) {
            if Task.isCancelled { break }
            await processJob(id: nextJob.id)
            pruneCompleted()
        }

        isProcessing = false
        workerTask = nil
        AppLogger.shared.log("Queue processing complete", category: .transcription)
    }

    /// Completed jobs stay briefly so `tx` can read the result, then leave the list.
    private func pruneCompleted() {
        let cutoff = Date().addingTimeInterval(-120)
        jobs.removeAll { ($0.status == .completed || $0.status == .cancelled) && ($0.completedAt ?? .distantPast) < cutoff }
    }

    private func setPhase(_ id: UUID, _ phase: JobPhase) {
        guard let i = jobs.firstIndex(where: { $0.id == id }), jobs[i].phase != phase else { return }
        let announce: Bool
        switch (jobs[i].phase, phase) {
        case (.downloading, .downloading),
             (.downloadingSpeakerModels, .downloadingSpeakerModels),
             (.detectingSpeakers, .detectingSpeakers): announce = false
        default: announce = true
        }
        jobs[i].phase = phase
        if announce, let text = Self.announcement(for: jobs[i]) {
            phaseAnnouncements.send(text)
        }
    }

    private static func announcement(for job: TranscriptionJob) -> String? {
        let es = UserDefaults.standard.string(forKey: "app_ui_language") == "es"
        let state: String
        switch job.phase {
        case .downloading: state = es ? "descargando" : "downloading"
        case .loadingModel: state = es ? "cargando modelo" : "loading model"
        case .preprocessing: state = es ? "preprocesando audio" : "preprocessing audio"
        case .transcribing: state = es ? "transcribiendo" : "transcribing"
        case .detectingSpeakers: state = es ? "identificando hablantes" : "identifying speakers"
        default: return nil
        }
        return "\(job.displayTitle), \(state)"
    }

    private func processJob(id: UUID) async {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }

        currentJobId = id
        cancellationRequested = false
        preprocessor.resetCancellation()
        jobs[index].markProcessing()

        // Links: fetch subtitles or audio first.
        if jobs[index].isLink {
            let handled = await processLinkStage(id: id)
            if handled { currentJobId = nil; return }
            guard let i = jobs.firstIndex(where: { $0.id == id }), jobs[i].status == .processing else {
                currentJobId = nil; return
            }
        }

        // Automático sin idioma: Whisper escucha 30 s y, si el idioma lo admite Rápido, se usa Rápido.
        if let pending = self.job(id), pending.modelWasAutomatic, pending.settings.language == "auto",
           ModelCatalog.descriptor(id: pending.settings.selectedModelId)?.engine == .whisper,
           let refined = await refineAutomaticModel(for: pending),
           let i = jobs.firstIndex(where: { $0.id == id }), jobs[i].status == .processing {
            jobs[i].settings.selectedModelId = refined.modelId
            jobs[i].languageNotice = refined.notice
            jobs[i].detectedLanguage = refined.language
        }

        guard let jobIndex = jobs.firstIndex(where: { $0.id == id }), jobs[jobIndex].status == .processing else {
            currentJobId = nil; return
        }
        let job = jobs[jobIndex]

        // The model could have been removed after queueing.
        if !transcriptionService.isModelDownloaded(job.settings.selectedModelId) {
            jobs[jobIndex].status = .waitingModel
            jobs[jobIndex].phase = .waitingModel
            currentJobId = nil
            return
        }

        AppLogger.shared.log("Processing job: \(job.fileName)", category: .transcription)

        let walSessionId = try? await RecoveryManager.shared.beginTranscriptionSession(
            audioURL: job.fileURL,
            modelId: job.settings.selectedModelId
        )
        var walDidUpdate = false
        var walSegmentCount = 0
        var walPendingSegments: [RecoveryManager.TranscriptionManifest.PartialSegment] = []

        do {
            let preprocessOptions = AudioPreprocessor.Options(
                isolateVoice: job.settings.isolateVoice,
                denoise: job.settings.deepfilter,
                normalize: job.settings.normalize,
                useVAD: job.settings.useVAD
            )

            let result = try await transcriptionService.transcribe(
                file: job.fileURL,
                modelId: job.settings.selectedModelId,
                settings: job.settings,
                preprocessOptions: preprocessOptions,
                onProgress: { [weak self] progress, message in
                    Task { @MainActor in
                        self?.updateJobProgress(id: id, overall: progress, message: message)
                    }
                },
                onSegment: { [weak self] segment in
                    walSegmentCount += 1
                    walPendingSegments.append(
                        RecoveryManager.TranscriptionManifest.PartialSegment(
                            startTime: segment.startTime,
                            endTime: segment.endTime,
                            text: segment.text,
                            speaker: nil))
                    if !walDidUpdate || walSegmentCount % 10 == 0 {
                        walDidUpdate = true
                        let batch = walPendingSegments
                        walPendingSegments.removeAll(keepingCapacity: true)
                        if let walSessionId {
                            Task { try? await RecoveryManager.shared.updateTranscriptionProgress(
                                sessionId: walSessionId, status: .processing, newSegments: batch) }
                        }
                    }
                    Task { @MainActor in
                        self?.appendStreamSegment(id: id, segment: segment)
                        self?.noteDetectedLanguage(id: id)
                    }
                },
                onPhase: { [weak self] phase in
                    Task { @MainActor in self?.setPhase(id, phase) }
                }
            )

            if cancellationRequested {
                if let idx = jobs.firstIndex(where: { $0.id == id }) {
                    jobs[idx].markCancelled()
                    if let walSessionId { try? await RecoveryManager.shared.completeTranscriptionSession(sessionId: walSessionId) }
                }
            } else if let idx = jobs.firstIndex(where: { $0.id == id }) {
                if let speakerError = result.speakerDetectionError {
                    // The text is kept; only the speakers are missing.
                    WorkspaceState.shared.post(BannerItem(
                        key: "speakers:\(id)", kind: .warning,
                        title: TXL.f("speakers.failed.title", "No se pudieron identificar los hablantes de %@", jobs[idx].displayTitle),
                        message: TXL.t("speakers.failed.message", "La transcripción se ha guardado sin hablantes. La primera vez hace falta conexión para descargar el modelo de hablantes."),
                        details: speakerError))
                }
                jobs[idx].markCompleted(with: result)
                await saveJobToHistory(job: jobs[idx])
                if let walSessionId { try? await RecoveryManager.shared.completeTranscriptionSession(sessionId: walSessionId) }
            }

        } catch {
            if let idx = jobs.firstIndex(where: { $0.id == id }) {
                if cancellationRequested || error is CancellationError {
                    jobs[idx].markCancelled()
                    if let walSessionId { try? await RecoveryManager.shared.completeTranscriptionSession(sessionId: walSessionId) }
                } else {
                    jobs[idx].markFailed(error: error.localizedDescription, info: Self.classify(error))
                    if let walSessionId {
                        let batch = walPendingSegments
                        walPendingSegments.removeAll(keepingCapacity: true)
                        try? await RecoveryManager.shared.updateTranscriptionProgress(
                            sessionId: walSessionId, status: .interrupted, newSegments: batch)
                    }
                    AppLogger.shared.logError(error, context: "Job failed: \(job.fileName)", category: .transcription)
                }
            }
        }

        onJobFinished?(id)
        currentJobId = nil
    }

    /// Probe de idioma (Whisper, 30 s) para Automático. Devuelve el modelo afinado o `nil`.
    private func refineAutomaticModel(for job: TranscriptionJob) async -> (modelId: String, notice: String, language: String)? {
        let fast = ModelEngineSettings.fastModelId
        let installed = ModelStorageService.shared.installedModelIds()
        guard installed.contains(fast),
              let whisper = ModelResolver.whisperFallbackOrder.reversed().first(where: { installed.contains($0) }),
              let language = await transcriptionService.detectLanguage(file: job.fileURL, modelId: whisper) else { return nil }
        let task: ModelTask
        if case .recording = job.source { task = .recording } else { task = .files }
        var probe = job.settings
        probe.language = language
        probe.selectedModelId = ModelSelection.autoToken
        let refined = ModelSelection.prepare(probe, task: task).settings.selectedModelId
        guard installed.contains(refined) else { return nil }
        AppLogger.shared.log("Language probe: \(language) → \(refined)", category: .transcription)
        return (refined, TXL.f("job.languageDetected", "Idioma detectado: %@", TXFormat.languageName(language)), language)
    }

    /// Rápido no dice qué idioma oye: se deduce del texto en cuanto llegan los segmentos.
    private func noteDetectedLanguage(id: UUID) {
        guard let i = jobs.firstIndex(where: { $0.id == id }), jobs[i].languageNotice == nil,
              jobs[i].settings.language == "auto",
              ModelCatalog.descriptor(id: jobs[i].settings.selectedModelId)?.engine == .parakeet,
              let code = ParakeetEngine.detectLanguage(of: jobs[i].streamingText) else { return }
        jobs[i].languageNotice = TXL.f("job.languageDetected", "Idioma detectado: %@", TXFormat.languageName(code))
        jobs[i].detectedLanguage = code
    }

    /// Maps engine errors to the user-facing kinds of spec 8.4.
    static func classify(_ error: Error) -> JobError {
        let es = UserDefaults.standard.string(forKey: "app_ui_language") == "es"
        if let pre = error as? PreprocessorError {
            switch pre {
            case .ffmpegNotFound:
                return JobError(kind: .missingDependency("FFmpeg"), message: es ? "Falta FFmpeg" : "FFmpeg is missing",
                                technicalDetails: pre.errorDescription)
            case .conversionFailed(let detail):
                return JobError(kind: .unreadableFile, message: pre.errorDescription ?? "", technicalDetails: detail)
            default:
                return JobError(kind: .engine, message: pre.errorDescription ?? "", technicalDetails: nil)
            }
        }
        if let te = error as? TranscriptionError {
            switch te {
            case .whisperNotInstalled:
                return JobError(kind: .missingDependency("whisper"), message: es ? "Falta whisper" : "whisper is missing",
                                technicalDetails: te.errorDescription)
            default:
                return JobError(kind: .engine, message: te.errorDescription ?? "", technicalDetails: te.errorDescription)
            }
        }
        return JobError(kind: .other, message: error.localizedDescription, technicalDetails: String(describing: error))
    }

    // MARK: Link stage

    /// Returns true when the job was fully handled here (subtitles document or failure).
    private func processLinkStage(id: UUID) async -> Bool {
        guard let job = job(id), case .url(let link) = job.source else { return false }
        linkObservers.removeAll()

        if job.urlMethod == .subtitles {
            setPhase(id, .fetchingSubtitles)
            urlService.$usingFallbackMethod
                .filter { $0 }
                .sink { [weak self] _ in self?.setPhase(id, .retryingDownload) }
                .store(in: &linkObservers)
            urlService.usingFallbackMethod = false
            await urlService.transcribe(urlString: link, shouldDownloadAudioFirst: false)
            linkObservers.removeAll()
            guard !cancellationRequested else { markCancelled(id); return true }

            if let text = urlService.transcriptionResult, !text.isEmpty {
                await saveSubtitlesDocument(id: id, link: link, text: text)
                return true
            }
            // No subtitles: the audio is transcribed on this Mac instead (spec 8.3).
            let error = urlService.error
            if error == .subtitlesDisabled || error == .noTranscriptAvailable {
                if let i = jobs.firstIndex(where: { $0.id == id }) {
                    jobs[i].urlMethod = .audio
                    jobs[i].subtitlesFallback = true
                }
                if !transcriptionService.isModelDownloaded(job.settings.selectedModelId) {
                    if let i = jobs.firstIndex(where: { $0.id == id }) {
                        jobs[i].status = .waitingModel
                        jobs[i].phase = .waitingModel
                    }
                    ModelDownloadCenter.shared.download(job.settings.selectedModelId)
                    return true
                }
            } else {
                failLink(id, error: error ?? .noTranscriptAvailable)
                return true
            }
        }

        // Audio method: download with yt-dlp.
        setPhase(id, .downloading(received: nil, total: nil, fraction: nil))
        urlService.$progress.combineLatest(urlService.$downloadedBytes, urlService.$totalBytes)
            .sink { [weak self] progress, received, total in
                let fraction = progress > 0.1 ? min(max((progress - 0.1) / 0.8, 0), 1) : nil
                self?.setPhase(id, .downloading(received: received, total: total, fraction: fraction))
            }
            .store(in: &linkObservers)
        let downloaded = await urlService.downloadAudioFromURL(urlString: link)
        linkObservers.removeAll()
        guard !cancellationRequested else { markCancelled(id); return true }
        guard let file = downloaded, let i = jobs.firstIndex(where: { $0.id == id }) else {
            failLink(id, error: urlService.error ?? .downloadFailed(""))
            return true
        }
        jobs[i].fileURL = file
        jobs[i].fileName = Self.cleanDownloadedName(file.lastPathComponent)
        if let d = try? await AVURLAsset(url: file).load(.duration), CMTimeGetSeconds(d).isFinite {
            jobs[i].fileDuration = CMTimeGetSeconds(d)
        }
        return false
    }

    /// yt-dlp writes «url_audio_<token>_<videoId>.mp3»; keep the video id.
    static func cleanDownloadedName(_ name: String) -> String {
        guard name.hasPrefix("url_audio_") else { return name }
        let parts = name.split(separator: "_", maxSplits: 3)
        return parts.count == 4 ? String(parts[3]) : name
    }

    private func markCancelled(_ id: UUID) {
        if let i = jobs.firstIndex(where: { $0.id == id }) { jobs[i].markCancelled() }
    }

    private func failLink(_ id: UUID, error: URLTranscriptionService.TranscriptionError) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        let details = urlService.lastToolOutput.isEmpty ? nil : urlService.lastToolOutput
        jobs[i].markFailed(error: error.errorDescription ?? "",
                           info: JobError(kind: .link(error), message: error.errorDescription ?? "", technicalDetails: details))
    }

    private func saveSubtitlesDocument(id: UUID, link: String, text: String) async {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        let result = TranscriptionResult(plainText: text)
        jobs[i].markCompleted(with: result)
        let title = URL(string: link)?.host ?? link
        let transcription = Transcription(
            id: id, title: title, text: text,
            language: jobs[i].settings.language == "auto" ? "es" : jobs[i].settings.language,
            duration: 0, createdAt: Date(), sourceURL: URL(string: link)
        )
        storage.saveTranscription(transcription)
        LibraryStore.shared.didSave(transcription)
        publishCompletion(id: id, title: title)
    }

    // MARK: - Helpers

    private func updateJobProgress(id: UUID, overall: Double, message: String) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        if jobs[index].phase == .transcribing {
            // Whisper's own percentage (the pipeline maps it to 30–100 %).
            let whisper = min(max((overall - 0.3) / 0.7, 0), 1)
            jobs[index].hasMeasuredProgress = true
            jobs[index].updateProgress(Int((whisper * 100).rounded()), message: message)
        } else {
            jobs[index].statusMessage = message
        }
    }

    private func appendStreamSegment(id: UUID, segment: TranscriptionService.LiveSegment) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        let s = StreamSegment(start: segment.startTime, end: segment.endTime, text: segment.text)
        jobs[index].streamSegments.append(s)
        jobs[index].appendStreamingText(segment.text + " ")
        onStreamSegment?(id, s)
    }

    private func publishCompletion(id: UUID, title: String) {
        let completion = JobCompletion(id: id, title: title, date: Date())
        completions.insert(completion, at: 0)
        if completions.count > 10 { completions.removeLast() }
        completed.send(completion)
        AppLogger.shared.log("Job saved to history: \(title)", category: .transcription)
    }

    private func saveJobToHistory(job: TranscriptionJob) async {
        guard let result = job.result else { return }

        // Title: meeting event for recordings made during a meeting, otherwise the file name.
        var title: String
        let cleanedTitle = job.fileName
            .replacingOccurrences(of: "\\.[^.]+$", with: "", options: .regularExpression)
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespaces)
        title = cleanedTitle.isEmpty ? localized("Transcripción", "Transcription") : String(cleanedTitle.prefix(50))
        if case .recording = job.source,
           let meeting = MeetingWatcherService.shared.meetingState.currentSuggestedTitle, !meeting.isEmpty {
            title = String(meeting.replacingOccurrences(of: "/", with: "-").prefix(60))
        }

        let transcriptionId = job.id
        let persistedAudioURL: URL?
        if job.settings.keepAudioFileInHistory {
            persistedAudioURL = storage.persistAudioFile(from: job.fileURL, for: transcriptionId)
        } else {
            persistedAudioURL = nil
            storage.deleteAudioFile(for: transcriptionId)
        }

        let transcription = Transcription(
            id: transcriptionId,
            title: title,
            text: result.plainText,
            language: job.settings.language == "auto" ? (job.detectedLanguage ?? job.settings.language) : job.settings.language,
            duration: job.fileDuration ?? result.segments.last?.endTime ?? 0,
            createdAt: Date(),
            sourceURL: persistedAudioURL,
            segments: result.segments.isEmpty ? nil : result.segments,
            modelId: job.settings.selectedModelId,
            engine: ModelCatalog.descriptor(id: job.settings.selectedModelId)?.engine.rawValue
        )

        storage.saveTranscription(transcription)
        // The history learns about the document before the completion is announced, so
        // opening it from the job view does not race the asynchronous reload.
        LibraryStore.shared.didSave(transcription)
        publishCompletion(id: transcriptionId, title: title)

        // Watch folders: auto-export next to the source file when enabled
        if WatchedFoldersManager.shared.autoExport,
           WatchedFoldersManager.shared.folders.contains(where: { $0.path == job.fileURL.deletingLastPathComponent().path }) {
            AutoExporter.export(transcription: transcription,
                                settings: job.settings,
                                format: .srt,
                                destination: job.fileURL.deletingLastPathComponent())
        }
    }
}
