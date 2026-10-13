import SwiftUI
import Combine
import AVFoundation
import UniformTypeIdentifiers

/// The five views of the work area (spec 4.2).
enum WorkspaceRoute: Hashable {
    case home
    case job(UUID)
    case live
    case document(UUID)
    case trash
}

enum SidebarID: Hashable {
    case job(UUID)
    case document(UUID)
}

enum InspectorTab: String, CaseIterable, Identifiable {
    case speakers, ai, translation, details
    var id: String { rawValue }
    var title: String {
        switch self {
        case .speakers: return TXL.t("inspector.tab.speakers", "Hablantes")
        case .ai: return TXL.t("inspector.tab.ai", "IA")
        case .translation: return TXL.t("inspector.tab.translation", "Traducción")
        case .details: return TXL.t("inspector.tab.details", "Detalles")
        }
    }
}

// MARK: - Banners (top of the work area, one visible, spec 3.4)

enum BannerKind: Equatable { case info, warning, error, meeting, recovery }

struct BannerAction: Identifiable {
    let id = UUID()
    let title: String
    var isPrimary = false
    let handler: () -> Void
}

struct BannerItem: Identifiable {
    let id = UUID()
    /// Deduplication key («memory», «recovery», «meeting», «migration», «save:<id>»…).
    let key: String
    let kind: BannerKind
    let title: String
    var message: String?
    var details: String? = nil
    var actions: [BannerAction] = []
    var dismissible = true
}

// MARK: - Toasts (36 pt, bottom centre, 4 s; 8 s with VoiceOver)

struct ToastItem: Identifiable {
    enum Icon { case success, info, warning, error }
    let id = UUID()
    let icon: Icon
    let text: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    var duration: TimeInterval = 4
}

// MARK: - Import chips (home canvas, spec 6.3)

struct ImportChip: Identifiable, Equatable {
    enum State: Equatable {
        case reading
        case ready
        case unreadable(String?)
        case project
    }
    let id = UUID()
    let url: URL
    var duration: TimeInterval?
    var size: Int64
    var state: State

    var name: String { url.lastPathComponent }
    var isTranscribable: Bool { state == .ready || state == .reading }
    var typeSymbol: String {
        if state == .project { return "doc.richtext" }
        if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .movie) { return "film" }
        return "waveform"
    }
}

// MARK: - Sheets

enum WorkspaceSheet: Identifiable {
    case url(prefill: String?, fromScheme: Bool, jobId: UUID?)
    case export(ExportRequest)
    case diagnostics
    case accessibilityPermission
    /// Recording sources when Inicio, where Grabar lives, is not on screen.
    case recordOptions

    var id: String {
        switch self {
        case .url: return "url"
        case .export: return "export"
        case .diagnostics: return "diagnostics"
        case .accessibilityPermission: return "ax"
        case .recordOptions: return "recordOptions"
        }
    }
}

/// What to export: one document or a batch (spec 6.16, 6.17).
struct ExportRequest: Equatable {
    var documentIds: [UUID]
    var isBatch: Bool { documentIds.count != 1 }
    var wholeHistory = false
}

// MARK: - Workspace state

@MainActor
final class WorkspaceState: ObservableObject {
    static let shared = WorkspaceState()

    /// Modelo pedido por `transcriptorx://transcribe?…&model=` (el sheet de enlace lo preselecciona y lo consume).
    var schemeModelId: String?

    @Published var route: WorkspaceRoute = .home {
        didSet { routeDidChange(from: oldValue) }
    }
    @Published var selection: Set<SidebarID> = []
    @Published var columnVisibility: NavigationSplitViewVisibility = .all

    /// User asked for the inspector (⌥⌘I). Remembered across launches.
    @Published var inspectorRequested: Bool = UserDefaults.standard.bool(forKey: "workspace.inspectorOpen") {
        didSet { UserDefaults.standard.set(inspectorRequested, forKey: "workspace.inspectorOpen") }
    }
    /// The window is narrower than 1040 pt: the inspector closes and returns with the width (spec 4.4).
    @Published var inspectorCollapsedByWidth = false
    @Published private var inspectorTabs: [UUID: InspectorTab] = [:]

    @Published private(set) var banners: [BannerItem] = []
    @Published var toast: ToastItem?
    @Published var sheet: WorkspaceSheet?
    @Published var importChips: [ImportChip] = []
    /// The recording sources popover hangs from Grabar in Inicio; anywhere else (a document,
    /// the live view, the menu bar) the same choices open as a sheet.
    @Published var showRecordPopover = false {
        didSet {
            if !showRecordPopover {
                if case .recordOptions = sheet { sheet = nil }
                return
            }
            guard route != .home || !importChips.isEmpty else { return }
            showRecordPopover = false
            sheet = .recordOptions
        }
    }
    /// Jobs that just finished, shown with the «Lista» tag for 4 s.
    @Published private(set) var recentlyCompleted: Set<UUID> = []
    /// Increments to move focus to the history search (⇧⌘F).
    @Published var focusHistorySearchToken = 0
    /// Opening animation still covering the work area (spec 9).
    @Published var openingAnimationActive = false

