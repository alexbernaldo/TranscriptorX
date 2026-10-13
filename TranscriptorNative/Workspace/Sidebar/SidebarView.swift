import SwiftUI
import UniformTypeIdentifiers

/// Historial (spec 4.2, 6.6, 6.13): search, «En proceso» and the history grouped by date
/// in one list. Jobs and documents are representations of `JobManager` and `LibraryStore`.
struct SidebarView: View {
    @EnvironmentObject var workspace: WorkspaceState
    @ObservedObject var library = LibraryStore.shared
    @ObservedObject var jobs = JobManager.shared
    @ObservedObject var models = ModelDownloadCenter.shared
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @FocusState private var searchFocused: Bool
    @FocusState private var listFocused: Bool
    @State private var dragging: UUID?

    private var inProcess: [TranscriptionJob] { jobs.inProcessJobs }
    private var isEmpty: Bool { library.items.isEmpty && inProcess.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            if !isEmpty || !library.query.isEmpty {
                searchField
                    .padding(.horizontal, TX.Space.s12)
                    .padding(.top, TX.Space.s8)
                    .padding(.bottom, TX.Space.s8)
            }
            content
            footer
        }
        .background(sidebarBackground)
        .txOnChange(of: workspace.focusHistorySearchToken) { _ in searchFocused = true }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(TXL.t("region.history", "Historial"))
    }

    @ViewBuilder private var sidebarBackground: some View {
        if reduceTransparency {
            TX.Colors.bgSidebarSolid.ignoresSafeArea()
        } else {
            TX.Colors.bgSidebarTint.ignoresSafeArea()
        }
    }

    // MARK: Search

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(TX.Colors.textTertiary)
                .accessibilityHidden(true)
            TextField(TXL.t("history.search.placeholder", "Buscar"), text: $library.query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($searchFocused)
                .onSubmit { openFirstResult() }
                .onExitCommand { library.query = ""; searchFocused = false }
                .accessibilityLabel(TXL.t("history.search.a11y", "Buscar en el historial"))
            if !library.query.isEmpty {
                Button { library.query = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(TX.Colors.textTertiary)
                .help(TXL.t("history.search.clear", "Borrar búsqueda"))
                .accessibilityLabel(TXL.t("history.search.clear", "Borrar búsqueda"))
            }
        }
        .padding(.horizontal, 8)
        .frame(height: TX.Size.control)
        .background(RoundedRectangle(cornerRadius: TX.Radius.control, style: .continuous).fill(TX.Colors.bgControl.opacity(0.6)))
        .help(TXL.t("history.search.help", "Buscar en el historial ⇧⌘F"))
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if library.state == .migrating {
            migrationState
        } else if let results = library.searchResults, !library.query.isEmpty {
            searchList(results)
        } else if isEmpty && library.state == .ready {
            VStack {
                Text(TXL.t("history.empty", "Aquí aparecerán tus transcripciones"))
                    .font(.system(size: 13))
                    .foregroundStyle(TX.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, TX.Space.s16)
                    .padding(.top, 120)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            mainList
        }
    }

    private var migrationState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(TXL.t("history.migrating", "Actualizando el historial…"))
                .font(.system(size: 13))
                .foregroundStyle(TX.Colors.textSecondary)
            TXProgressLine(kind: .indeterminate)
            Spacer()
        }
        .padding(TX.Space.s16)
        .accessibilityElement(children: .combine)
    }

    private var mainList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
                    if !inProcess.isEmpty {
                        TXGroupHeader(title: TXL.t("history.group.inProcess", "En proceso"), trailing: "\(inProcess.count)")
                            .padding(.horizontal, TX.Space.s16)
                            .padding(.top, TX.Space.s8)
                            .padding(.bottom, TX.Space.s4)
                        ForEach(inProcess) { job in
                            QueueRow(job: job, isSelected: workspace.selection.contains(.job(job.id)), listFocused: listFocused)
                                .id(SidebarID.job(job.id))
                                .padding(.horizontal, TX.Space.s8)
                                .contentShape(Rectangle())
                                .onTapGesture { tap(.job(job.id)) }
                                .accessibilityAction { workspace.select([.job(job.id)]) }
                                .contextMenu { QueueContextMenu(job: job) }
                                .onDrag {
                                    dragging = job.id
                                    return NSItemProvider(object: job.id.uuidString as NSString)
                                }
                                .onDrop(of: [.text], delegate: QueueDropDelegate(target: job.id, dragging: $dragging))
                        }
                    }
                    ForEach(library.sections) { section in
                        TXGroupHeader(title: section.title)
                            .padding(.horizontal, TX.Space.s16)
                            .padding(.top, TX.Space.s16)
                            .padding(.bottom, TX.Space.s4)
                        ForEach(section.items) { item in
                            HistoryRow(item: item,
                                       isSelected: workspace.selection.contains(.document(item.id)),
                                       listFocused: listFocused,
                                       isNew: workspace.recentlyCompleted.contains(item.id))
                                .id(SidebarID.document(item.id))
                                .padding(.horizontal, TX.Space.s8)
                                .contentShape(Rectangle())
                                .onTapGesture { tap(.document(item.id)) }
                                .accessibilityAction { workspace.select([.document(item.id)]) }
                                .contextMenu { HistoryContextMenu(itemId: item.id) }
                        }
                    }
                }
                .padding(.bottom, TX.Space.s8)
                .animation(TX.Motion.jobCompleted, value: inProcess.map(\.id))
            }
            .contextMenu {
                Button(TXL.t("history.exportAll", "Exportar todo el historial…")) {
                    workspace.sheet = .export(ExportRequest(documentIds: library.items.map(\.id), wholeHistory: true))
                }
                .disabled(library.items.isEmpty)
            }
            .focusable()
            .txCustomFocusRing()
            .focused($listFocused)
            .onMoveCommand { direction in move(direction, proxy: proxy) }
            .onKeyDown(active: listFocused) { event in
                switch (event.keyCode, event.txModifiers) {
                case (KeyCode.returnKey, []), (KeyCode.enter, []):
                    return openSelection()
                case (KeyCode.delete, .command):
                    trashSelection(); return true
                default:
                    return false
                }
            }
            .accessibilityLabel(TXL.t("history.list.a11y", "Lista del historial"))
        }
    }

    private func searchList(_ results: SearchResults) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if results.hits.isEmpty {
                    VStack(spacing: 8) {
                        Text(TXL.f("history.search.none", "Nada coincide con «%@»", results.query))
                            .font(.system(size: 13))
                            .foregroundStyle(TX.Colors.textSecondary)
                            .multilineTextAlignment(.center)
                        Button(TXL.t("history.search.clear", "Borrar búsqueda")) { library.query = "" }
                            .buttonStyle(TXBorderlessButtonStyle())
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
                } else {
                    Text(TXL.f("history.search.count", "%@ en %@",
                               TXL.n("history.search.matches", "%d coincidencia", "%d coincidencias", results.totalMatches),
                               TXL.n("history.search.docs", "%d transcripción", "%d transcripciones", results.hits.count)))
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(TX.Colors.textTertiary)
                        .padding(.horizontal, TX.Space.s16)
                        .padding(.vertical, TX.Space.s8)
                    ForEach(results.hits) { hit in
                        SearchResultRow(hit: hit, isSelected: workspace.selection.contains(.document(hit.id)))
                            .padding(.horizontal, TX.Space.s8)
                            .contentShape(Rectangle())
                            .onTapGesture { openResult(hit) }
                            .accessibilityAction { openResult(hit) }
                            .contextMenu { HistoryContextMenu(itemId: hit.id) }
                    }
                }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 0) {
            TXSeparator()
            Button { workspace.showTrash() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "trash").font(.system(size: 13)).frame(width: 16).accessibilityHidden(true)
                    Text(TXL.t("trash.title", "Eliminados recientemente"))
                        .font(.system(size: 13))
                        .lineLimit(1)
                    Spacer()
                    if !library.trash.isEmpty {
                        Text("\(library.trash.count)")
                            .font(.system(size: 11, weight: .medium).monospacedDigit())
                            .foregroundStyle(TX.Colors.textTertiary)
                    }
                }
                .foregroundStyle(TX.Colors.textPrimary)
                .padding(.horizontal, 8)
                .frame(height: TX.Size.control)
            }
            .buttonStyle(TXRowButtonStyle(isSelected: workspace.route == .trash))
            .padding(.horizontal, TX.Space.s8)
            .padding(.top, 6)
            .accessibilityValue(library.trash.isEmpty ? "" : "\(library.trash.count)")

            ModelStatusLine()
                .padding(.horizontal, TX.Space.s16)
                .padding(.vertical, 8)
        }
    }

    // MARK: Interaction

    private func tap(_ id: SidebarID) {
        let flags = NSEvent.modifierFlags
        listFocused = true
        if flags.contains(.command) {
            var s = workspace.selection
            if s.contains(id) { s.remove(id) } else { s.insert(id) }
            workspace.select(s)
        } else if flags.contains(.shift), let anchor = workspace.selection.first {
            let order = orderedIds
            if let a = order.firstIndex(of: anchor), let b = order.firstIndex(of: id) {
                workspace.select(Set(order[min(a, b)...max(a, b)]))
            }
        } else {
            workspace.select([id])
        }
    }

    private var orderedIds: [SidebarID] {
        inProcess.map { .job($0.id) } + library.sections.flatMap { $0.items.map { SidebarID.document($0.id) } }
    }

    private func move(_ direction: MoveCommandDirection, proxy: ScrollViewProxy) {
        let order = orderedIds
        guard !order.isEmpty else { return }
        let flags = NSEvent.modifierFlags
        // ⌥⌘↑ / ⌥⌘↓: priority, only with the queue focused.
        if flags.contains(.option) && flags.contains(.command),
           workspace.selection.count == 1, case .job(let id)? = workspace.selection.first {
            if direction == .up, jobs.canMove(id, .up) { jobs.move(id, .up) }
            if direction == .down, jobs.canMove(id, .down) { jobs.move(id, .down) }
            return
        }
        let current = workspace.selection.compactMap { order.firstIndex(of: $0) }
        let index: Int
        switch direction {
        case .up: index = max((current.min() ?? order.count) - 1, 0)
        case .down: index = min((current.max() ?? -1) + 1, order.count - 1)
        default: return
        }
        if flags.contains(.shift), let anchor = current.first {
            workspace.select(Set(order[min(anchor, index)...max(anchor, index)]))
        } else {
            workspace.select([order[index]])
        }
        proxy.scrollTo(order[index])
    }

    private func openSelection() -> Bool {
        guard workspace.selection.count == 1, let only = workspace.selection.first else { return false }
        workspace.select([only])
        return true
    }

    private func trashSelection() {
        let ids = workspace.selectedDocumentIds
        guard !ids.isEmpty else { return }
        HistoryActions.moveToTrash(ids)
    }

    private func openFirstResult() {
        if let hit = library.searchResults?.hits.first { openResult(hit) }
    }

    private func openResult(_ hit: SearchHit) {
        workspace.open(document: hit.id)
        // Jump to the first match and leave the editor's find bar open with the term.
        PendingFind.shared.request(document: hit.id, query: library.searchResults?.query ?? library.query)
    }
}

