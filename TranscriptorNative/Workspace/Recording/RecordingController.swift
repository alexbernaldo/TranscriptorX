import SwiftUI
import Combine
import AVFoundation

/// Recording flow (spec 6.7–6.9): popover configuration, start/stop, floating panel and
/// hand-off of the recorded file to the queue. The capture itself is `SystemAudioRecorder`.
///
/// Real capabilities (validated against the code, spec 12.1 #3–#4): one source at a time
/// (microphone or system audio). While recording, `LiveTranscription` shows Nemotron's text;
/// the final transcription of the whole file runs in the queue when the recording stops.
@MainActor
final class RecordingController: ObservableObject {
    static let shared = RecordingController()

    enum Phase: Equatable {
        case idle
        case starting
        case recording
        case processing
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lastJobId: UUID?
    /// Settings used for the transcription of the recording (popover compact row).
    @Published var presetId: String = UserDefaults.standard.string(forKey: "recording.preset") ?? QuickSettingsModel.defaultPresetId {
        didSet { UserDefaults.standard.set(presetId, forKey: "recording.preset") }
    }

    let recorder = SystemAudioRecorder.shared
    private var cancellables = Set<AnyCancellable>()

    /// The user configured sources once: a click on the button body starts recording directly.
    var isConfigured: Bool {
        get { UserDefaults.standard.bool(forKey: "recording.configured") }
        set { UserDefaults.standard.set(newValue, forKey: "recording.configured"); objectWillChange.send() }
    }

    var isRecording: Bool { phase == .recording }
    var isActive: Bool { phase == .recording || phase == .starting || phase == .processing }
    var elapsed: TimeInterval { recorder.recordingDuration }
    var usesMicrophone: Bool { recorder.selectedSource == .microphone }

