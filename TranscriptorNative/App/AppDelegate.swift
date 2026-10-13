import SwiftUI
import AppKit
import Combine

class AppDelegate: NSObject, NSApplicationDelegate {

    private var cancellables = Set<AnyCancellable>()
    private var memorySource: DispatchSourceMemoryPressure?
    private var lastMemoryLevel: DispatchSource.MemoryPressureEvent = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ninguna descarga implícita de FluidAudio: solo «Descargar» abre la red (FluidNetworkGate).
        FluidNetworkGate.lockDown()
        TaskModelPreferences.migrateStoredModelNames()
        // Claves de la app con defaults (#10): menú de barra + segundo plano
        UserDefaults.standard.register(defaults: [
            "showMenuBarExtra": true,
            "keepRunningInBackground": true,
            "liveCaptionEnabled": false,   // #11 — subtítulos en pantalla, off por defecto
            "liveCaptionDelay": 2.0,
            "announceLiveSegments": true,
            "appearanceMode": AppearanceMode.dark.rawValue
        ])
        DictationPreferences.registerDefaults()
        Self.migrateToAutomaticLanguage()
        // Dark is the default appearance (spec 3.5); «Sistema» follows macOS.
        MainActor.assumeIsolated {
            AppearanceMode.apply(AppearanceMode.current)
            DockVisibility.apply()
        }

        AppLogger.shared.log("Application launched", category: .app)

        MainActor.assumeIsolated {
            _ = LibraryStore.shared
            _ = LiveCaptionCenter.shared
            _ = FloatingRecordingPanelController.shared
            observeApp()
        }

        // Crash recovery (spec 6.26): interrupted jobs come back as «Recuperable» rows + banner.
        Task {
            let items = await RecoveryManager.shared.checkForRecoverableItems()
            let pending = RecoveryManager.shared.pendingRecordings()
            await MainActor.run {
                let all = items + pending
                if !all.isEmpty {
                    AppLogger.shared.log("Found recovered items", category: .recovery, metadata: ["count": "\(all.count)"])
                }
                JobManager.shared.restoreRecoverable(all, defaults: QuickSettingsModel.defaultSettings())
                RecoveryActions.postBannerIfNeeded()
            }
        }

        CLIServer.shared.start()

        // #13 — Dictado: registrar atajo global si estaba activo
        if UserDefaults.standard.bool(forKey: "dictationEnabled") {
            MainActor.assumeIsolated { DictationManager.shared.registerHotKey() }
        }

        // Start persistent folder watchers without requiring Preferences to be opened
        _ = WatchedFoldersManager.shared
        // Recently Deleted retention: purge on launch, silently (spec 6.14).
        DispatchQueue.global(qos: .utility).async { TranscriptionStorage.shared.purgeTrash() }

