import SwiftUI
import AppKit

/// Eliminados recientemente (spec 6.14). Restoring returns the row to its date group.
/// Permanent deletion already existed in the app (spec 12.1 #15 assumed it did not): it is kept,
/// behind a confirmation with the exact verb.
struct TrashView: View {
    @ObservedObject private var library = LibraryStore.shared
    @AppStorage("trashRetentionDays") private var retention = 30
    @State private var selection: Set<UUID> = []
    @State private var anchor: UUID?
    @FocusState private var listFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, TX.Space.s32)
                .padding(.top, TX.Space.s24)
                .padding(.bottom, TX.Space.s16)
            if library.trash.isEmpty {
                TXEmptyState(systemImage: "trash", title: TXL.t("trash.empty", "No hay transcripciones eliminadas"))
                    .frame(maxHeight: .infinity)
            } else {
                list
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(TX.Colors.bgWindow)
        .onAppear {
            listFocused = true
            if let first = library.trash.first { selection = [first.id]; anchor = first.id }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(TXL.t("trash.title", "Eliminados recientemente"))
                .txStyle(TX.Typography.documentTitle)
                .foregroundStyle(TX.Colors.textPrimary)
            HStack(spacing: 4) {
                Text(TXL.f("trash.retention", "Se eliminan definitivamente a los %d días.", retention))
                    .font(.system(size: 13))
                    .foregroundStyle(TX.Colors.textSecondary)
                Button(TXL.t("trash.changeRetention", "Cambiar en Ajustes › Comportamiento")) {
                    SettingsNavigator.open(.behavior)
                }
                .buttonStyle(TXBorderlessButtonStyle())
            }
            if selection.count > 1 {
                HStack(spacing: 8) {
                    Button(TXL.f("trash.restoreMany", "Restaurar %d", selection.count)) { restore(Array(selection)) }
                        .buttonStyle(TXSecondaryButtonStyle())
                }
                .padding(.top, 4)
            }
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(library.trash) { item in
                    TrashRow(item: item, isSelected: selection.contains(item.id), listFocused: listFocused) {
                        restore([item.id])
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { tap(item.id) }
                    .accessibilityAction { selection = [item.id]; anchor = item.id }
                    .contextMenu {
                        let ids = selection.contains(item.id) ? Array(selection) : [item.id]
                        Button(ids.count > 1 ? TXL.f("trash.restoreMany", "Restaurar %d", ids.count) : TXL.t("trash.restore", "Restaurar")) { restore(ids) }
                        Divider()
                        Button(TXL.t("trash.deleteForever", "Eliminar definitivamente…")) { confirmDelete(ids) }
                    }
                }
            }
            .padding(.horizontal, TX.Space.s24)
        }
        .focusable()
            .txCustomFocusRing()
        .focused($listFocused)
        .onMoveCommand { direction in
            let ids = library.trash.map(\.id)
            guard let current = anchor.flatMap({ ids.firstIndex(of: $0) }) else { return }
            let next = direction == .up ? max(0, current - 1) : (direction == .down ? min(ids.count - 1, current + 1) : current)
            selection = [ids[next]]; anchor = ids[next]
        }
        .onKeyDown(active: listFocused) { event in
            if event.keyCode == KeyCode.returnKey, event.txModifiers.isEmpty, !selection.isEmpty {
                restore(Array(selection)); return true
            }
            return false
        }
    }

    private func tap(_ id: UUID) {
        listFocused = true
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        } else if flags.contains(.shift), let anchor, let a = library.trash.firstIndex(where: { $0.id == anchor }),
                  let b = library.trash.firstIndex(where: { $0.id == id }) {
            selection = Set(library.trash[min(a, b)...max(a, b)].map(\.id))
        } else {
            selection = [id]
            anchor = id
        }
    }

    private func restore(_ ids: [UUID]) {
        library.restore(ids)
        selection.subtract(ids)
        WorkspaceState.shared.showToast(ToastItem(icon: .success,
            text: TXL.n("trash.restored", "%d transcripción restaurada", "%d transcripciones restauradas", ids.count)))
    }

    private func confirmDelete(_ ids: [UUID]) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = TXL.n("trash.deleteForever.title", "¿Eliminar definitivamente %d transcripción?", "¿Eliminar definitivamente %d transcripciones?", ids.count)
        alert.informativeText = TXL.t("trash.deleteForever.text", "Se borrarán el texto y el audio guardado. No se puede deshacer.")
        alert.addButton(withTitle: TXL.n("trash.deleteForever.confirm", "Eliminar %d transcripción", "Eliminar %d transcripciones", ids.count))
        alert.addButton(withTitle: TXL.t("common.cancel", "Cancelar")).keyEquivalent = "\u{1b}"
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task.detached { ids.forEach { TranscriptionStorage.shared.deleteForever(id: $0) } }
        selection.subtract(ids)
    }
}

private struct TrashRow: View {
    let item: TrashItem
    let isSelected: Bool
    let listFocused: Bool
    let onRestore: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.text").font(.system(size: 13)).foregroundStyle(TX.Colors.textSecondary).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(TX.Colors.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(TXL.f("trash.deletedOn", "Eliminada el %@", TXFormat.shortDate(item.deletedAt)))
                        .foregroundStyle(TX.Colors.textSecondary)
                    Text("·").foregroundStyle(TX.Colors.textTertiary)
                    Text(TXL.n("trash.daysLeft", "Queda %d día", "Quedan %d días", item.daysLeft))
                        .foregroundStyle(item.daysLeft <= 3 ? TX.Colors.warning : TX.Colors.textSecondary)
                }
                .font(.system(size: 11, weight: .medium).monospacedDigit())
            }
            Spacer()
            if hovering || isSelected {
                Button(TXL.t("trash.restore", "Restaurar"), action: onRestore)
                    .buttonStyle(TXSecondaryButtonStyle(size: .small))
            }
        }
        .padding(.horizontal, 8)
        .frame(height: TX.Size.historyRow)
        .background(
            RoundedRectangle(cornerRadius: TX.Radius.row, style: .continuous)
                .fill(isSelected ? (listFocused ? TX.Colors.selectionRow : TX.Colors.selectionRowInactive) : (hovering ? TX.Colors.bgHover : .clear))
        )
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityAction(named: TXL.t("trash.restore", "Restaurar"), onRestore)
    }
}
