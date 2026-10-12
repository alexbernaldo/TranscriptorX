import SwiftUI
import AppKit

/// Inicio (spec 6.2, 6.3): import zone, three entry points and Quick settings; with files
/// added the zone becomes the list of chips and the primary action «Transcribir».
struct HomeView: View {
    @EnvironmentObject var workspace: WorkspaceState
    @ObservedObject private var jobs = JobManager.shared
    @StateObject private var quick = QuickSettingsModel(syncsWithDefaults: true)
    @StateObject private var modifiers = ModifierKeys()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedChip: UUID?
    @State private var leaving = false
    @FocusState private var focus: Field?

    enum Field { case chooseFiles, chips }

    private var chips: [ImportChip] { workspace.importChips }
    private var transcribable: [ImportChip] { chips.filter(\.isTranscribable) }
    private var waitingAhead: Int { jobs.activeCount }

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(spacing: 24) {
                    if chips.isEmpty { dropZone } else { chipList }
                    if chips.isEmpty { entryButtons } else { chipActions }
                    QuickSettingsRow(model: quick)
                }
                // 560 pt column (spec 6.4); narrower when the work area is (720 pt window: 480 pt).
                .frame(width: min(560, max(0, geo.size.width - 2 * TX.Space.s20)))
                .padding(.top, max(TX.Space.s32, geo.size.height * 0.40 - (chips.isEmpty ? 160 : 120)))
                .padding(.bottom, TX.Space.s32)
                .frame(maxWidth: .infinity)
            }
        }
        .background(TX.Colors.bgWindow)
        .onAppear { focus = chips.isEmpty ? .chooseFiles : .chips }
        .onKeyDown(active: !chips.isEmpty && focus == .chips) { event in handleChipKey(event) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(TXL.t("region.home", "Nueva transcripción"))
    }

    // MARK: Import zone (560 × 200)

    private var dropZone: some View {
        Button { ImportActions.chooseFiles() } label: {
            VStack(spacing: 10) {
                CruceSymbol(style: .mono(TX.Colors.textTertiary))
                    .frame(width: 40, height: 40)
                    .opacity(workspace.openingAnimationActive ? 0 : 1)
                    .anchorPreference(key: HomeMarkAnchorKey.self, value: .bounds) { $0 }
                Text(TXL.t("home.drop.title", "Arrastra audio o vídeo aquí"))
                    .txStyle(TX.Typography.sectionTitle)
                    .foregroundStyle(TX.Colors.textPrimary)
                Text(TXL.t("home.drop.subtitle", "Cualquier formato que lea FFmpeg"))
                    .font(.system(size: 12))
                    .foregroundStyle(TX.Colors.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 200)
            .background(
                RoundedRectangle(cornerRadius: TX.Radius.dropZone, style: .continuous)
                    .strokeBorder(TX.Colors.borderStrong, style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(TXL.t("home.drop.a11y", "Zona de importación. Arrastra audio o vídeo, o haz clic para elegir archivos"))
    }

    private var entryButtons: some View {
        HStack(spacing: 12) {
            Button(TXL.t("home.chooseFiles", "Elegir archivos…")) { ImportActions.chooseFiles() }
                .buttonStyle(TXPrimaryButtonStyle(size: .large))
                .focused($focus, equals: .chooseFiles)
                .help(TXL.t("home.chooseFiles.help", "Elegir archivos… ⌘O"))
            Button(TXL.t("home.pasteLink", "Pegar enlace…")) {
                workspace.sheet = .url(prefill: nil, fromScheme: false, jobId: nil)
            }
            .buttonStyle(TXSecondaryButtonStyle(size: .large))
            .help(TXL.t("home.pasteLink.help", "Pegar enlace… ⇧⌘L"))
            HomeRecordButton()
        }
    }

    // MARK: Chips (44 pt rows, scroll from 5)

    private var chipList: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(chips) { chip in
                        ChipRow(chip: chip, isSelected: selectedChip == chip.id) {
                            remove(chip.id)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { selectedChip = chip.id; focus = .chips }
                        .accessibilityAction { selectedChip = chip.id }
                        .onDrag { NSItemProvider(object: chip.id.uuidString as NSString) }
                        .onDrop(of: [.text], delegate: ChipDropDelegate(target: chip.id))
                    }
                }
            }
            .frame(height: min(CGFloat(chips.count) * 44, 264))
            .focusable()
            .txCustomFocusRing()
            .focused($focus, equals: .chips)
            .scaleEffect(leaving && !reduceMotion ? 0.92 : 1, anchor: .leading)
            .offset(x: leaving && !reduceMotion ? -60 : 0)
            .opacity(leaving ? 0 : 1)
            .accessibilityLabel(TXL.t("home.chips.a11y", "Archivos para transcribir"))

            Button(TXL.t("home.addMore", "Añadir más…")) { ImportActions.chooseFiles() }
                .buttonStyle(TXBorderlessButtonStyle())
        }
    }

    private var chipActions: some View {
        HStack(spacing: 12) {
            Button(TXL.t("home.clear", "Vaciar")) { workspace.importChips.removeAll() }
                .buttonStyle(TXSecondaryButtonStyle())
                .help(TXL.t("home.clear.help", "Quita todas las fichas; no borra nada del disco"))
            Spacer()
            Button(primaryTitle) { transcribe(atFront: modifiers.option) }
                .buttonStyle(TXPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(transcribable.isEmpty)
        }
    }

    private var primaryTitle: String {
        if modifiers.option && waitingAhead > 0 { return TXL.t("home.transcribeFirst", "Transcribir antes que los demás") }
        if waitingAhead > 0 { return TXL.f("home.addToQueue", "Añadir a la cola · %d delante", waitingAhead) }
        if transcribable.count == 1 { return TXL.t("home.transcribe", "Transcribir") }
        return TXL.f("home.transcribeMany", "Transcribir %d archivos", transcribable.count)
    }

    // MARK: Actions

    private func transcribe(atFront: Bool) {
        let toQueue = transcribable
        guard !toQueue.isEmpty else { return }
        let settings = quick.settings
        let preset = quick.presetTitle
        func enqueue() {
            var firstId: UUID?
            // Order of the chips is the order of entry in the queue; with ⌥ they go first, keeping their order.
            for chip in (atFront ? toQueue.reversed() : toQueue) {
                let id = jobs.enqueue(fileURL: chip.url, fileName: chip.name, fileDuration: chip.duration,
                                      settings: settings, source: .file, presetName: preset,
                                      atFront: atFront, userInitiated: true)
                if !atFront, firstId == nil { firstId = id }
                if atFront { firstId = id }
            }
            workspace.importChips.removeAll { chip in toQueue.contains { $0.id == chip.id } }
            leaving = false
            if let firstId { workspace.open(job: firstId) }
        }
        if reduceMotion {
            enqueue()
        } else {
            withAnimation(TX.Motion.chipsToQueue) { leaving = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) { enqueue() }
        }
    }

    private func remove(_ id: UUID) {
        workspace.importChips.removeAll { $0.id == id }
        if selectedChip == id { selectedChip = nil }
    }

    /// ⌫ removes the selected chip; ⌘↑/⌘↓ moves it.
    private func handleChipKey(_ event: NSEvent) -> Bool {
        guard let id = selectedChip, let i = chips.firstIndex(where: { $0.id == id }) else { return false }
        switch (event.keyCode, event.txModifiers) {
        case (KeyCode.delete, []), (KeyCode.forwardDelete, []):
            remove(id); return true
        case (KeyCode.up, .command) where i > 0:
            workspace.importChips.swapAt(i, i - 1); return true
        case (KeyCode.down, .command) where i < chips.count - 1:
            workspace.importChips.swapAt(i, i + 1); return true
        case (KeyCode.up, []):
            selectedChip = chips[max(0, i - 1)].id; return true
        case (KeyCode.down, []):
            selectedChip = chips[min(chips.count - 1, i + 1)].id; return true
        default:
            return false
        }
    }
}

/// Grabar: the only one in the window. The first time it asks for the source in a popover
/// hanging from it; the sources stay in Ajustes › Grabación and in the context menu.
private struct HomeRecordButton: View {
    @ObservedObject private var workspace = WorkspaceState.shared
    @ObservedObject private var recording = RecordingController.shared

    var body: some View {
        Button { recording.primaryAction() } label: {
            HStack(spacing: 6) {
                Circle().fill(TX.Colors.record).frame(width: 8, height: 8).accessibilityHidden(true)
                Text(TXL.t("record.button", "Grabar"))
            }
        }
        .buttonStyle(TXSecondaryButtonStyle(size: .large))
        .help(TXL.t("record.help", "Grabar"))
        .contextMenu {
            Button(TXL.t("record.sources.menu", "Fuentes de grabación…")) { workspace.showRecordPopover = true }
        }
        .popover(isPresented: $workspace.showRecordPopover, arrowEdge: .bottom) {
            RecordPopover()
        }
    }
}

struct HomeMarkAnchorKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>?
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) { value = value ?? nextValue() }
}