/// Passes a search from the history to the editor that is about to open.
@MainActor
final class PendingFind: ObservableObject {
    static let shared = PendingFind()
    @Published private(set) var request: (UUID, String)?
    func request(document: UUID, query: String) { request = (document, query) }
    func consume(for document: UUID) -> String? {
        guard let r = request, r.0 == document else { return nil }
        request = nil
        return r.1
    }
}

// MARK: - Rows

struct QueueRow: View {
    let job: TranscriptionJob
    let isSelected: Bool
    let listFocused: Bool
    @ObservedObject private var models = ModelDownloadCenter.shared
    @State private var hovering = false

    var body: some View {
        let p = JobPresentation(job)
        HStack(alignment: .center, spacing: 8) {
            ZStack {
                Image(systemName: job.source.systemImage)
                    .font(.system(size: 13))
                    .foregroundStyle(TX.Colors.textSecondary)
                    .opacity(hovering && canDrag ? 0 : 1)
                if hovering && canDrag {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 11))
                        .foregroundStyle(TX.Colors.textTertiary)
                }
            }
            .frame(width: 16)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(p.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(TX.Colors.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let tag = p.tag, job.status == .failed || job.status == .recoverable {
                        TXStatusTag(text: tag.0, kind: tag.1)
                    }
                }
                Text(p.statusLine)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(job.status == .failed ? TX.Colors.error : TX.Colors.textSecondary)
                    .lineLimit(1)
                if let kind = p.progress {
                    TXProgressLine(kind: kind)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
            if hovering, job.canCancel {
                Button {
                    WorkspaceState.shared.cancel(job: job.id)
                } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(TXIconButtonStyle(iconSize: 13))
                    .help(TXL.t("job.cancel", "Cancelar trabajo"))
                    .accessibilityLabel(TXL.t("job.cancel", "Cancelar trabajo"))
            }
        }
        .padding(.horizontal, 8)
        .frame(minHeight: TX.Size.queueRow)
        .background(
            RoundedRectangle(cornerRadius: TX.Radius.row, style: .continuous)
                .fill(isSelected ? (listFocused ? TX.Colors.selectionRow : TX.Colors.selectionRowInactive) : (hovering ? TX.Colors.bgHover : .clear))
        )
        .onHover { hovering = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(p.accessibilityLabel)
        .accessibilityValue(p.accessibilityValue ?? "")
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        .accessibilityAction(named: TXL.t("job.priority.up", "Subir prioridad")) { JobManager.shared.move(job.id, .up) }
        .accessibilityAction(named: TXL.t("job.priority.down", "Bajar prioridad")) { JobManager.shared.move(job.id, .down) }
        .accessibilityAction(named: TXL.t("job.cancel", "Cancelar trabajo")) { WorkspaceState.shared.cancel(job: job.id) }
    }

    /// The first row (active job) cannot move.
    private var canDrag: Bool { job.status != .processing }
}

struct QueueContextMenu: View {
    let job: TranscriptionJob
    var body: some View {
        let jobs = JobManager.shared
        if job.status == .recoverable {
            Button(TXL.t("recovery.resume", "Reanudar")) { jobs.retry(jobId: job.id) }
            Button(TXL.t("recovery.discard", "Descartar…")) { RecoveryActions.confirmDiscard(job) }
            Divider()
        }
        if job.status == .failed {
            Button(TXL.t("common.retry", "Reintentar")) { jobs.retry(jobId: job.id) }
            Button(TXL.t("job.removeFromQueue", "Quitar de la cola")) { jobs.remove(jobId: job.id) }
            Divider()
        }
        if job.status != .processing {
            Button(TXL.t("job.move.top", "Mover al principio")) { jobs.move(job.id, .top) }.disabled(!jobs.canMove(job.id, .top))
            Button(TXL.t("job.move.up", "Subir")) { jobs.move(job.id, .up) }.disabled(!jobs.canMove(job.id, .up))
            Button(TXL.t("job.move.down", "Bajar")) { jobs.move(job.id, .down) }.disabled(!jobs.canMove(job.id, .down))
            Button(TXL.t("job.move.bottom", "Mover al final")) { jobs.move(job.id, .bottom) }.disabled(!jobs.canMove(job.id, .bottom))
        }
        if job.canCancel {
            Divider()
            Button(TXL.t("job.cancel", "Cancelar trabajo")) { WorkspaceState.shared.cancel(job: job.id) }
        }
        if job.fileURL.isFileURL {
            Divider()
            Button(TXL.t("common.showInFinder", "Mostrar en Finder")) {
                NSWorkspace.shared.activateFileViewerSelecting([job.fileURL])
            }
        }
    }
}

private struct QueueDropDelegate: DropDelegate {
    let target: UUID
    @Binding var dragging: UUID?

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target else { return }
        let jobs = JobManager.shared
        guard let from = jobs.inProcessJobs.firstIndex(where: { $0.id == dragging }),
              let to = jobs.inProcessJobs.firstIndex(where: { $0.id == target }),
              jobs.job(target)?.status != .processing, jobs.job(dragging)?.status != .processing else { return }
        let steps = to - from
        for _ in 0..<abs(steps) { jobs.move(dragging, steps > 0 ? .down : .up) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool { dragging = nil; return true }
}

struct HistoryRow: View {
    let item: HistoryItem
    let isSelected: Bool
    let listFocused: Bool
    var isNew = false
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: item.isLink ? "link" : "doc.text")
                .font(.system(size: 13))
                .foregroundStyle(TX.Colors.textSecondary)
                .frame(width: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.title)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(TX.Colors.textPrimary)
                        .lineLimit(1)
                    if isNew {
                        TXStatusTag(text: TXL.t("job.status.ready", "Lista"), kind: .success)
                            .transition(.opacity)
                    }
                }
                Text(item.metadataLine)
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .tracking(0.2)
                    .foregroundStyle(TX.Colors.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if item.hasFavorites {
                Image(systemName: "star.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(TX.Colors.accentText)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 8)
        .frame(minHeight: TX.Size.historyRow)
        .background(
            RoundedRectangle(cornerRadius: TX.Radius.row, style: .continuous)
                .fill(isSelected ? (listFocused ? TX.Colors.selectionRow : TX.Colors.selectionRowInactive) : (hovering ? TX.Colors.bgHover : .clear))
        )
        .onHover { hovering = $0 }
        .animation(TX.Motion.hover, value: hovering)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.accessibilityLabel + (item.hasFavorites ? ", " + TXL.t("a11y.hasFavorites", "con favoritos") : ""))
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        .accessibilityAction(named: TXL.t("history.export", "Exportar…")) { HistoryActions.export([item.id]) }
        .accessibilityAction(named: TXL.t("history.saveProject", "Guardar como proyecto…")) { HistoryActions.saveProject(item.id) }
        .accessibilityAction(named: TXL.t("history.moveToTrash", "Mover a Eliminados recientemente")) { HistoryActions.moveToTrash([item.id]) }
    }
}

struct SearchResultRow: View {
    let hit: SearchHit
    let isSelected: Bool
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(hit.item.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(TX.Colors.textPrimary)
                .lineLimit(1)
            Text(highlighted)
                .font(.system(size: 12))
                .foregroundStyle(TX.Colors.textSecondary)
                .lineLimit(2)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .frame(minHeight: TX.Size.historyRowSearch, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: TX.Radius.row, style: .continuous)
                .fill(isSelected ? TX.Colors.selectionRow : (hovering ? TX.Colors.bgHover : .clear))
        )
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private var highlighted: AttributedString {
        var a = AttributedString(hit.snippet)
        for r in hit.matchRanges {
            guard let lower = AttributedString.Index(r.lowerBound, within: a),
                  let upper = AttributedString.Index(r.upperBound, within: a) else { continue }
            a[lower..<upper].font = .system(size: 12, weight: .semibold)
            a[lower..<upper].foregroundColor = TX.Colors.accentText
        }
        return a
    }
}

/// «Modelo listo · medium» while a whisper process holds it, otherwise «Modelo en reposo».
/// whisper-cli loads the model in each transcription and frees it when it finishes (spec 8.6 adapted).
/// Pie de la barra lateral con estado en memoria y popover interactivo (spec 6.3).
struct ModelStatusLine: View {
    @ObservedObject private var jobs = JobManager.shared
    @State private var showingPopover = false

