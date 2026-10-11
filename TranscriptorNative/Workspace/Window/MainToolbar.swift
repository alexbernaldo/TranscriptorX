import SwiftUI
import UniformTypeIdentifiers

/// Unified toolbar (spec 4.2): sidebar button (system), title/subtitle, Nueva, Exportar, Inspector, Ajustes.
/// Grabar lives in the centre of Inicio, next to the other ways to start.
struct MainToolbar: CustomizableToolbarContent {
    var body: some CustomizableToolbarContent {
        ToolbarItem(id: "selection", placement: .primaryAction, showsByDefault: true) {
            SelectionActions()
        }
        ToolbarItem(id: "new", placement: .primaryAction, showsByDefault: true) {
            NewToolbarButton()
        }
        ToolbarItem(id: "export", placement: .primaryAction, showsByDefault: true) {
            ExportToolbarButton()
        }
        ToolbarItem(id: "inspector", placement: .primaryAction, showsByDefault: true) {
            InspectorToolbarButton()
        }
        ToolbarItem(id: "settings", placement: .primaryAction, showsByDefault: true) {
            SettingsToolbarButton()
        }
    }
}

/// Always-visible way into Ajustes, so nobody has to know ⌘,.
private struct SettingsToolbarButton: View {
    var body: some View {
        Button {
            SettingsNavigator.open(SettingsNavigator.shared.section)
        } label: {
            Label(TXL.t("settings.button", "Ajustes"), systemImage: "gearshape")
        }
        .help(TXL.t("settings.button.help", "Ajustes ⌘,"))
    }
}

/// «3 seleccionadas»: Exportar 3…, Mover 3 a Eliminados (spec 6.13).
private struct SelectionActions: View {
    @ObservedObject private var workspace = WorkspaceState.shared

    var body: some View {
        let ids = workspace.selectedDocumentIds
        if ids.count > 1 {
            HStack(spacing: 4) {
                Button(TXL.f("history.exportMany", "Exportar %d…", ids.count)) { HistoryActions.export(ids) }
                    .buttonStyle(TXSecondaryButtonStyle())
                Button(TXL.f("history.moveManyToTrash", "Mover %d a Eliminados", ids.count)) { HistoryActions.moveToTrash(ids) }
                    .buttonStyle(TXSecondaryButtonStyle())
            }
        }
    }
}

private struct NewToolbarButton: View {
    @ObservedObject private var workspace = WorkspaceState.shared

    var body: some View {
        Button { workspace.goHome() } label: {
            Label(TXL.t("new.button", "Nueva"), systemImage: "plus")
        }
        .help(TXL.t("new.help", "Nueva transcripción ⌘N"))
        .accessibilityLabel(TXL.t("new.help.a11y", "Nueva transcripción"))
    }
}

private struct ExportToolbarButton: View {
    @ObservedObject private var workspace = WorkspaceState.shared

    var body: some View {
        Button {
            if let id = workspace.currentDocumentId { HistoryActions.export([id]) }
        } label: {
            Label(TXL.t("export.button", "Exportar"), systemImage: "square.and.arrow.up")
        }
        .disabled(workspace.currentDocumentId == nil)
        .help(TXL.t("export.help", "Exportar… ⇧⌘E"))
    }
}

private struct InspectorToolbarButton: View {
    @ObservedObject private var workspace = WorkspaceState.shared

    var body: some View {
        Button { workspace.toggleInspector() } label: {
            Label(TXL.t("inspector.button", "Inspector"), systemImage: "sidebar.right")
        }
        .disabled(workspace.currentDocumentId == nil)
        .help(workspace.inspectorVisible
              ? TXL.t("inspector.hide.help", "Ocultar inspector ⌥⌘I")
              : TXL.t("inspector.show.help", "Mostrar inspector ⌥⌘I"))
    }
}

/// File choosers shared by toolbar, home canvas and the File menu.
@MainActor
enum ImportActions {
    static func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audiovisualContent, .audio, .movie] + [UTType(filenameExtension: ProjectPackage.fileExtension)].compactMap { $0 }
        panel.message = TXL.t("import.panel.message", "Elige audio o vídeo para transcribir")
        guard panel.runModal() == .OK else { return }
        WorkspaceState.shared.addImports(panel.urls)
    }

}
