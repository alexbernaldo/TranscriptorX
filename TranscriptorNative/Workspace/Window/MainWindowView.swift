import SwiftUI
import UniformTypeIdentifiers

/// One window, three regions (spec 4): Historial, work area, inspector on request.
struct MainWindowView: View {
    @EnvironmentObject var workspace: WorkspaceState
    @EnvironmentObject var localizationManager: LocalizationManager
    @ObservedObject private var library = LibraryStore.shared
    @ObservedObject private var jobs = JobManager.shared
    @ObservedObject private var recording = RecordingController.shared
    @ObservedObject private var onboarding = OnboardingState.shared
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.undoManager) private var undoManager
    @State private var dropState: DropState = .none
    @State private var windowSize: CGSize = TX.Window.initial
    @ObservedObject private var opening = OpeningAnimator.shared

    enum DropState { case none, valid, invalid }

    var body: some View {
        Group {
            if onboarding.isShowingWizard {
                WizardView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(TX.Colors.bgWindow)
            } else {
                splitView
            }
        }
        .frame(minWidth: TX.Window.minimum.width, minHeight: TX.Window.minimum.height - TX.Size.toolbar)
        .background(GeometryReader { geo in
            Color.clear
                .onAppear { windowSize = geo.size; updateInspectorCollapse(geo.size.width) }
                .txOnChange(of: geo.size) { size in windowSize = size; updateInspectorCollapse(size.width) }
        })
        .environment(\.isCompactHeight, windowSize.height < TX.Window.compactHeight)
        .environment(\.workAreaWidth, workAreaWidth)
        .sheet(item: $workspace.sheet) { sheet in sheetView(sheet) }
        .onAppear {
            WindowCoordinator.openMainWindowAction = { openWindow(id: WindowCoordinator.mainWindowID) }
            SettingsNavigator.shared.openAction = { openSettings() }
        }
    }

    // MARK: Split view

    private var splitView: some View {
        NavigationSplitView(columnVisibility: $workspace.columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: TX.Size.sidebarMin, ideal: TX.Size.sidebar, max: TX.Size.sidebarMax)
        } detail: {
            HStack(spacing: 0) {
                workArea
                    .frame(minWidth: TX.Size.workspaceMin)
                if workspace.inspectorVisible, let id = workspace.currentDocumentId, let session = DocumentSessions.shared.session(for: id) {
                    TXSeparator(vertical: true)
                    InspectorView(editor: session.editor)
                        .frame(width: TX.Size.inspector)
                        .transition(inspectorTransition)
                }
            }
            .animation(inspectorAnimation, value: workspace.inspectorVisible)
            .background(TX.Colors.bgWindow)
            .navigationTitle(title)
            .navigationSubtitle(subtitle)
            .toolbar { MainToolbar() }
        }
        .navigationSplitViewStyle(.balanced)
        .onDrop(of: [.fileURL], delegate: WindowDropDelegate(state: $dropState))
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var inspectorTransition: AnyTransition {
        reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity)
    }

    private var inspectorAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.15) : TX.Motion.inspector
    }

    private var workAreaWidth: CGFloat {
        let sidebar = workspace.columnVisibility == .detailOnly ? 0 : TX.Size.sidebar
        let inspector = workspace.inspectorVisible ? TX.Size.inspector : 0
        return windowSize.width - sidebar - inspector
    }

    /// Below 1040 pt the inspector closes first, and returns with the width (spec 4.4).
    private func updateInspectorCollapse(_ width: CGFloat) {
        let collapse = width < TX.Size.inspectorCollapseWidth
        if collapse != workspace.inspectorCollapsedByWidth { workspace.inspectorCollapsedByWidth = collapse }
    }

    // MARK: Work area

    private var workArea: some View {
        VStack(spacing: 0) {
            BannerStack()
            ZStack {
                route
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(opening.contentVisible ? 1 : 0)
                    .offset(y: opening.contentVisible || reduceMotion ? 0 : 8)
                    .overlayPreferenceValue(HomeMarkAnchorKey.self) { anchor in
                        GeometryReader { geo in
                            if workspace.openingAnimationActive {
                                OpeningAnimationLayer(target: workspace.route == .home ? anchor.map { geo[$0] } : nil,
                                                      documentTitle: workspace.currentDocumentId.flatMap { library.item($0)?.title })
                            }
                        }
                    }
                if dropState != .none { dropOverlay }
                ToastHost()
            }
        }
        .background(translationDriver)
        .onReceive(NotificationCenter.default.publisher(for: .adjustTimesRequested)) { note in
            guard let id = note.object as? UUID, let editor = CommandRouter.shared.editor else { return }
            editor.scrollRequest = .init(id: id, anchor: .center, animated: false)
            AdjustTimesRequest.shared.segmentId = id
        }
        .onAppear { opening.runIfNeeded(workspace: workspace, reduceMotion: reduceMotion) }
        .accessibilityElement(children: .contain)
    }

    /// Apple Translation sessions only exist inside `.translationTask`; kept at the window root so
    /// a translation continues when the inspector tab changes.
    @ViewBuilder private var translationDriver: some View {
        if #available(macOS 15.0, *) {
            AppleTranslationDriver(controller: TranslationController.shared)
        }
    }

    @ViewBuilder private var route: some View {
        switch workspace.route {
        case .home:
            HomeView()
        case .job(let id):
            if let job = jobs.job(id), job.status != .completed {
                JobView(job: job)
            } else if library.document(id) != nil {
                DocumentView(documentId: id).onAppear { workspace.open(document: id) }
            } else {
                HomeView()
            }
        case .live:
            LiveRecordingView()
        case .document(let id):
            if library.document(id) != nil {
                DocumentView(documentId: id).id(id)
            } else if library.state != .ready {
                Color.clear
            } else {
                HomeView().onAppear { workspace.goHome() }
            }
        case .trash:
            TrashView()
        }
    }

    private var dropOverlay: some View {
        ZStack {
            TX.Colors.bgWindow.opacity(0.85)
            RoundedRectangle(cornerRadius: TX.Radius.dropZone, style: .continuous)
                .strokeBorder(dropState == .valid ? TX.Colors.purpleX : TX.Colors.border,
                              style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .padding(8)
            Text(dropState == .valid
                 ? TXL.t("drop.valid", "Suelta para añadir")
                 : TXL.t("drop.invalid", "Este tipo de archivo no se puede transcribir"))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(dropState == .valid ? TX.Colors.textPrimary : TX.Colors.textSecondary)
        }
        .allowsHitTesting(false)
    }

    // MARK: Title

    private var title: String {
        let selected = workspace.selectedDocumentIds
        if selected.count > 1 { return TXL.f("toolbar.selectedCount", "%d seleccionadas", selected.count) }
        switch workspace.route {
        case .home: return TXL.t("toolbar.newTranscription", "Nueva transcripción")
        case .job(let id): return jobs.job(id)?.displayTitle ?? "Transcriptor X"
        case .live: return TXL.t("live.title", "Grabación")
        case .document(let id): return DocumentSessions.shared.session(for: id)?.editor.document.title ?? library.item(id)?.title ?? ""
        case .trash: return TXL.t("trash.title", "Eliminados recientemente")
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if case .document(let id) = workspace.route, let item = library.item(id) {
            parts.append(TXFormat.longDateTime(item.createdAt).components(separatedBy: ",").first ?? "")
            if item.duration > 0 { parts.append(TXFormat.shortDuration(item.duration)) }
        }
        // «2 en cola» when the current view is not the queue (spec 4.2).
        let active = jobs.activeCount
        if active > 0, !isOnQueue {
            parts.append(TXL.f("toolbar.queueCount", "%d en cola", active))
        }
        return parts.joined(separator: " · ")
    }

    private var isOnQueue: Bool {
        if case .job = workspace.route { return true }
        return false
    }

    // MARK: Sheets

    @ViewBuilder private func sheetView(_ sheet: WorkspaceSheet) -> some View {
        switch sheet {
        case .url(let prefill, let fromScheme, let jobId):
            LinkSheet(prefill: prefill, fromScheme: fromScheme, existingJobId: jobId)
                .environmentObject(workspace)
        case .export(let request):
            ExportSheet(request: request)
                .environmentObject(workspace)
        case .diagnostics:
            DiagnosticsSheet()
        case .accessibilityPermission:
            AccessibilityPermissionSheet()
        case .recordOptions:
            VStack(alignment: .trailing, spacing: 0) {
                RecordPopover()
                Button(TXL.t("common.close", "Cerrar")) { workspace.sheet = nil }
                    .buttonStyle(TXBorderlessButtonStyle())
                    .keyboardShortcut(.cancelAction)
                    .padding([.horizontal, .bottom], TX.Space.s16)
            }
        }
    }
}

// MARK: - Environment

private struct CompactHeightKey: EnvironmentKey { static let defaultValue = false }
private struct WorkAreaWidthKey: EnvironmentKey { static let defaultValue: CGFloat = 800 }

extension EnvironmentValues {
    /// Window shorter than 600 pt: compact document header and 44 pt player (spec 4.4).
    var isCompactHeight: Bool {
        get { self[CompactHeightKey.self] }
        set { self[CompactHeightKey.self] = newValue }
    }
    var workAreaWidth: CGFloat {
        get { self[WorkAreaWidthKey.self] }
        set { self[WorkAreaWidthKey.self] = newValue }
    }
}

// MARK: - Drop anywhere in the window (spec 6.3)

struct WindowDropDelegate: DropDelegate {
    @Binding var state: MainWindowView.DropState

    static let accepted: [UTType] = [.audiovisualContent, .audio, .movie, UTType(filenameExtension: "transcriptor") ?? .data]

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: Self.accepted)
    }

    func dropEntered(info: DropInfo) {
        state = validateDrop(info: info) ? .valid : .invalid
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: validateDrop(info: info) ? .copy : .forbidden)
    }

    func dropExited(info: DropInfo) { state = .none }

    func performDrop(info: DropInfo) -> Bool {
        state = .none
        guard validateDrop(info: info) else { return false }
        let providers = info.itemProviders(for: [.fileURL])
        Task { @MainActor in
            var urls: [URL] = []
            for provider in providers {
                if let url = await loadURL(provider), FileInputService.isSupported(url) || url.pathExtension == ProjectPackage.fileExtension {
                    urls.append(url)
                }
            }
            WorkspaceState.shared.addImports(urls)
        }
        return true
    }

    private func loadURL(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
        }
    }
}