        let autoMeetings = QuickSettingsModel.defaultSettings().autoDetectMeetings
        MeetingWatcherService.shared.start(enabled: autoMeetings)
        startMemoryPressureMonitor()
    }

    @MainActor private func observeApp() {
        let workspace = WorkspaceState.shared
        // History known: onboarding decision, migration notice.
        LibraryStore.shared.$state
            .filter { $0 == .ready }
            .first()
            .sink { _ in
                Task { @MainActor in
                    let library = LibraryStore.shared
                    if !library.items.isEmpty { UserDefaults.standard.set(true, forKey: "onboarding.hasHistory") }
                    // Restoration (spec 4.5): the last document, paused; Inicio if it was deleted.
                    if workspace.route == .home, let raw = UserDefaults.standard.string(forKey: "restore.documentId"),
                       let id = UUID(uuidString: raw), library.document(id) != nil {
                        workspace.open(document: id)
                    }
                    OnboardingState.shared.historyLoaded(count: library.items.count)
                    switch library.migrationOutcome {
                    case .migrated(let backup):
                        workspace.showToast(ToastItem(icon: .success,
                            text: TXL.t("migration.done", "Historial actualizado. Copia de seguridad guardada como transcriptions.json.bak"),
                            actionTitle: TXL.t("common.showInFinder", "Mostrar en Finder"),
                            action: { NSWorkspace.shared.activateFileViewerSelecting([backup]) }, duration: 8))
                    case .failed(let details):
                        workspace.post(BannerItem(key: "migration", kind: .error,
                            title: TXL.t("migration.failed", "No se pudo actualizar el historial"),
                            message: TXL.t("migration.failed.text", "Tus transcripciones siguen en transcriptions.json y no se han modificado."),
                            details: details,
                            actions: [BannerAction(title: TXL.t("common.retry", "Reintentar"), isPrimary: true) { library.retryMigration() }]))
                    case .none:
                        break
                    }
                }
            }
            .store(in: &cancellables)

        // Meeting detected (#7) → banner; the menu bar shows it when the window is closed.
        NotificationCenter.default.publisher(for: .meetingDetected)
            .receive(on: RunLoop.main)
            .sink { note in
                Task { @MainActor in
                    guard QuickSettingsModel.defaultSettings().autoDetectMeetings else { return }
                    MeetingActions.postBanner(title: note.userInfo?["suggestedTitle"] as? String,
                                              app: note.userInfo?["app"] as? String ?? "")
                }
            }
            .store(in: &cancellables)
        MeetingWatcherService.shared.$meetingState
            .receive(on: RunLoop.main)
            .sink { state in
                if case .none = state { Task { @MainActor in WorkspaceState.shared.dismissBanner(key: "meeting") } }
            }
            .store(in: &cancellables)

        // VoiceOver: queue phase changes (never every percentage).
        JobManager.shared.phaseAnnouncements
            .throttle(for: .seconds(1), scheduler: RunLoop.main, latest: true)
            .sink { AccessibilityAnnouncer.announce($0) }
            .store(in: &cancellables)

        // Grouped VoiceOver announcement of streamed segments: at most every 4 s (spec 10.2).
        var buffer: [String] = []
        let previous = JobManager.shared.onStreamSegment
        JobManager.shared.onStreamSegment = { id, segment in
            previous?(id, segment)
            if UserDefaults.standard.bool(forKey: "announceLiveSegments") { buffer.append(segment.text) }
        }
        Timer.publish(every: 4, on: .main, in: .common).autoconnect()
            .sink { _ in
                guard !buffer.isEmpty, NSWorkspace.shared.isVoiceOverEnabled else { buffer.removeAll(); return }
                AccessibilityAnnouncer.announce(buffer.joined(separator: " "))
                buffer.removeAll()
            }
            .store(in: &cancellables)

        // Pending recordings handed over on quit become regular recovered files once handled.
        JobManager.shared.onJobFinished = { id in
            Task { @MainActor in
                if let job = JobManager.shared.job(id), job.source == .recovered, job.status == .completed {
                    RecoveryManager.shared.resolvePendingRecording(job.fileURL)
                }
            }
        }
    }

    /// «Hay poca memoria disponible en el Mac» (spec 8.6): shown again only if pressure increases.
    private func startMemoryPressureMonitor() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let level = source.data
            let increased = level.contains(.critical) && !self.lastMemoryLevel.contains(.critical)
            guard self.lastMemoryLevel.isEmpty || increased else { return }
            self.lastMemoryLevel = level
            MainActor.assumeIsolated {
                WorkspaceState.shared.post(BannerItem(key: "memory", kind: .warning,
                    title: TXL.t("memory.title", "Hay poca memoria disponible en el Mac"),
                    message: TXL.t("memory.text", "La transcripción puede ir más lenta. Cerrar otras apps ayuda.")))
            }
        }
        source.resume()
        memorySource = source
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if url.pathExtension == ProjectPackage.fileExtension {
                MainActor.assumeIsolated {
                    WindowCoordinator.showMainWindow()
                    WorkspaceState.shared.openProject(url)
                }
            } else if url.scheme == "transcriptorx" {
                handleDeepLink(url)
            } else if url.isFileURL, FileInputService.isSupported(url) {
                // Files dropped on the Dock icon or opened with «Abrir con».
                MainActor.assumeIsolated {
                    WindowCoordinator.showMainWindow()
                    WorkspaceState.shared.addImports([url])
                }
            }
        }
    }

    private func handleDeepLink(_ url: URL) {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            AppLogger.shared.log("Invalid deep link: \(url.absoluteString)", category: .app)
            return
        }
        switch comps.host {
        case "transcribe":
            // Never downloads without confirmation: the sheet opens with the link filled in (spec 6.4).
            let target = comps.queryItems?.first(where: { $0.name == "url" })?.value
            AppLogger.shared.log("Deep link transcribe", category: .app, metadata: ["url": target ?? "(none)"])
            // «model» acepta un nombre («Turbo») o un ID técnico; solo preselecciona el modelo en el sheet.
            let rawModel = comps.queryItems?.first(where: { $0.name == "model" })?.value
            let model = rawModel.flatMap { ModelCatalog.migratedId(fromStored: $0) ?? ($0.lowercased() == "auto" ? "auto" : nil) }
            NotificationCenter.default.post(name: .transcribeURL, object: nil,
                                            userInfo: ["url": target as Any, "model": model as Any])
        case "open":
            AppLogger.shared.log("Deep link open", category: .app)
            MainActor.assumeIsolated { WindowCoordinator.showMainWindow() }
        default:
            AppLogger.shared.log("Unknown deep link host: \(comps.host ?? "")", category: .app)
        }
    }

    /// Language detection became the default (Oct 2026). Saved defaults that predate it
    /// fixed Spanish because that was the old default, so they switch once.
    private static func migrateToAutomaticLanguage() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "migration.autoLanguage") else { return }
        d.set(true, forKey: "migration.autoLanguage")
        guard let data = d.data(forKey: "transcription_settings"),
              var saved = try? JSONDecoder().decode(TranscriptionSettings.self, from: data),
              saved.language != "auto",
              !ModelCapabilities.isEnglishOnly(saved.selectedModelId) else { return }
        saved.language = "auto"
        if let encoded = try? JSONEncoder().encode(saved) { d.set(encoded, forKey: "transcription_settings") }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { DictationManager.shared.unregisterHotKey() }   // #13
        CLIServer.shared.stop()
        AppLogger.shared.log("Application terminating", category: .app)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Closing the window keeps the app in the Dock and the menu bar (spec 4.6).
        let menubar = UserDefaults.standard.bool(forKey: "showMenuBarExtra")
        let keepRunning = UserDefaults.standard.bool(forKey: "keepRunningInBackground") || UserDefaults.standard.bool(forKey: "hideDockIcon")
        return !(menubar && keepRunning)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { MainActor.assumeIsolated { WindowCoordinator.showMainWindow() } }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let menubar = UserDefaults.standard.bool(forKey: "showMenuBarExtra")
        let keepRunning = UserDefaults.standard.bool(forKey: "keepRunningInBackground") || UserDefaults.standard.bool(forKey: "hideDockIcon")
        let canLiveInBackground = menubar && keepRunning
        // Which app asked (e.g. a utility that quits apps without windows) helps when the
        // app «disappears».
        AppLogger.shared.log("Quit requested", category: .app, metadata: ["appleEvent": QuitIntent.describeCurrentEvent()])
        if !canLiveInBackground || QuitIntent.isWanted() {
            let reply = MainActor.assumeIsolated { confirmQuitIfBusy() }
            if reply == .terminateCancel { QuitIntent.userAsked = false }
            return reply
        }
        // macOS 27 sometimes sends the app a quit of its own when its window opens or closes
        // while it lives in the menu bar. It used to slip through when it arrived during a
        // click (e.g. «Nueva transcripción…» in the menu bar) and the app vanished.
        AppLogger.shared.log("Ignored a quit the user did not ask for", category: .app,
                             metadata: ["appleEvent": QuitIntent.describeCurrentEvent()])
        return .terminateCancel
    }

    /// «¿Salir de Transcriptor X?» only with a recording or active jobs (spec 6.25).
    @MainActor private func confirmQuitIfBusy() -> NSApplication.TerminateReply {
        let recording = RecordingController.shared.isRecording
        let jobs = JobManager.shared
        let processing = jobs.currentJob != nil
        let waiting = jobs.jobs.filter { $0.status == .queued || $0.status == .waitingModel }.count
        guard recording || processing || waiting > 0 else { return .terminateNow }

        var lines: [String] = []
        if recording { lines.append(TXL.t("quit.recording", "Se detendrá la grabación y se guardará lo grabado para transcribirlo la próxima vez.")) }
        if processing { lines.append(TXL.t("quit.processing", "El trabajo en curso se podrá reanudar la próxima vez.")) }
        if waiting > 0 { lines.append(TXL.n("quit.waiting", "%d trabajo en espera no se conserva.", "%d trabajos en espera no se conservan.", waiting)) }

        let alert = NSAlert()
        alert.messageText = TXL.t("quit.title", "¿Salir de Transcriptor X?")
        alert.informativeText = lines.joined(separator: " ")
        alert.addButton(withTitle: TXL.t("quit.quit", "Salir"))
        alert.addButton(withTitle: TXL.t("quit.closeWindow", "Cerrar solo la ventana"))
        alert.addButton(withTitle: TXL.t("common.cancel", "Cancelar")).keyEquivalent = "\u{1b}"
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if recording {
                Task { @MainActor in
                    if let url = await RecordingController.shared.recorder.stopRecording() {
                        _ = RecoveryManager.shared.storeRecordingForNextLaunch(url)
                    }
                    NSApp.reply(toApplicationShouldTerminate: true)
                }
                return .terminateLater
            }
            return .terminateNow
        case .alertSecondButtonReturn:
            WindowCoordinator.mainWindow?.close()
            return .terminateCancel
        default:
            return .terminateCancel
        }
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let recoveredItemsFound = Notification.Name("recoveredItemsFound")
    static let transcribeURL = Notification.Name("transcribeURL")   // #22 — deep link transcriptorx://transcribe
}

