import AppKit
import Carbon
import CoreAudio

// Pieces of the dictation flow that do not depend on its state: preferences, the global
// shortcut, text clean-up, muting the speakers and inserting the text. Behaviour follows
// Handy (hold or tap the shortcut, Esc cancels, clipboard paste that leaves the clipboard
// as it was), adapted to Transcriptor X.

// MARK: - Preferences

/// Dictation preferences (Ajustes › Dictado), stored in UserDefaults.
enum DictationPreferences {
    /// How the shortcut starts and stops dictation.
    enum Activation: String, CaseIterable, Identifiable {
        /// Hold to dictate and release to paste, or tap to start and tap again to paste.
        case automatic
        /// Dictates only while the shortcut is held.
        case hold
        /// Tap to start, tap again to paste.
        case toggle
        var id: String { rawValue }
    }

    /// How the text reaches the app in use.
    enum Insertion: String, CaseIterable, Identifiable {
        /// Through the clipboard and ⌘V: fast, keeps accents and emoji.
        case paste
        /// Typed character by character: for fields that block pasting.
        case type
        /// Only copied to the clipboard.
        case copyOnly
        var id: String { rawValue }
    }

    enum AutoSubmit: String, CaseIterable, Identifiable {
        case off, enter, commandEnter
        var id: String { rawValue }
    }

    enum OverlayPosition: String, CaseIterable, Identifiable {
        case bottom, top, hidden
        var id: String { rawValue }
    }

    /// Value of the model and language pickers that means «as in Ajustes › Idioma».
    static let useDefault = "default"
    /// Holding longer than this is a hold; shorter is a tap (Handy uses 300 ms).
    static let holdThreshold: TimeInterval = 0.3

    private static var defaults: UserDefaults { .standard }

    static func registerDefaults() {
        defaults.register(defaults: [
            "dictation.activation": Activation.automatic.rawValue,
            "dictation.sounds": true,
            "dictation.soundVolume": 0.5,
            "dictation.muteWhileRecording": false,
            "dictation.insertion": Insertion.paste.rawValue,
            "dictation.keepInClipboard": false,
            "dictation.autoSubmit": AutoSubmit.off.rawValue,
            "dictation.trailingSpace": true,
            "dictation.removeFillers": true,
            "dictation.translate": false,
            "dictation.model": ModelSelection.autoToken,
            "dictation.language": useDefault,
            "dictation.overlay": OverlayPosition.bottom.rawValue,
            "dictation.microphone": "",
            "hideDockIcon": false,
        ])
    }

    static var activation: Activation { Activation(rawValue: defaults.string(forKey: "dictation.activation") ?? "") ?? .automatic }
    static var sounds: Bool { defaults.bool(forKey: "dictation.sounds") }
    static var soundVolume: Float { Float(defaults.double(forKey: "dictation.soundVolume")) }
    static var muteWhileRecording: Bool { defaults.bool(forKey: "dictation.muteWhileRecording") }
    static var insertion: Insertion { Insertion(rawValue: defaults.string(forKey: "dictation.insertion") ?? "") ?? .paste }
    static var keepInClipboard: Bool { defaults.bool(forKey: "dictation.keepInClipboard") }
    static var autoSubmit: AutoSubmit { AutoSubmit(rawValue: defaults.string(forKey: "dictation.autoSubmit") ?? "") ?? .off }
    static var trailingSpace: Bool { defaults.bool(forKey: "dictation.trailingSpace") }
    static var removeFillers: Bool { defaults.bool(forKey: "dictation.removeFillers") }
    static var translate: Bool { defaults.bool(forKey: "dictation.translate") }
    static var overlay: OverlayPosition { OverlayPosition(rawValue: defaults.string(forKey: "dictation.overlay") ?? "") ?? .bottom }
    /// Microphone name, empty for the system default.
    static var microphone: String { defaults.string(forKey: "dictation.microphone") ?? "" }

    static var customWords: [String] {
        get { defaults.stringArray(forKey: "dictation.customWords") ?? [] }
        set { defaults.set(newValue, forKey: "dictation.customWords") }
    }