    private var cancellables = Set<AnyCancellable>()
    private var toastTask: Task<Void, Never>?

    var inspectorVisible: Bool {
        guard case .document = route else { return false }
        return inspectorRequested && !inspectorCollapsedByWidth
    }

    var currentDocumentId: UUID? {
        if case .document(let id) = route { return id }
        return nil
    }

    private init() {
        JobManager.shared.completed
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.jobCompleted($0) }
            .store(in: &cancellables)
        observeLegacyNotifications()
    }

    // MARK: Navigation

    func goHome() {
        selection = []
        route = .home
    }

    func open(document id: UUID) {
        selection = [.document(id)]
        route = .document(id)
    }

    func open(job id: UUID) {
        selection = [.job(id)]
        route = .job(id)
    }

    func showTrash() {
        selection = []
        route = .trash
    }

    /// Applies a sidebar selection change (single or multiple).
    func select(_ newSelection: Set<SidebarID>) {
        selection = newSelection
        guard newSelection.count == 1, let only = newSelection.first else { return }
        switch only {
        case .job(let id): route = .job(id)
        case .document(let id): route = .document(id)
        }
    }

    var selectedDocumentIds: [UUID] {
        selection.compactMap { if case .document(let id) = $0 { return id } else { return nil } }
    }

    private func routeDidChange(from old: WorkspaceRoute) {
        if case .document(let id) = route {
            UserDefaults.standard.set(id.uuidString, forKey: "restore.documentId")
        } else if route == .home {
            UserDefaults.standard.removeObject(forKey: "restore.documentId")
        }
    }

    // MARK: Inspector

    func inspectorTab(for document: UUID) -> InspectorTab {
        if let tab = inspectorTabs[document] { return tab }
        if let raw = UserDefaults.standard.string(forKey: "inspector.tab.\(document.uuidString)"),
           let tab = InspectorTab(rawValue: raw) { return tab }
        return .speakers
    }

    func setInspectorTab(_ tab: InspectorTab, for document: UUID) {
        inspectorTabs[document] = tab
        UserDefaults.standard.set(tab.rawValue, forKey: "inspector.tab.\(document.uuidString)")
    }

    func toggleInspector() {
        if inspectorCollapsedByWidth {
            // Explicit request wins over the automatic collapse only when there is room for it.
            inspectorRequested = true
        } else {
            inspectorRequested.toggle()
        }
    }

    func showInspector(tab: InspectorTab) {
        guard let id = currentDocumentId else { return }
        setInspectorTab(tab, for: id)
        inspectorRequested = true
    }

    // MARK: Banners (max one visible; the rest stacks as «2 avisos más»)

    func post(_ banner: BannerItem) {
        banners.removeAll { $0.key == banner.key }
        // Errors and recovery go first.
        if banner.kind == .error || banner.kind == .recovery {
            banners.insert(banner, at: 0)
        } else {
            banners.append(banner)
        }
        if banner.kind == .error { AccessibilityAnnouncer.announce(banner.title, highPriority: true) }
        else { AccessibilityAnnouncer.announce(banner.title) }
    }

    func dismissBanner(key: String) {
        banners.removeAll { $0.key == key }
    }

    func hasBanner(_ key: String) -> Bool { banners.contains { $0.key == key } }

    /// Moves the first banner to the back so the next one shows («2 avisos más»).
    func cycleBanners() {
        guard banners.count > 1 else { return }
        banners.append(banners.removeFirst())
    }

    // MARK: Toasts

    func showToast(_ toast: ToastItem) {
        toastTask?.cancel()
        self.toast = toast
        AccessibilityAnnouncer.announce(toast.text)
        let duration = NSWorkspace.shared.isVoiceOverEnabled ? max(8, toast.duration) : toast.duration
        let id = toast.id
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled, self?.toast?.id == id else { return }
            self?.toast = nil
        }
    }

    func dismissToast() {
        toastTask?.cancel()
        toast = nil
    }

    // MARK: Jobs

    private func jobCompleted(_ c: JobCompletion) {
        recentlyCompleted.insert(c.id)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            self?.recentlyCompleted.remove(c.id)
        }
        AccessibilityAnnouncer.announce(TXL.f("job.announce.ready", "%@, lista", c.title))
        if route == .job(c.id) {
            // The user is on that job: the document replaces the progress view (200 ms fade).
            withAnimation(.easeOut(duration: 0.2)) { open(document: c.id) }
            DocumentFocus.shared.pendingFocusFirstSegment = c.id
        } else {
            // Never switch documents without being asked.
            showToast(ToastItem(icon: .success,
                                text: TXL.f("toast.jobReady", "%@ está lista", c.title),
                                actionTitle: TXL.t("common.open", "Abrir"),
                                action: { [weak self] in self?.open(document: c.id) }))
        }
    }

    func cancel(job id: UUID) {
        guard let job = JobManager.shared.job(id) else { return }
        let undo = JobManager.shared.cancel(jobId: id)
        if route == .job(id) { goHome() }
        if let undo {
            showToast(ToastItem(icon: .info, text: TXL.t("toast.jobCancelled", "Trabajo cancelado"),
                                actionTitle: TXL.t("common.undo", "Deshacer"),
                                action: { JobManager.shared.requeue(undo) }, duration: 5))
        } else {
            showToast(ToastItem(icon: .info, text: TXL.f("toast.jobCancelledNamed", "%@ cancelado", job.displayTitle)))
        }
    }

    // MARK: Imports

    func addImports(_ urls: [URL]) {
        for url in urls where !importChips.contains(where: { $0.url == url }) {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            if url.pathExtension == ProjectPackage.fileExtension {
                openProject(url)
                continue
            }
            let chip = ImportChip(url: url, duration: nil, size: size, state: .reading)
            importChips.append(chip)
            inspectChip(chip.id, url: url)
        }
        if route != .home, !importChips.isEmpty { goHome() }
    }

    private func inspectChip(_ id: UUID, url: URL) {
        Task {
            let result = await MediaProbe.probe(url)
            guard let i = importChips.firstIndex(where: { $0.id == id }) else { return }
            switch result {
            case .readable(let duration):
                importChips[i].duration = duration
                importChips[i].state = .ready
            case .unreadable(let details):
                importChips[i].state = .unreadable(details)
            }
        }
    }

    func openProject(_ url: URL) {
        Task {
            do {
                let (transcription, _) = try await Task.detached { try ProjectPackage.open(from: url) }.value
                TranscriptionStorage.shared.saveTranscription(transcription)
                LibraryStore.shared.didSave(transcription)
                open(document: transcription.id)
                showToast(ToastItem(icon: .success, text: TXL.t("toast.projectOpened", "Proyecto abierto y añadido al historial")))
            } catch {
                ProjectAlerts.showDamaged(url: url, error: error)
            }
        }
    }

    // MARK: Legacy notifications (menu bar, deep links, App menu)

    private func observeLegacyNotifications() {
        let nc = NotificationCenter.default
        nc.publisher(for: .showNewTranscription).receive(on: RunLoop.main)
            .sink { [weak self] _ in WindowCoordinator.showMainWindow(); self?.goHome() }.store(in: &cancellables)
        nc.publisher(for: .showRecorder).receive(on: RunLoop.main)
            .sink { _ in WindowCoordinator.showMainWindow(); RecordingController.shared.primaryAction() }.store(in: &cancellables)
        nc.publisher(for: .transcribeURL).receive(on: RunLoop.main)
            .sink { [weak self] note in
                WindowCoordinator.showMainWindow()
                self?.schemeModelId = note.userInfo?["model"] as? String
                self?.sheet = .url(prefill: note.userInfo?["url"] as? String, fromScheme: true, jobId: nil)
            }.store(in: &cancellables)
        nc.publisher(for: .openNewTranscriptionWithFile).receive(on: RunLoop.main)
            .sink { [weak self] note in
                if let url = note.userInfo?["fileURL"] as? URL { self?.addImports([url]) }
            }.store(in: &cancellables)
        nc.publisher(for: .showLibrary).receive(on: RunLoop.main)
            .sink { [weak self] _ in
                WindowCoordinator.showMainWindow()
                self?.columnVisibility = .all
            }.store(in: &cancellables)
    }
}