private struct ChipRow: View {
    let chip: ImportChip
    let isSelected: Bool
    let onRemove: () -> Void
    @State private var hovering = false
    @State private var showDetails = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: chip.typeSymbol)
                .font(.system(size: 13))
                .foregroundStyle(TX.Colors.textSecondary)
                .frame(width: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(chip.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(TX.Colors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if case .unreadable(let details) = chip.state {
                    HStack(spacing: 6) {
                        Text(TXL.t("chip.unreadable", "FFmpeg no puede leer este archivo"))
                            .font(.system(size: 11))
                            .foregroundStyle(TX.Colors.error)
                        if details != nil {
                            Button(TXL.t("common.viewDetails", "Ver detalles")) { showDetails.toggle() }
                                .buttonStyle(TXBorderlessButtonStyle())
                                .popover(isPresented: $showDetails) {
                                    Text(details ?? "")
                                        .font(.system(size: 12, design: .monospaced))
                                        .textSelection(.enabled)
                                        .padding(16)
                                        .frame(width: 320, alignment: .leading)
                                }
                        }
                    }
                }
            }
            Spacer(minLength: 8)
            switch chip.state {
            case .reading:
                ProgressView().controlSize(.mini).accessibilityLabel(TXL.t("chip.reading", "Leyendo duración"))
            case .ready:
                if let d = chip.duration {
                    Text(TXFormat.clock(d))
                        .font(.system(size: 12, design: .monospaced).monospacedDigit())
                        .foregroundStyle(TX.Colors.textSecondary)
                }
            default:
                EmptyView()
            }
            if chip.size > 0 {
                Text(TXFormat.bytes(chip.size))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(TX.Colors.textTertiary)
            }
            Button(action: onRemove) { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(TXIconButtonStyle(iconSize: 13))
                .opacity(hovering || isSelected ? 1 : 0)
                .help(TXL.t("chip.remove", "Quitar"))
                .accessibilityLabel(TXL.f("chip.remove.a11y", "Quitar %@", chip.name))
        }
        .padding(.horizontal, 8)
        .frame(height: 44)
        .background(
            RoundedRectangle(cornerRadius: TX.Radius.row, style: .continuous)
                .fill(isSelected ? TX.Colors.selectionRow : (hovering ? TX.Colors.bgHover : .clear))
        )
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
    }
}

private struct ChipDropDelegate: DropDelegate {
    let target: UUID
    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: [.text]).first else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let raw = object as? String, let source = UUID(uuidString: raw) else { return }
            DispatchQueue.main.async {
                let ws = WorkspaceState.shared
                guard let from = ws.importChips.firstIndex(where: { $0.id == source }),
                      let to = ws.importChips.firstIndex(where: { $0.id == target }), from != to else { return }
                let chip = ws.importChips.remove(at: from)
                ws.importChips.insert(chip, at: to)
            }
        }
        return true
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
}

/// Live modifier state (⌥ changes «Transcribir» to «Transcribir antes que los demás»).
@MainActor
final class ModifierKeys: ObservableObject {
    @Published private(set) var option = false
    private var monitor: Any?

    init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.option = event.modifierFlags.contains(.option)
            return event
        }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }
}