    /// The defaults of Ajustes › Idioma with the dictation overrides on top.
    static func transcriptionSettings() -> TranscriptionSettings {
        var settings = QuickSettingsModel.defaultSettings()
        let filesAssignment = ModelAssignment(storage: settings.selectedModelId)
        // Modelo del dictado (Ajustes › Modelos): «auto» se resuelve aquí a un modelo concreto.
        settings.selectedModelId = TaskModelPreferences.dictationStorage(defaults.string(forKey: "dictation.model"))
            ?? ModelSelection.autoToken
        let language = defaults.string(forKey: "dictation.language") ?? useDefault
        if language != useDefault { settings.language = language }
        settings.translate = translate
        settings = ModelSelection.prepare(settings, task: .dictation, filesAssignment: filesAssignment).settings
        settings.translate = translate && !ModelCapabilities.isEnglishOnly(settings.selectedModelId)
        // Speakers make no sense for a dictation and add seconds of work.
        settings.enableDiarization = false
        // Custom words are given to whisper as context, the way it learns spellings.
        let words = customWords.filter { !$0.isEmpty }
        if !words.isEmpty {
            let vocabulary = words.joined(separator: ", ")
            settings.initialPrompt = settings.initialPrompt.isEmpty ? vocabulary : settings.initialPrompt + " " + vocabulary
        }
        return settings
    }
}

// MARK: - Shortcut

/// A global shortcut: a Carbon key code and Carbon modifier mask.
struct DictationShortcut: Equatable {
    let keyCode: UInt32
    let modifiers: UInt32

    static let standard = DictationShortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey))

    /// The saved shortcut; the three presets of earlier versions are migrated.
    static var current: DictationShortcut {
        get {
            let d = UserDefaults.standard
            if d.object(forKey: "dictation.shortcut.keyCode") != nil {
                return DictationShortcut(keyCode: UInt32(d.integer(forKey: "dictation.shortcut.keyCode")),
                                         modifiers: UInt32(d.integer(forKey: "dictation.shortcut.modifiers")))
            }
            switch d.string(forKey: "dictationShortcut") {
            case "ctrl+opt+d": return DictationShortcut(keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(controlKey | optionKey))
            case "ctrl+opt+r": return DictationShortcut(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(controlKey | optionKey))
            default: return .standard
            }
        }
        set {
            UserDefaults.standard.set(Int(newValue.keyCode), forKey: "dictation.shortcut.keyCode")
            UserDefaults.standard.set(Int(newValue.modifiers), forKey: "dictation.shortcut.modifiers")
        }
    }

    /// From a key press in the shortcut recorder; nil when it cannot be a global shortcut
    /// (a letter without ⌘, ⌃ or ⌥ would stop that letter from being typed anywhere).
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        let code = UInt32(event.keyCode)
        let hasRealModifier = !flags.intersection([.command, .control, .option]).isEmpty
        guard hasRealModifier || Self.functionKeys[code] != nil else { return nil }
        self.init(keyCode: code, modifiers: carbon)
    }

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// «⌃⌥ Espacio», «⌘⇧ D», «F5».
    var displayName: String {
        var symbols = ""
        if modifiers & UInt32(controlKey) != 0 { symbols += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { symbols += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { symbols += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { symbols += "⌘" }
        let key = Self.keyName(keyCode)
        return symbols.isEmpty ? key : "\(symbols) \(key)"
    }

    private static let functionKeys: [UInt32: String] = [
        UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2", UInt32(kVK_F3): "F3", UInt32(kVK_F4): "F4",
        UInt32(kVK_F5): "F5", UInt32(kVK_F6): "F6", UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8",
        UInt32(kVK_F9): "F9", UInt32(kVK_F10): "F10", UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12",
        UInt32(kVK_F13): "F13", UInt32(kVK_F14): "F14", UInt32(kVK_F15): "F15", UInt32(kVK_F16): "F16",
        UInt32(kVK_F17): "F17", UInt32(kVK_F18): "F18", UInt32(kVK_F19): "F19",
    ]

    private static func keyName(_ code: UInt32) -> String {
        if let f = functionKeys[code] { return f }
        switch Int(code) {
        case kVK_Space: return TXL.t("key.space", "Espacio")
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Delete: return "⌫"
        case kVK_Escape: return "⎋"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        default: break
        }
        // The character the key types in the current keyboard layout.
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "#\(code)" }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        return data.withUnsafeBytes { buffer -> String in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return "#\(code)" }
            var deadKeys: UInt32 = 0
            var length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                        OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars)
            guard status == noErr, length > 0 else { return "#\(code)" }
            return String(utf16CodeUnits: chars, count: length).uppercased()
        }
    }
}

