import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Actions on history documents shared by context menus, the toolbar and VoiceOver actions.
@MainActor
enum HistoryActions {
    static func export(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        WorkspaceState.shared.sheet = .export(ExportRequest(documentIds: ids))
    }

    static func moveToTrash(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        let workspace = WorkspaceState.shared
        if let current = workspace.currentDocumentId, ids.contains(current) {
            PlaybackController.shared.unload()
            workspace.goHome()
        }
        workspace.selection.subtract(ids.map { SidebarID.document($0) })
        LibraryStore.shared.moveToTrash(ids)
        let text = ids.count == 1
            ? TXL.t("toast.movedToTrash", "Movida a Eliminados recientemente")
            : TXL.n("toast.movedToTrashMany", "%d movida a Eliminados recientemente", "%d movidas a Eliminados recientemente", ids.count)
        workspace.showToast(ToastItem(icon: .info, text: text,
                                      actionTitle: TXL.t("common.undo", "Deshacer"),
                                      action: { LibraryStore.shared.restore(ids) }))
    }

    /// Archivo › Guardar como proyecto… (spec 6.15): native save panel with an accessory line.
    static func saveProject(_ id: UUID) {
        guard let transcription = LibraryStore.shared.document(id) else { return }
        let panel = NSSavePanel()
        if let type = UTType(filenameExtension: ProjectPackage.fileExtension) { panel.allowedContentTypes = [type] }
        panel.nameFieldStringValue = transcription.title.replacingOccurrences(of: "/", with: "-") + "." + ProjectPackage.fileExtension
        panel.canCreateDirectories = true
        let size = transcription.sourceURL.flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }.map(Int64.init)
        let line = TXL.t("project.save.accessory", "Incluye transcripción, hablantes, favoritos y el audio original")
            + (size.map { " · " + TXFormat.bytes($0) } ?? "")
        let label = NSTextField(labelWithString: line)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 28))
        label.frame = container.bounds.insetBy(dx: 12, dy: 6)
        container.addSubview(label)
        panel.accessoryView = container
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                try await Task.detached { try ProjectPackage.save(transcription: transcription, to: url) }.value
                WorkspaceState.shared.showToast(ToastItem(icon: .success,
                    text: TXL.f("toast.projectSaved", "Proyecto guardado en %@", url.deletingLastPathComponent().lastPathComponent),
                    actionTitle: TXL.t("common.showInFinder", "Mostrar en Finder"),
                    action: { NSWorkspace.shared.activateFileViewerSelecting([url]) }))
            } catch {
                WorkspaceState.shared.post(BannerItem(key: "projectSave", kind: .error,
                    title: TXL.t("project.save.failed", "No se pudo guardar el proyecto"),
                    message: error.localizedDescription))
            }
        }
    }

    static func originalMedia(_ id: UUID) -> URL? {
        guard let url = LibraryStore.shared.document(id)?.sourceURL, url.isFileURL,
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }
}

/// Context menu of a history row (spec 6.13). Applies to the whole selection when the row is part of it.
struct HistoryContextMenu: View {
    let itemId: UUID
    @ObservedObject private var workspace = WorkspaceState.shared

    private var targets: [UUID] {
        let selected = workspace.selectedDocumentIds
        return selected.contains(itemId) && selected.count > 1 ? selected : [itemId]
    }

    var body: some View {
        let ids = targets
        if ids.count == 1 {
            Button(TXL.t("common.open", "Abrir")) { workspace.open(document: itemId) }
            Button(TXL.t("history.export", "Exportar…")) { HistoryActions.export(ids) }
            Button(TXL.t("history.saveProject", "Guardar como proyecto…")) { HistoryActions.saveProject(itemId) }
            Button(TXL.t("history.showOriginal", "Mostrar archivo original en Finder")) {
                if let url = HistoryActions.originalMedia(itemId) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
            .disabled(HistoryActions.originalMedia(itemId) == nil)
            Divider()
            Button(TXL.t("history.moveToTrash", "Mover a Eliminados recientemente")) { HistoryActions.moveToTrash(ids) }
                .keyboardShortcut(.delete, modifiers: .command)
        } else {
            Button(TXL.f("history.exportMany", "Exportar %d…", ids.count)) { HistoryActions.export(ids) }
            Divider()
            Button(TXL.f("history.moveManyToTrash", "Mover %d a Eliminados", ids.count)) { HistoryActions.moveToTrash(ids) }
        }
    }
}

/// Crash recovery actions (spec 6.26).
@MainActor
enum RecoveryActions {
    static func confirmDiscard(_ job: TranscriptionJob) {
        let alert = NSAlert()
        alert.messageText = TXL.f("recovery.discard.title", "¿Descartar %@?", job.displayTitle)
        alert.informativeText = TXL.t("recovery.discard.text", "Se quitará de la cola. El archivo original no se borra.")
        alert.addButton(withTitle: TXL.t("recovery.discard.confirm", "Descartar"))
        alert.addButton(withTitle: TXL.t("common.cancel", "Cancelar")).keyEquivalent = "\u{1b}"
        if alert.runModal() == .alertFirstButtonReturn {
            JobManager.shared.remove(jobId: job.id)
            if WorkspaceState.shared.route == .job(job.id) { WorkspaceState.shared.goHome() }
        }
    }

    /// Banner «2 trabajos no terminaron la última vez» (spec 6.26).
    static func postBannerIfNeeded() {
        let count = JobManager.shared.recoverableJobs.count
        let workspace = WorkspaceState.shared
        guard count > 0 else { workspace.dismissBanner(key: "recovery"); return }
        workspace.post(BannerItem(
            key: "recovery", kind: .recovery,
            title: TXL.n("recovery.banner.title", "%d trabajo no terminó la última vez", "%d trabajos no terminaron la última vez", count),
            message: TXL.t("recovery.banner.text", "La app se cerró antes de completarlos. El audio y la configuración se conservan."),
            actions: [
                BannerAction(title: TXL.t("recovery.resumeAll", "Reanudar todo"), isPrimary: true) {
                    JobManager.shared.resumeAllRecoverable()
                    workspace.dismissBanner(key: "recovery")
                },
                BannerAction(title: TXL.t("recovery.review", "Revisar")) {
                    if let first = JobManager.shared.recoverableJobs.first { workspace.open(job: first.id) }
                    workspace.columnVisibility = .all
                }
            ]))
    }
}
