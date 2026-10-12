import SwiftUI

/// Menú de barra (spec 6.25): native menu so it inherits keyboard and VoiceOver.
struct MenuBarMenu: View {
    @ObservedObject private var jobs = JobManager.shared
    @ObservedObject private var recording = RecordingController.shared
    @ObservedObject private var recorder = SystemAudioRecorder.shared
    @ObservedObject private var meeting = MeetingWatcherService.shared
    @ObservedObject private var updater = UpdaterModel.shared
    @ObservedObject private var library = LibraryStore.shared
    @ObservedObject private var dictation = DictationManager.shared

    var body: some View {
        if updater.availableVersion != nil {
            Button(TXL.t("menubar.updateAvailable", "Actualización disponible…")) { updater.checkForUpdates() }
            Divider()
        }
        if !jobs.recoverableJobs.isEmpty {
            Button(TXL.n("menubar.recoverable", "%d trabajo por recuperar", "%d trabajos por recuperar", jobs.recoverableJobs.count)) {
                WindowCoordinator.showMainWindow()
                if let first = jobs.recoverableJobs.first { WorkspaceState.shared.open(job: first.id) }
            }
            Divider()
        }
        if case .detected(let app, let title) = meeting.meetingState, !recording.isRecording {
            Text(TXL.f("menubar.meeting", "Reunión: %@", title ?? app))
            Button(TXL.t("meeting.recordNow", "Grabar ahora")) { MeetingActions.recordNow() }
            Divider()
        }
        if recording.isRecording {
            Button(TXL.f("menubar.stopRecording", "Detener grabación · %@", TXFormat.clock(recorder.recordingDuration))) { recording.stop() }
        } else {
            Button(TXL.t("record.button", "Grabar")) {
                if recording.isConfigured { recording.start() } else {
                    WindowCoordinator.showMainWindow()
                    WorkspaceState.shared.showRecordPopover = true
                }
            }
        }
        if dictation.isEnabled {
            if dictation.isDictating {
                Button(TXL.t("menubar.dictation.finish", "Terminar dictado y pegar")) { dictation.finish() }
                Button(TXL.t("menubar.dictation.cancel", "Cancelar dictado")) { dictation.cancel() }
            } else {
                Button(TXL.f("menubar.dictation.start", "Dictar (%@)", dictation.shortcut.displayName)) { dictation.toggleDictation() }
            }
            if dictation.lastText != nil {
                Button(TXL.t("menubar.dictation.copyLast", "Copiar último dictado")) { dictation.copyLastDictation() }
            }
        }
        Divider()
        if let last = jobs.completions.first ?? library.items.first.map({ JobCompletion(id: $0.id, title: $0.title, date: $0.createdAt) }) {
            Button(TXL.f("menubar.last", "Última: %@", last.title)) {
                WindowCoordinator.showMainWindow()
                WorkspaceState.shared.open(document: last.id)
            }
        }
        let active = jobs.inProcessJobs
        if !active.isEmpty {
            Menu(TXL.f("menubar.queue", "En cola (%d)", active.count)) {
                ForEach(active) { job in
                    Button("\(job.displayTitle) · \(JobPresentation(job).phaseText)") {
                        WindowCoordinator.showMainWindow()
                        WorkspaceState.shared.open(job: job.id)
                    }
                }
                Divider()
                Button(TXL.t("menubar.showQueue", "Mostrar cola")) {
                    WindowCoordinator.showMainWindow()
                    WorkspaceState.shared.columnVisibility = .all
                    if let first = active.first { WorkspaceState.shared.open(job: first.id) }
                }
            }
        }
        Divider()
        Button(TXL.t("menubar.new", "Nueva transcripción…")) {
            WindowCoordinator.showMainWindow()
            WorkspaceState.shared.goHome()
        }
        Button(TXL.t("menubar.history", "Historial")) {
            WindowCoordinator.showMainWindow()
            WorkspaceState.shared.columnVisibility = .all
        }
        Button(TXL.t("menubar.settings", "Ajustes…")) { SettingsNavigator.open(SettingsNavigator.shared.section) }
        Divider()
        Button(TXL.t("menubar.quit", "Salir de Transcriptor X")) { QuitIntent.quit() }
    }
}

/// Menu bar symbol: template, recording time, dashed «queue active», orange dot for a meeting (spec 2.4).
struct MenuBarLabel: View {
    @ObservedObject private var jobs = JobManager.shared
    @ObservedObject private var recording = RecordingController.shared
    @ObservedObject private var recorder = SystemAudioRecorder.shared
    @ObservedObject private var meeting = MeetingWatcherService.shared

    var body: some View {
        let meetingDetected: Bool = { if case .detected = meeting.meetingState { return !recording.isRecording }; return false }()
        let state: CruceRenderer.MenuBarState = meetingDetected ? .meeting : (jobs.activeCount > 0 ? .queueActive : .idle)
        HStack(spacing: 4) {
            Image(nsImage: CruceRenderer.menuBarImage(state: state))
            if recording.isRecording {
                Text(TXFormat.clock(recorder.recordingDuration)).monospacedDigit()
            }
        }
        .accessibilityLabel(recording.isRecording ? TXL.t("menubar.a11y.recording", "Transcriptor X, grabando") : "Transcriptor X")
    }
}

/// Meeting banner and menu bar action (spec 8.6).
@MainActor
enum MeetingActions {
    static func recordNow() {
        SystemAudioRecorder.shared.selectedSource = .system
        WorkspaceState.shared.dismissBanner(key: "meeting")
        RecordingController.shared.start()
    }

    static func postBanner(title: String?, app: String) {
        guard !RecordingController.shared.isRecording else { return }
        let text = title.map { TXL.f("meeting.banner.event", "%@ · %@ está abierto", $0, app) } ?? TXL.f("meeting.banner.app", "%@ está abierto", app)
        WorkspaceState.shared.post(BannerItem(key: "meeting", kind: .meeting, title: text,
                                              actions: [BannerAction(title: TXL.t("meeting.recordNow", "Grabar ahora"), isPrimary: true) { recordNow() }]))
    }
}