// MARK: - Text

/// Clean-up of the dictated text (pure; tested).
enum DictationText {
    /// Hesitations that are not a word in any language whisper writes.
    static let universalFillers: Set<String> = ["uh", "uhm", "umm", "uhh", "uhhh", "ehh", "ehm", "ahm", "hmm", "hm", "mmm"]

    /// Hesitations that are a real word elsewhere, removed only when the language is known.
    static func fillers(for language: String) -> Set<String> {
        switch language.split(separator: "-").first.map(String.init) ?? language {
        case "en": return ["um", "ah", "eh"]
        case "es": return ["eh", "em", "mm"]
        case "de": return ["äh", "ähm"]
        case "fr": return ["euh"]
        default: return []
        }
    }

    static func clean(_ text: String, language: String, removeFillers: Bool) -> String {
        // Non-speech annotations whisper writes in silences: [BLANK_AUDIO], (music), *laughs*.
        var result = text.replacingOccurrences(of: #"\[[^\]]*\]|\([^)]*\)|\*[^*]*\*"#, with: " ", options: .regularExpression)
        if removeFillers {
            let fillers = universalFillers.union(fillers(for: language))
            var words: [String] = []
            for word in result.split(whereSeparator: \.isWhitespace).map(String.init) {
                let bare = word.lowercased().trimmingCharacters(in: .punctuationCharacters)
                if fillers.contains(bare) {
                    // «Eh, bueno» → «bueno»; «dijo, eh.» keeps the full stop on the previous word.
                    if let last = word.last, ".?!".contains(last), let previous = words.popLast() {
                        words.append(previous.trimmingCharacters(in: CharacterSet(charactersIn: ",;")) + String(last))
                    }
                    continue
                }
                words.append(word)
            }
            result = collapseStutters(words).joined(separator: " ")
        }
        result = result.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // A filler removed at the start leaves «bueno, ...»: capitalise what is now first.
        if removeFillers, let first = result.first, first.isLowercase, text.trimmingCharacters(in: .whitespaces).first?.isUppercase == true {
            result = first.uppercased() + result.dropFirst()
        }
        return result
    }

    /// «I I I I think» → «I think» (three or more repeats, as Handy does).
    static func collapseStutters(_ words: [String]) -> [String] {
        var result: [String] = []
        var i = 0
        while i < words.count {
            var j = i + 1
            while j < words.count && words[j].lowercased() == words[i].lowercased() { j += 1 }
            if j - i >= 3 { result.append(words[j - 1]) } else { result.append(contentsOf: words[i..<j]) }
            i = j
        }
        return result
    }
}

// MARK: - Speakers mute

/// Mutes the default output device while dictating, so music or a video does not end
/// up in the transcript, and restores exactly what was there before.
enum SystemOutputMute {
    private static var mutedDevice: AudioDeviceID?

    static func mute() {
        guard mutedDevice == nil, let device = defaultOutputDevice(), let current = muteValue(device), current == 0 else { return }
        if setMute(device, 1) { mutedDevice = device }
    }

    static func restore() {
        guard let device = mutedDevice else { return }
        _ = setMute(device, 0)
        mutedDevice = nil
    }

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != 0 ? device : nil
    }