    private init() {
        recorder.$recordingState
            .receive(on: RunLoop.main)
            .sink { [weak self] state in self?.recorderStateChanged(state) }
            .store(in: &cancellables)
        // Forward recorder changes (level, time) to views observing this controller.
        recorder.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    // MARK: Entry points

    /// Botón «Grabar»: siempre abre las opciones (fuente, modelo, preset). Con `quick` (atajo global)
    /// empieza directamente si ya se configuró una vez.
    func primaryAction(quick: Bool = false) {
        if isActive {
            stop()
        } else if quick && isConfigured && permissionState(for: recorder.selectedSource) != .notDetermined {
            start()
        } else {
            WorkspaceState.shared.showRecordPopover = true
        }
    }

    enum PermissionState { case granted, notDetermined, denied }

    func permissionState(for source: SystemAudioRecorder.AudioSource) -> PermissionState {
        switch source {
        case .microphone:
            switch recorder.microphoneAuthorization {
            case .authorized: return .granted
            case .notDetermined: return .notDetermined
            default: return .denied
            }
        case .system:
            if CGPreflightScreenCaptureAccess() { return .granted }
            return UserDefaults.standard.bool(forKey: "recording.screenPermissionAsked") ? .denied : .notDetermined
        }
    }

    /// «Permitir…»: lets macOS show its own dialog.
    func requestPermission(for source: SystemAudioRecorder.AudioSource) async {
        let previous = recorder.selectedSource
        recorder.selectedSource = source
        if source == .system { UserDefaults.standard.set(true, forKey: "recording.screenPermissionAsked") }
        await recorder.requestPermission()
        recorder.selectedSource = previous
        recorder.refreshPermissionStatusPassively()
        objectWillChange.send()
    }

    func openPrivacySettings(for source: SystemAudioRecorder.AudioSource) {
        let anchor = source == .microphone ? "Privacy_Microphone" : "Privacy_ScreenCapture"
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Start / stop

    func start() {
        guard !isActive else { return }
        WorkspaceState.shared.showRecordPopover = false
        isConfigured = true
        phase = .starting
        if recorder.selectedSource == .system { UserDefaults.standard.set(true, forKey: "recording.screenPermissionAsked") }
        Task {
            await recorder.startRecording()
            if recorder.isRecording {
                phase = .recording
                WorkspaceState.shared.route = .live
                AccessibilityAnnouncer.announce(TXL.t("recording.announce.started", "Grabación iniciada"))
                LiveTranscription.shared.start(language: QuickSettingsModel.settings(forPreset: presetId).language)
                FloatingRecordingPanelController.shared.update()
            } else {
                phase = .failed(recorder.errorMessage ?? TXL.t("recording.error.start", "No se pudo empezar a grabar"))
                FloatingRecordingPanelController.shared.update()
            }
        }
    }

    func stop() {
        guard phase == .recording else { return }
        phase = .processing
        AccessibilityAnnouncer.announce(TXL.t("recording.announce.stopped", "Grabación detenida, procesando"))
        FloatingRecordingPanelController.shared.update()
        LiveTranscription.shared.stop()
        Task {
            let url = await recorder.stopRecording()
            if let url {
                var settings = QuickSettingsModel.settings(forPreset: presetId)
                // Sin preset, la grabación usa su propio modelo (Ajustes › Modelos › Grabación).
                if !QuickSettingsModel.presetIds.contains(presetId),
                   case .model(let id) = TaskModelPreferences.shared.recordingAssignment {
                    settings.selectedModelId = id
                }
                let name = TXL.f("recording.fileName", "Grabación %@", TXFormat.longDateTime(Date()))
                let id = JobManager.shared.enqueue(
                    fileURL: url, fileName: name, fileDuration: recorder.recordingDuration,
                    settings: settings, source: .recording(microphone: usesMicrophone),
                    presetName: QuickSettingsModel.presetTitle(presetId), userInitiated: true)
                lastJobId = id
                if WorkspaceState.shared.route == .live { WorkspaceState.shared.open(job: id) }
                phase = .idle
            } else {
                phase = .failed(recorder.errorMessage ?? TXL.t("recording.error.interrupted", "La grabación se ha interrumpido"))
            }
            FloatingRecordingPanelController.shared.update()
        }
    }

    /// Quit confirmation: stop and keep what was recorded.
    func stopForQuit() async {
        guard phase == .recording else { return }
        LiveTranscription.shared.stop()
        _ = await recorder.stopRecording()
    }

    func dismissError() {
        if case .failed = phase { phase = .idle }
        FloatingRecordingPanelController.shared.update()
    }

    private func recorderStateChanged(_ state: RecordingState) {
        if case .failed(let error) = state, phase == .recording {
            LiveTranscription.shared.stop()
            phase = .failed(error.userMessage)
            FloatingRecordingPanelController.shared.update()
        }
    }
}

// MARK: - Texto en vivo (Nemotron)

/// Texto de Nemotron mientras se graba: lo muestran la vista En vivo y los subtítulos en pantalla.
/// La transcripción definitiva sigue haciéndose con el archivo completo al detener la grabación.
@MainActor
final class LiveTranscription: ObservableObject {
    static let shared = LiveTranscription()

    enum State: Equatable {
        case off
        case loading
        case running
        /// El modelo en vivo para este idioma no está descargado (la vista ofrece «Descargar»).
        case needsDownload(modelId: String)
        /// Ningún modelo en vivo admite el idioma, o no hay Apple Silicon.
        case unavailable(String)
        case failed(String)
    }

    @Published private(set) var state: State = .off
    @Published private(set) var text = ""
    @Published private(set) var modelId: String?

    private var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private var lastCaption = ""

    /// Modelo en vivo para un idioma según Ajustes › Modelos › Subtítulos en vivo.
    static func resolution(language: String) -> ModelResolution {
        TaskModelPreferences.shared.resolve(task: .liveCaptions, currentLanguage: language, translate: false)
    }

    func start(language: String) {
        stop()
        text = ""
        lastCaption = ""
        let r = Self.resolution(language: language)
        guard let model = r.model else {
            modelId = r.needsDownload?.id
            if let need = r.needsDownload {
                state = .needsDownload(modelId: need.id)
            } else {
                state = .unavailable(TXL.t("live.text.unavailable", "No hay texto en vivo para este idioma. El texto aparecerá al detener la grabación."))
            }
            return
        }
        modelId = model.id
        state = .loading
        let chunk = ModelEngineSettings.nemotronChunkMs(for: model.id)
        let (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream(bufferingPolicy: .bufferingNewest(400))
        self.continuation = continuation
        Task { [weak self] in
            let engine = NemotronStreamingEngine.shared
            do {
                try await engine.startLiveSession(modelId: model.id, language: language, chunkMs: chunk)
                guard let self, self.continuation != nil else { _ = await engine.endLiveSession(); return }
                self.state = .running
                SystemAudioRecorder.shared.liveAudioTap = { buffer in continuation.yield(buffer) }
                for await buffer in stream {
                    let partial = try await engine.feed(buffer)
                    self.update(partial)
                }
                let final = await engine.endLiveSession()
                if !final.isEmpty { self.update(final) }
                if self.state == .running { self.state = .off }
            } catch {
                SystemAudioRecorder.shared.liveAudioTap = nil
                _ = await engine.endLiveSession()
                AppLogger.shared.logError(error, context: "Live transcription", category: .recording)
                self?.state = .failed(error.localizedDescription)
            }
        }
    }

    /// Deja de recibir audio; el texto ya mostrado se queda hasta la próxima grabación.
    func stop() {
        SystemAudioRecorder.shared.liveAudioTap = nil
        continuation?.finish()
        continuation = nil
        if state == .loading || state == .running { state = .off }
    }

    private func update(_ partial: String) {
        let trimmed = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != text else { return }
        text = trimmed
        let caption = Self.lastSentence(of: trimmed)
        if !caption.isEmpty, caption != lastCaption {
            lastCaption = caption
            LiveCaptionCenter.shared.showLive(caption)
        }
    }

    /// Última frase (o las últimas ~14 palabras) para la cápsula de subtítulos.
    static func lastSentence(of text: String) -> String {
        let body = text.trimmingCharacters(in: CharacterSet(charactersIn: " .?!"))
        let start = body.lastIndex(where: { ".?!".contains($0) }).map { body.index(after: $0) } ?? body.startIndex
        let words = body[start...].split(separator: " ")
        return words.suffix(14).joined(separator: " ")
    }
}