// MARK: - Media probing (duration and readability without blocking the UI)

enum MediaProbe {
    enum Result { case readable(TimeInterval?), unreadable(String?) }

    static func probe(_ url: URL) async -> Result {
        let asset = AVURLAsset(url: url)
        if let d = try? await asset.load(.duration) {
            let seconds = CMTimeGetSeconds(d)
            if seconds.isFinite && seconds > 0 { return .readable(seconds) }
        }
        // AVFoundation does not read everything FFmpeg reads: ask ffprobe when available.
        let candidates = ["/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe"]
        guard let ffprobe = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            return .readable(nil)
        }
        return await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: ffprobe)
            p.arguments = ["-v", "error", "-show_entries", "format=duration", "-of", "default=nw=1:nk=1", url.path]
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            do { try p.run() } catch { return .readable(nil) }
            p.waitUntilExit()
            let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if p.terminationStatus != 0 { return .unreadable(stderr.trimmingCharacters(in: .whitespacesAndNewlines)) }
            return .readable(Double(stdout.trimmingCharacters(in: .whitespacesAndNewlines)))
        }.value
    }
}

// MARK: - App-wide notifications (menu bar, deep links, services)

extension Notification.Name {
    static let showNewTranscription = Notification.Name("showNewTranscription")
    static let showRecorder = Notification.Name("showRecorder")
    static let openNewTranscriptionWithFile = Notification.Name("openNewTranscriptionWithFile")
    static let showLibrary = Notification.Name("showLibrary")
    static let meetingDetected = Notification.Name("meetingDetected")   // #7
}
