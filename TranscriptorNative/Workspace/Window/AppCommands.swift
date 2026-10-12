import SwiftUI
import AppKit
import Combine

/// Routes menu commands to the document in front.
@MainActor
final class CommandRouter: ObservableObject {
    static let shared = CommandRouter()
    @Published var activeEditor: DocumentEditor? {
        didSet { observeEditor() }
    }
    private var editorObservation: AnyCancellable?

    /// Menu items depend on the editor's mode, selection, filter and find state (enabled
    /// state and titles). Republish those changes only, not playback ticks.
    private func observeEditor() {
        guard let e = activeEditor else { editorObservation = nil; return }
        editorObservation = Publishers.MergeMany(
            e.$mode.map { _ in () }.eraseToAnyPublisher(),
            e.$selection.map { _ in () }.eraseToAnyPublisher(),
            e.$favoritesOnly.map { _ in () }.eraseToAnyPublisher(),
            e.$find.map { _ in () }.eraseToAnyPublisher(),
            e.$visible.map { _ in () }.eraseToAnyPublisher()
        )
        .dropFirst(5)
        .sink { [weak self] in self?.objectWillChange.send() }
    }

    var editor: DocumentEditor? {
        guard let e = activeEditor, WorkspaceState.shared.currentDocumentId == e.id else { return nil }
        return e
    }

    /// The segment text view being edited, if any (for ⌥Return from the menu).
    var editingTextView: SegmentNSTextView? {
        NSApp.keyWindow?.firstResponder as? SegmentNSTextView
    }
}

struct AppCommands: Commands {
    @ObservedObject var router = CommandRouter.shared
    @ObservedObject var workspace = WorkspaceState.shared
    @ObservedObject var recording = RecordingController.shared
    let exportDiagnostics: () -> Void