    private var inUseId: String? { jobs.modelInUse }
    private var inUseDescriptor: ModelDescriptor? { inUseId.flatMap { ModelCatalog.descriptor(id: $0) } }
    private var inUseName: String {
        guard let inUseId else { return TXL.t("model.memory.none", "Ningún modelo en memoria") }
        return inUseDescriptor?.displayName ?? inUseId
    }

    private var statusLineText: String {
        guard let job = jobs.currentJob else {
            return TXL.t("model.memory.none", "Ningún modelo en memoria")
        }
        switch job.phase {
        case .loadingModel:
            return TXL.f("model.status.loading", "Cargando %@…", inUseName)
        case .transcribing:
            return TXL.f("model.status.ready", "Modelo listo · %@", inUseName)
        default:
            return TXL.t("model.memory.none", "Ningún modelo en memoria")
        }
    }

    var body: some View {
        Button {
            showingPopover.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: inUseId == nil ? "circle.dashed" : "circle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(inUseId == nil ? TX.Colors.textTertiary : TX.Colors.purpleX)
                    .accessibilityHidden(true)
                Text(statusLineText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(inUseId == nil ? TX.Colors.textTertiary : TX.Colors.textPrimary)
                    .lineLimit(1)
                Spacer()
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(statusLineText)
        .popover(isPresented: $showingPopover, arrowEdge: .top) {
            popoverContent
        }
    }

    private var popoverContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(TXL.t("models.sidebar.detailsTitle", "Estado del modelo"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(TX.Colors.textPrimary)

            Divider()

            if let id = inUseId {
                let desc = inUseDescriptor
                let name = desc?.displayName ?? id
                let engine = desc?.engine.badge ?? "Whisper"
                let compute = (desc?.capabilities.computeUnits == .neuralEngine) ? "Neural Engine" : "CPU"

                infoRow(label: TXL.t("models.sidebar.model", "Modelo"), value: name)
                infoRow(label: TXL.t("models.sidebar.engine", "Motor"), value: engine)
                infoRow(label: TXL.t("models.sidebar.technicalId", "ID técnico"), value: id)
                infoRow(label: TXL.t("models.sidebar.compute", "Unidades"), value: compute)
                infoRow(label: TXL.t("models.sidebar.task", "Tarea"), value: TXL.t("models.task.files", "Archivos"))

                Divider()

                Button(TXL.t("models.memory.freeNow", "Liberar ahora")) {
                    if let activeId = jobs.jobs.first(where: { $0.status == .processing })?.id {
                        _ = jobs.cancel(jobId: activeId)
                    }
                    showingPopover = false
                }
                .buttonStyle(TXSecondaryButtonStyle())
                .controlSize(.small)
            } else {
                Text(TXL.t("models.sidebar.noModelLoaded", "No hay ningún modelo cargado actualmente en memoria."))
                    .font(.system(size: 12))
                    .foregroundStyle(TX.Colors.textSecondary)
            }
        }
        .padding(14)
        .frame(width: 250)
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack {
            Text(label).font(.system(size: 11)).foregroundStyle(TX.Colors.textSecondary)
            Spacer()
            Text(value).font(.system(size: 11, weight: .medium)).foregroundStyle(TX.Colors.textPrimary)
        }
    }
}