    private static var muteAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                                                mScope: kAudioDevicePropertyScopeOutput,
                                                                mElement: kAudioObjectPropertyElementMain)

    private static func muteValue(_ device: AudioDeviceID) -> UInt32? {
        guard AudioObjectHasProperty(device, &muteAddress) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &muteAddress, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func setMute(_ device: AudioDeviceID, _ value: UInt32) -> Bool {
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(device, &muteAddress, &settable) == noErr, settable.boolValue else { return false }
        var newValue = value
        return AudioObjectSetPropertyData(device, &muteAddress, 0, nil, UInt32(MemoryLayout<UInt32>.size), &newValue) == noErr
    }
}

// MARK: - Inserting the text

/// Puts the dictated text into the app in use.
@MainActor
enum DictationInserter {
    static func insert(_ text: String) async {
        switch DictationPreferences.insertion {
        case .paste: await pasteThroughClipboard(text)
        case .type: await type(text)
        case .copyOnly: copy(text)
        }
        guard DictationPreferences.insertion != .copyOnly else { return }
        switch DictationPreferences.autoSubmit {
        case .off: break
        case .enter: await pressReturn(command: false)
        case .commandEnter: await pressReturn(command: true)
        }
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// ⌘V with the text on the clipboard; what was there before comes back afterwards
    /// unless the user asked to keep the dictation copied.
    private static func pasteThroughClipboard(_ text: String) async {
        let pasteboard = NSPasteboard.general
        let saved = DictationPreferences.keepInClipboard ? nil : snapshot(pasteboard)
        copy(text)
        let ours = pasteboard.changeCount
        try? await Task.sleep(nanoseconds: 30_000_000)
        postKey(CGKeyCode(kVK_ANSI_V), flags: .maskCommand)
        // The target app reads the clipboard asynchronously; give it time before restoring.
        try? await Task.sleep(nanoseconds: 350_000_000)
        if let saved, pasteboard.changeCount == ours {
            pasteboard.clearContents()
            if !saved.isEmpty { pasteboard.writeObjects(saved) }
        }
    }

    private static func snapshot(_ pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
    }

    /// Unicode key events in chunks of 20 UTF-16 units, never splitting a surrogate pair.
    private static func type(_ text: String) async {
        var remaining = Array(text.utf16)
        while !remaining.isEmpty {
            var chunk = Array(remaining.prefix(20))
            remaining.removeFirst(chunk.count)
            if let last = chunk.last, (0xD800...0xDBFF).contains(last),
               let first = remaining.first, (0xDC00...0xDFFF).contains(first) {
                chunk.append(remaining.removeFirst())
            }
            if let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) {
                down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
                down.post(tap: .cghidEventTap)
            }
            try? await Task.sleep(nanoseconds: 12_000_000)
            CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)?.post(tap: .cghidEventTap)
            try? await Task.sleep(nanoseconds: 4_000_000)
        }
    }

    private static func pressReturn(command: Bool) async {
        try? await Task.sleep(nanoseconds: 60_000_000)
        postKey(CGKeyCode(kVK_Return), flags: command ? .maskCommand : [])
    }

    private static func postKey(_ key: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { continue }
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
    }
}

// MARK: - Dock

/// «Ocultar del Dock»: the app lives only in the menu bar, like Handy in the background.
/// Hidden from the Dock the menu bar icon is the only way back, so it stays on.
@MainActor
enum DockVisibility {
    static var isHidden: Bool { UserDefaults.standard.bool(forKey: "hideDockIcon") }

    static func apply() {
        if isHidden { UserDefaults.standard.set(true, forKey: "showMenuBarExtra") }
        let policy: NSApplication.ActivationPolicy = isHidden ? .accessory : .regular
        guard NSApp.activationPolicy() != policy else { return }
        let visible = NSApp.windows.filter { $0.isVisible && $0.canBecomeKey }
        NSApp.setActivationPolicy(policy)
        // Changing the policy deactivates the app; bring back the window the user was in.
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            visible.forEach { $0.makeKeyAndOrderFront(nil) }
        }
    }
}
