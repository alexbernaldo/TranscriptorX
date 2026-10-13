import AppKit
import Carbon
import Combine
import CoreGraphics
import ApplicationServices
import AVFoundation

/// #13 — Dictation, modelled on Handy: a global shortcut records the microphone, whisper
/// transcribes it directly (no queue, not saved in the history: a dictation is ephemeral)
/// and the text goes into the app in use.
///
/// The shortcut is held to dictate and released to paste, or tapped to start and tapped
/// again to paste (`DictationPreferences.Activation`). Esc cancels while dictating.
@MainActor
final class DictationManager: ObservableObject {
    static let shared = DictationManager()

    @Published var isEnabled: Bool = UserDefaults.standard.bool(forKey: "dictationEnabled") {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "dictationEnabled")
            if isEnabled {
                registerHotKey()
            } else {
                unregisterHotKey()
                if isDictating { cancel() }
            }
        }
    }
    @Published var isDictating = false
    @Published var statusText: String = ""
    /// The shortcut in use (Ajustes shows it and the recorder changes it).
    @Published private(set) var shortcut = DictationShortcut.current
    /// The shortcut could not be registered (another app owns it).
    @Published private(set) var shortcutConflict = false
    /// Text of the last dictation, for «Copiar último dictado». Only in memory.
    @Published private(set) var lastText: String?

    /// What the overlay shows (spec 6.23).
    enum Phase: Equatable {
        case idle
        /// The shortcut was heard and the microphone is opening (Handy's «arming»).
        case arming
        case listening
        case transcribing
        case pasted
        case cancelled
        case noAccessibility
        case noMicrophone
        case unavailable(String)
    }
    @Published private(set) var phase: Phase = .idle
    private var hideTask: Task<Void, Never>?

    /// The shortcut is being held for a hold-to-dictate (overlay hint «Suelta para pegar»).
    @Published private(set) var isHolding = false

    private func show(_ newPhase: Phase, hideAfter seconds: Double? = nil) {
        phase = newPhase
        hideTask?.cancel()
        DictationOverlayController.shared.show()
        if let seconds {
            hideTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.phase = .idle
                DictationOverlayController.shared.hide()
            }
        }
    }

    private func hideOverlay() {
        hideTask?.cancel()
        phase = .idle
        DictationOverlayController.shared.hide()
    }

    private func localized(_ spanish: String, _ english: String) -> String {
        UserDefaults.standard.string(forKey: "app_ui_language") == "es" ? spanish : english
    }

    // MARK: - Hotkeys

    private var hotKeyRef: EventHotKeyRef?
    private var cancelHotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private static let hotKeySignature = OSType(0x44494354) // 'DICT'
    private static let dictateID: UInt32 = 1
    private static let cancelID: UInt32 = 2

    /// Saves and registers a new shortcut; false (and the old one back) when it is taken.
    @discardableResult
    func setShortcut(_ new: DictationShortcut) -> Bool {
        let old = shortcut
        shortcut = new
        DictationShortcut.current = new
        guard isEnabled else { return true }
        registerHotKey()
        if shortcutConflict {
            shortcut = old
            DictationShortcut.current = old
            registerHotKey()
            return false
        }
        return true
    }

    func registerHotKey() {
        unregisterHotKey()
        installHandlerIfNeeded()
        let id = EventHotKeyID(signature: Self.hotKeySignature, id: Self.dictateID)
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
        shortcutConflict = status != noErr
        if status != noErr {
            AppLogger.shared.log("Failed to register dictation hotkey: \(status)", level: .error, category: .app)
        } else {
            AppLogger.shared.log("Dictation hotkey registered: \(shortcut.displayName)", category: .app)
        }
    }

    func unregisterHotKey() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        unregisterCancelKey()
    }

    /// Releases the shortcut while the recorder in Ajustes listens for a new one.
    func suspendHotKey() { unregisterHotKey() }
    func resumeHotKey() { if isEnabled { registerHotKey() } }

    /// Esc is only taken while dictating, so it keeps working everywhere else.
    private func registerCancelKey() {
        guard cancelHotKeyRef == nil else { return }
        let id = EventHotKeyID(signature: Self.hotKeySignature, id: Self.cancelID)
        RegisterEventHotKey(UInt32(kVK_Escape), 0, id, GetApplicationEventTarget(), 0, &cancelHotKeyRef)
    }

    private func unregisterCancelKey() {
        if let cancelHotKeyRef {
            UnregisterEventHotKey(cancelHotKeyRef)
            self.cancelHotKeyRef = nil
        }
    }

    private func installHandlerIfNeeded() {
        guard eventHandlerRef == nil else { return }
        var specs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                guard let event, let userData else { return noErr }
                var id = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                  nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
                let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
                let manager = Unmanaged<DictationManager>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async {
                    if id.id == DictationManager.cancelID {
                        if pressed { manager.cancel() }
                    } else if pressed {
                        manager.shortcutPressed()
                    } else {
                        manager.shortcutReleased()
                    }
                }
                return noErr
            },
            specs.count, &specs,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )
    }

    /// Prompt de Accessibility SOLO desde Ajustes (la app ya está en primer
    /// plano al pulsar el toggle — nunca roba foco desde el atajo global).
    func promptAccessibilityIfNeeded() {
        guard !AXIsProcessTrusted() else { return }
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    // MARK: - Shortcut → flow

    private var pressedAt: Date?
    /// The press that started this dictation (its release decides hold vs tap).
    private var startedByPress = false

    private func shortcutPressed() {
        pressedAt = Date()
        if isDictating || isStarting {
            // Second press of a tap-started dictation: paste.
            finish()
        } else {
            startedByPress = true
            Task { await startDictation() }
        }
    }

    private func shortcutReleased() {
        defer { pressedAt = nil; startedByPress = false; isHolding = false }
        guard startedByPress, let pressedAt else { return }
        let held = Date().timeIntervalSince(pressedAt)
        switch DictationPreferences.activation {
        case .toggle:
            return
        case .hold:
            finish()
        case .automatic:
            if held >= DictationPreferences.holdThreshold { finish() }
        }
    }

    /// Menu bar and the overlay button: start, or stop and paste.
    func toggleDictation() {
        if isDictating || isStarting { finish() } else { Task { await startDictation() } }
    }

    /// Stops and pastes (or cancels if the recording has not started yet).
    func finish() {
        if isStarting { pendingStop = true; return }
        guard isDictating else { return }
        Task { await stopAndTranscribe(discard: false) }
    }

    /// Esc, the ✕ in the capsule, the menu bar or turning dictation off: nothing is pasted.
    func cancel() {
        if isStarting { pendingCancel = true; return }
        if phase == .transcribing {
            // whisper finishes on its own; its text is simply not pasted.
            discardTranscription = true
            unregisterCancelKey()
            show(.cancelled, hideAfter: 0.8)
            Task { await playFeedback(.cancel) }
            return
        }
        guard isDictating else { return }
        Task { await stopAndTranscribe(discard: true) }
    }

    private var discardTranscription = false

    func copyLastDictation() {
        guard let lastText else { return }
        DictationInserter.copy(lastText)
    }

    // MARK: - Flow

    private var isStarting = false
    private var pendingStop = false
    private var pendingCancel = false
    private var previousSource: SystemAudioRecorder.AudioSource?
    private var previousMicrophone: SystemAudioRecorder.AudioDevice??

    private func startDictation() async {
        guard !isDictating, !isStarting else { return }
        isStarting = true
        pendingStop = false
        pendingCancel = false
        defer { isStarting = false }

        // Without Accessibility the text could not be pasted: nothing is recorded, nothing is lost.
        guard AXIsProcessTrusted() || DictationPreferences.insertion == .copyOnly else {
            statusText = localized("Necesito permiso para pegar", "I need permission to paste")
            show(.noAccessibility, hideAfter: 6)
            AppLogger.shared.log("Dictation blocked: accessibility not trusted", category: .app)
            return
        }
        // Microphone permission is requested on the first dictation (spec 8.5).
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                show(.noMicrophone, hideAfter: 6); return
            }
        case .denied, .restricted:
            show(.noMicrophone, hideAfter: 6); return
        default:
            break
        }
        // v1: one transcriber at a time; a recording also uses the capture engine.
        guard !JobManager.shared.isProcessing else {
            statusText = localized("La cola de transcripción está ocupada", "The transcription queue is busy")
            show(.unavailable(statusText), hideAfter: 3)
            return
        }
        guard !recorder.isRecording else {
            statusText = localized("Hay una grabación en curso", "A recording is in progress")
            show(.unavailable(statusText), hideAfter: 3)
            return
        }

        // Sin modelo, se descarga el del dictado (Turbo o el de Automático) y se avisa; no se graba en vano.
        let dictationModel = DictationPreferences.transcriptionSettings().selectedModelId
        if !TranscriptionService.shared.isModelDownloaded(dictationModel) {
            ModelDownloadCenter.shared.download(dictationModel)
            let name = ModelCatalog.descriptor(id: dictationModel)?.displayName ?? dictationModel
            statusText = localized("Descargando \(name)… vuelve a dictar al terminar", "Downloading \(name)… dictate again when it finishes")
            show(.unavailable(statusText), hideAfter: 5)
            AppLogger.shared.log("Dictation: model \(dictationModel) missing, download started", category: .app)
            return
        }

        show(.arming)
        previousSource = recorder.selectedSource
        recorder.selectedSource = .microphone
        selectDictationMicrophone()
        // The start sound plays before the microphone opens so it is not transcribed.
        await playFeedback(.start)
        if DictationPreferences.muteWhileRecording { SystemOutputMute.mute() }
        await recorder.startRecording()
        guard recorder.isRecording else {
            SystemOutputMute.restore()
            statusText = recorder.errorMessage
                ?? localized("No se pudo iniciar la grabación", "Could not start recording")
            show(.unavailable(statusText), hideAfter: 4)
            restoreRecorder()
            return
        }

        statusText = localized("Escuchando…", "Listening…")
        isDictating = true
        isHolding = startedByPress && DictationPreferences.activation != .toggle
        registerCancelKey()
        show(.listening)
        AccessibilityAnnouncer.announce(localized("Escuchando", "Listening"))
        AppLogger.shared.log("Dictation started", category: .app)

        // A release or Esc that arrived while the microphone was opening.
        if pendingCancel {
            await stopAndTranscribe(discard: true)
        } else if pendingStop {
            await stopAndTranscribe(discard: false)
        }
    }

    /// The microphone chosen in Ajustes › Dictado, if it is connected.
    private func selectDictationMicrophone() {
        let name = DictationPreferences.microphone
        guard !name.isEmpty else { return }
        recorder.refreshMicrophoneList()
        guard let device = recorder.availableMicrophones.first(where: { $0.name == name }) else { return }
        previousMicrophone = .some(recorder.selectedMicrophone)
        recorder.selectedMicrophone = device
    }

    private func restoreRecorder() {
        if let previousSource { recorder.selectedSource = previousSource }
        if let previousMicrophone { recorder.selectedMicrophone = previousMicrophone }
        previousSource = nil
        previousMicrophone = nil
    }

    private func stopAndTranscribe(discard: Bool) async {
        guard isDictating else { return }
        isDictating = false
        isHolding = false
        unregisterCancelKey()
        let url = await recorder.stopRecording()
        SystemOutputMute.restore()
        restoreRecorder()

        guard !discard, let url else {
            if let url { try? FileManager.default.removeItem(at: url) }
            await playFeedback(.cancel)
            statusText = localized("Cancelado", "Cancelled")
            show(.cancelled, hideAfter: 0.8)
            AppLogger.shared.log("Dictation cancelled", category: .app)
            return
        }
        await playFeedback(.stop)
        statusText = localized("Transcribiendo…", "Transcribing…")
        discardTranscription = false
        // Esc keeps working while whisper runs, as in Handy.
        registerCancelKey()
        show(.transcribing)
        defer { unregisterCancelKey() }

        do {
            let settings = DictationPreferences.transcriptionSettings()
            let result = try await TranscriptionService.shared.transcribe(
                file: url,
                modelId: settings.selectedModelId,
                settings: settings,
                preprocessOptions: .default,
                onProgress: { _, _ in }
            )
            var text = DictationText.clean(result.plainText, language: settings.language,
                                           removeFillers: DictationPreferences.removeFillers)
            if discardTranscription {
                AppLogger.shared.log("Dictation discarded after transcription", category: .app)
            } else if text.isEmpty {
                AppLogger.shared.log("Dictation produced empty text", category: .app)
                statusText = localized("No se ha oído nada", "Nothing was heard")
                show(.unavailable(statusText), hideAfter: 1.5)
            } else {
                if DictationPreferences.trailingSpace { text += " " }
                lastText = text
                await DictationInserter.insert(text)
                UserDefaults.standard.set(true, forKey: "dictation.firstDone")
                statusText = DictationPreferences.insertion == .copyOnly ? localized("Copiado", "Copied") : localized("Pegado", "Pasted")
                show(.pasted, hideAfter: 0.6)
                AccessibilityAnnouncer.announce(statusText)
                AppLogger.shared.log("Dictation inserted (\(text.count) chars)", category: .app)
            }
        } catch where discardTranscription {
            AppLogger.shared.log("Dictation discarded", category: .app)
        } catch {
            statusText = error.localizedDescription
            show(.unavailable(statusText), hideAfter: 4)
            AppLogger.shared.logError(error, context: "Dictation transcription", category: .app)
        }
        // El audio del dictado es efímero: se descarta siempre.
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Sounds

    enum Feedback { case start, stop, cancel }

    /// System sounds, like the rest of macOS. The start sound is awaited so the
    /// microphone does not pick it up.
    private func playFeedback(_ kind: Feedback) async {
        guard DictationPreferences.sounds else { return }
        let name: NSSound.Name
        switch kind {
        case .start: name = "Tink"
        case .stop: name = "Pop"
        case .cancel: name = "Funk"
        }
        guard let sound = NSSound(named: name)?.copy() as? NSSound else { return }
        sound.volume = DictationPreferences.soundVolume
        sound.play()
        if kind == .start {
            try? await Task.sleep(nanoseconds: UInt64(min(sound.duration, 0.4) * 1_000_000_000))
        }
    }

    static func previewSound() {
        guard let sound = NSSound(named: "Tink")?.copy() as? NSSound else { return }
        sound.volume = DictationPreferences.soundVolume
        sound.play()
    }

    private let recorder = SystemAudioRecorder.shared
}
