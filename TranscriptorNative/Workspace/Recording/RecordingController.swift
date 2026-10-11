import SwiftUI
import Combine
import AVFoundation

/// Recording flow (spec 6.7–6.9): popover configuration, start/stop, floating panel and
/// hand-off of the recorded file to the queue. The capture itself is `SystemAudioRecorder`.
///
/// Real capabilities (validated against the code, spec 12.1 #3–#4): one source at a time
/// (microphone or system audio) and no live text while recording; the transcription runs
/// in the queue when the recording stops.
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

    /// Click on the body of «Grabar»: records if configured, otherwise opens the popover.
    func primaryAction() {
        if isActive {
            stop()
        } else if isConfigured && permissionState(for: recorder.selectedSource) != .notDetermined {
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
                if UserDefaults.standard.bool(forKey: "liveCaptionEnabled") {
                    LiveCaptionCenter.shared.recordingStarted()
                }
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
        Task {
            let url = await recorder.stopRecording()
            if let url {
                let settings = QuickSettingsModel.settings(forPreset: presetId)
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
        _ = await recorder.stopRecording()
    }

    func dismissError() {
        if case .failed = phase { phase = .idle }
        FloatingRecordingPanelController.shared.update()
    }

    private func recorderStateChanged(_ state: RecordingState) {
        if case .failed(let error) = state, phase == .recording {
            phase = .failed(error.userMessage)
            FloatingRecordingPanelController.shared.update()
        }
    }
}