/// Whether a quit is something the user (or the system on their behalf) asked for.
enum QuitIntent {
    /// Set by our own Quit commands and by Sparkle before it relaunches.
    @MainActor static var userAsked = false

    /// Our Quit menu items and ⌘Q.
    @MainActor static func quit() {
        userAsked = true
        NSApp.terminate(nil)
    }

    /// A deliberate quit: one of ours, another process (Dock, Activity Monitor, a script,
    /// an installer) or log out / restart / shut down.
    static func isWanted() -> Bool {
        if MainActor.assumeIsolated({ userAsked }) { return true }
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventClass == AEEventClass(kCoreEventClass),
              event.eventID == AEEventID(kAEQuitApplication) else { return false }
        if event.paramDescriptor(forKeyword: AEKeyword(kAEQuitReason)) != nil { return true }
        if let sender = event.attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr))?.int32Value,
           sender != 0, sender != getpid() {
            return !isWindowCloserUtility(sender)
        }
        return false
    }

    /// Utilities that quit every app whose last window closes. Transcriptor X is meant to stay
    /// in the menu bar without a window (dictation, recording, queue), so while «Seguir
    /// funcionando al cerrar la ventana» is on, their quits are not the user's intent.
    static let windowCloserUtilities: Set<String> = ["onebadidea.Swift-Quit"]

    private static func isWindowCloserUtility(_ pid: pid_t) -> Bool {
        guard let id = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier else { return false }
        return windowCloserUtilities.contains(id)
    }

    static func describeCurrentEvent() -> String {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return "none" }
        let sender = event.attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr))?.int32Value ?? 0
        let reason = event.paramDescriptor(forKeyword: AEKeyword(kAEQuitReason))?.typeCodeValue ?? 0
        let app = sender == getpid() ? "self" : (NSRunningApplication(processIdentifier: sender)?.localizedName ?? "pid \(sender)")
        return "from=\(app) reason=\(reason)"
    }
}