    var body: some Commands {
        // ⌘Q goes through QuitIntent so it is told apart from quits nobody asked for.
        CommandGroup(replacing: .appTermination) {
            Button(TXL.t("menu.quit", "Salir de Transcriptor X")) { QuitIntent.quit() }
                .keyboardShortcut("q")
        }
        CommandGroup(replacing: .newItem) {
            Button(TXL.t("menu.new", "Nueva transcripción")) {
                WindowCoordinator.showMainWindow(); workspace.goHome()
            }
            .keyboardShortcut("n")
            Button(TXL.t("menu.open", "Abrir…")) { WindowCoordinator.showMainWindow(); ImportActions.chooseFiles() }
                .keyboardShortcut("o")
            Button(TXL.t("menu.fromURL", "Transcribir desde un enlace…")) {
                WindowCoordinator.showMainWindow()
                workspace.sheet = .url(prefill: nil, fromScheme: false, jobId: nil)
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])
            Divider()
            Button(recording.isRecording ? TXL.t("menu.stopRecording", "Detener grabación") : TXL.t("menu.record", "Grabar")) {
                recording.isRecording ? recording.stop() : recording.primaryAction()
            }
            .keyboardShortcut(recording.isRecording ? KeyboardShortcut(".", modifiers: .command) : nil)
        }
        CommandGroup(after: .saveItem) {
            Button(TXL.t("menu.saveProject", "Guardar como proyecto…")) {
                if let id = workspace.currentDocumentId { HistoryActions.saveProject(id) }
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(workspace.currentDocumentId == nil)
            Button(TXL.t("menu.export", "Exportar…")) {
                let ids = workspace.selectedDocumentIds.count > 1 ? workspace.selectedDocumentIds : workspace.currentDocumentId.map { [$0] } ?? []
                HistoryActions.export(ids)
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(workspace.currentDocumentId == nil && workspace.selectedDocumentIds.isEmpty)
            Button(TXL.t("history.exportAll", "Exportar todo el historial…")) {
                workspace.sheet = .export(ExportRequest(documentIds: LibraryStore.shared.items.map(\.id), wholeHistory: true))
            }
            .disabled(LibraryStore.shared.items.isEmpty)
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button(TXL.t("menu.copyTranscription", "Copiar transcripción")) {
                if let text = router.editor?.document.text {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(router.editor == nil)
            Button(TXL.t("history.moveToTrash", "Mover a Eliminados recientemente")) {
                let ids = workspace.selectedDocumentIds.isEmpty ? workspace.currentDocumentId.map { [$0] } ?? [] : workspace.selectedDocumentIds
                HistoryActions.moveToTrash(ids)
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(workspace.currentDocumentId == nil && workspace.selectedDocumentIds.isEmpty)
        }
        CommandGroup(after: .textEditing) {
            Divider()
            Button(TXL.t("menu.find", "Buscar…")) { router.editor?.openFind(replace: false) }
                .keyboardShortcut("f")
                .disabled(router.editor == nil)
            Button(TXL.t("menu.findReplace", "Buscar y reemplazar…")) { router.editor?.openFind(replace: true) }
                .keyboardShortcut("f", modifiers: [.command, .option])
                .disabled(router.editor == nil)
            Button(TXL.t("menu.findNext", "Buscar siguiente")) { router.editor?.stepMatch(1) }
                .keyboardShortcut("g")
                .disabled(router.editor?.matches.isEmpty ?? true)
            Button(TXL.t("menu.findPrevious", "Buscar anterior")) { router.editor?.stepMatch(-1) }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(router.editor?.matches.isEmpty ?? true)
            Button(TXL.t("menu.findHistory", "Buscar en el historial")) {
                workspace.columnVisibility = .all
                workspace.focusHistorySearchToken += 1
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
        }
        CommandGroup(after: .sidebar) {
            Button(workspace.inspectorVisible ? TXL.t("menu.hideInspector", "Ocultar inspector") : TXL.t("menu.showInspector", "Mostrar inspector")) {
                workspace.toggleInspector()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .disabled(workspace.currentDocumentId == nil)
            Button(TXL.t("editor.favoritesOnly", "Solo favoritos")) { router.editor?.favoritesOnly.toggle() }
                .disabled(router.editor == nil)
            Button(TXL.t("menu.backToPlayback", "Volver a la reproducción")) { router.editor?.resumeFollowing() }
                .keyboardShortcut("l")
                .disabled(router.editor == nil)
            Divider()
        }
        CommandMenu(TXL.t("menu.transcription", "Transcripción")) {
            Button(TXL.t("menu.playPause", "Reproducir o pausar")) {
                PlaybackController.shared.togglePlayPause()
            }
            .keyboardShortcut("p", modifiers: [.command, .option])
            .disabled(!PlaybackController.shared.hasMedia || router.editor == nil)
            Button(TXL.t("menu.back5", "Retroceder 5 s")) { PlaybackController.shared.skip(-5) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .disabled(router.editor == nil)
            Button(TXL.t("menu.forward5", "Avanzar 5 s")) { PlaybackController.shared.skip(5) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled(router.editor == nil)
            Divider()
            Button(TXL.t("menu.split", "Dividir en el cursor")) {
                if let tv = router.editingTextView, let parent = tv.coordinator?.parent {
                    parent.onSplit(tv.string, tv.selectedRange().location)
                }
            }
            .keyboardShortcut(.return, modifiers: .option)
            .disabled(!(router.editor?.isEditing ?? false))
            Button(router.editor.map { $0.selection.count > 1 ? TXL.f("segment.mergeMany", "Unir %d segmentos", $0.selection.count) : TXL.t("menu.merge", "Unir segmentos") } ?? TXL.t("menu.merge", "Unir segmentos")) {
                if let editor = router.editor { SpeakerActions.mergeSegments(editor: editor) }
            }
            .keyboardShortcut("j", modifiers: [.command, .option])
            .disabled(!(router.editor?.canMergeSelection ?? false))
            .help(TXL.t("merge.disabled.help", "Solo se pueden unir segmentos seguidos"))
            Button(TXL.t("menu.favorite", "Marcar como favorito")) { router.editor?.toggleFavorite() }
                .keyboardShortcut("d")
                .disabled(router.editor == nil)
            Button(TXL.t("menu.nextFavorite", "Favorito siguiente")) { router.editor?.nextFavorite(true) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .control])
                .disabled(router.editor == nil)
            Button(TXL.t("menu.previousFavorite", "Favorito anterior")) { router.editor?.nextFavorite(false) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .control])
                .disabled(router.editor == nil)
            Button(TXL.t("menu.adjustTimes", "Ajustar tiempos…")) {
                if let editor = router.editor, let id = editor.primarySelection {
                    NotificationCenter.default.post(name: .adjustTimesRequested, object: id)
                }
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])
            .disabled(router.editor?.primarySelection == nil)
            Divider()
            Menu(TXL.t("menu.ai", "IA")) {
                Button(TXL.t("ai.suggestTitle", "Sugerir título")) { AIController.shared.run(.title, editorFromMenu: router.editor) }
                Button(TXL.t("ai.summarize", "Resumir")) { AIController.shared.run(.summary, editorFromMenu: router.editor) }
                Button(TXL.t("ai.suggestTags", "Sugerir etiquetas")) { AIController.shared.run(.tags, editorFromMenu: router.editor) }
            }
            .disabled(router.editor == nil)
            Button(TXL.t("menu.translate", "Traducir…")) { workspace.showInspector(tab: .translation) }
                .disabled(router.editor == nil)
        }
        CommandGroup(replacing: .help) {
            Button(TXL.t("menu.checkUpdates", "Buscar actualizaciones…")) { UpdaterModel.shared.checkForUpdates() }
                .keyboardShortcut("u")
            Divider()
            Button(TXL.t("menu.diagnostics", "Diagnóstico…")) {
                WindowCoordinator.showMainWindow()
                workspace.sheet = .diagnostics
            }
            Button(TXL.t("menu.exportLogs", "Exportar registro de diagnóstico…"), action: exportDiagnostics)
            Divider()
            Button(TXL.t("menu.help", "Ayuda de Transcriptor X")) {
                if let url = URL(string: "https://github.com/alexbernaldo/TranscriptorX#readme") { NSWorkspace.shared.open(url) }
            }
        }
    }
}

extension Notification.Name {
    static let adjustTimesRequested = Notification.Name("adjustTimesRequested")
}
