import AppKit
import Carbon
import Combine
import CoreGraphics
import ApplicationServices

/// #13 — Dictación push-to-talk v1 (recortada):
/// atajo global (`RegisterEventHotKey`) → graba el micrófono con
/// `SystemAudioRecorder` → transcribe con el pipeline de whisper DIRECTO
/// (sin cola de UI, sin guardar en historial — un dictado es efímero)
/// → pega el texto en la app activa con CGEvent (Unicode por chunks de 20
/// UTF-16, cuidando pares sustitutos) + overlay "Escuchando…".
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
                if isDictating { Task { await stopAndTranscribe(discard: true) } }
            }
        }
    }
    @Published var isDictating = false
    @Published var statusText: String = ""

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private static let hotKeySignature = OSType(0x44494354) // 'DICT'
    private static let hotKeyID: UInt32 = 1

    private func localized(_ spanish: String, _ english: String) -> String {
        UserDefaults.standard.string(forKey: "app_ui_language") == "es" ? spanish : english
    }

    // MARK: - Atajos (presets fijos v1)

    /// ⌃⌥Espacio (default) / ⌃⌥D / ⌃⌥R — la combo vive en `dictationShortcut`.
    private var currentCombo: (keyCode: UInt32, modifiers: UInt32) {
        switch UserDefaults.standard.string(forKey: "dictationShortcut") ?? "ctrl+opt+space" {
        case "ctrl+opt+d":
            return (UInt32(kVK_ANSI_D), UInt32(controlKey | optionKey))
        case "ctrl+opt+r":
            return (UInt32(kVK_ANSI_R), UInt32(controlKey | optionKey))
        default:
            return (UInt32(kVK_Space), UInt32(controlKey | optionKey))
        }
    }

    // MARK: - Hotkey

    func registerHotKey() {
        unregisterHotKey()
        let combo = currentCombo
        var hotKeyID = EventHotKeyID(signature: Self.hotKeySignature, id: Self.hotKeyID)
        let status = RegisterEventHotKey(
            combo.keyCode, combo.modifiers, hotKeyID,
            GetApplicationEventTarget(), 0, &hotKeyRef
        )
        guard status == noErr else {
            AppLogger.shared.log("Failed to register dictation hotkey: \(status)", level: .error, category: .app)
            return
        }

        if eventHandlerRef == nil {
            var spec = EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            )
            InstallEventHandler(
                GetApplicationEventTarget(),
                { _, _, userData -> OSStatus in
                    guard let userData else { return noErr }
                    let manager = Unmanaged<DictationManager>.fromOpaque(userData).takeUnretainedValue()
                    DispatchQueue.main.async { manager.toggleDictation() }
                    return noErr
                },
                1, &spec,
                Unmanaged.passUnretained(self).toOpaque(),
                &eventHandlerRef
            )
        }
        AppLogger.shared.log("Dictation hotkey registered", category: .app)
    }

    func unregisterHotKey() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
    }

    /// Prompt de Accessibility SOLO desde Ajustes (la app ya está en primer
    /// plano al pulsar el toggle — nunca roba foco desde el atajo global).
    func promptAccessibilityIfNeeded() {
        guard !AXIsProcessTrusted() else { return }
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    // MARK: - Flujo

    func toggleDictation() {
        if isDictating {
            Task { await stopAndTranscribe(discard: false) }
        } else {
            Task { await startDictation() }
        }
    }

    private func startDictation() async {
        guard !isDictating else { return }

        guard AXIsProcessTrusted() else {
            statusText = localized(
                "Activa el Control de Apps en Ajustes del Sistema → Privacidad y seguridad",
                "Enable Accessibility in System Settings → Privacy & Security"
            )
            AppLogger.shared.log("Dictation blocked: accessibility not trusted", category: .app)
            return
        }
        // v1: no competir con la cola de trabajos (transcriptor singleton)
        guard !JobManager.shared.isProcessing else {
            statusText = localized("La cola de transcripción está ocupada", "The transcription queue is busy")
            return
        }

        recorder.selectedSource = .microphone
        await recorder.startRecording()
        guard recorder.isRecording else {
            statusText = recorder.errorMessage
                ?? localized("No se pudo iniciar la grabación", "Could not start recording")
            return
        }

        statusText = localized("Escuchando…", "Listening…")
        isDictating = true
        DictationOverlayController.shared.show()
        AppLogger.shared.log("Dictation started", category: .app)
    }

    private func stopAndTranscribe(discard: Bool) async {
        DictationOverlayController.shared.hide()
        let url = await recorder.stopRecording()
        isDictating = false
        statusText = ""
        guard !discard, let url else { return }

        do {
            let settings = TranscriptionSettings.default
            let result = try await TranscriptionService.shared.transcribe(
                file: url,
                modelId: settings.selectedModelId,
                settings: settings,
                preprocessOptions: .default,
                onProgress: { _, _ in }
            )
            let text = result.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty {
                AppLogger.shared.log("Dictation produced empty text", category: .app)
            } else {
                await paste(text)
                AppLogger.shared.log("Dictation pasted (\(text.count) chars)", category: .app)
            }
        } catch {
            statusText = error.localizedDescription
            AppLogger.shared.logError(error, context: "Dictation transcription", category: .app)
        }
        // El audio del dictado es efímero: se descarta siempre (v1)
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Pegado (CGEvent Unicode)

    private func paste(_ text: String) async {
        var remaining = Array(text.utf16)
        while !remaining.isEmpty {
            var chunk = Array(remaining.prefix(20))
            remaining.removeFirst(chunk.count)
            // No partir un par sustituto entre chunks
            if let last = chunk.last, (0xD800...0xDBFF).contains(last),
               let first = remaining.first, (0xDC00...0xDFFF).contains(first) {
                chunk.append(remaining.removeFirst())
            }
            let length = chunk.count
            var utf16 = chunk
            if let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) {
                down.keyboardSetUnicodeString(stringLength: length, unicodeString: &utf16)
                down.post(tap: .cghidEventTap)
            }
            try? await Task.sleep(nanoseconds: 12_000_000)
            CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)?
                .post(tap: .cghidEventTap)
            try? await Task.sleep(nanoseconds: 4_000_000)
        }
    }

    private let recorder = SystemAudioRecorder.shared
}
