import SwiftUI
import AppKit
import Combine

// MARK: - Non-activating panel base

/// Borderless panel that never becomes key or main: it does not steal focus from the active app
/// and floats over every Space and full-screen app (spec 6.8, 6.23, 6.24, 10.7, 10.8).
final class NonActivatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(size: NSSize, ignoresMouse: Bool = false, title: String) {
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        ignoresMouseEvents = ignoresMouse
        isReleasedWhenClosed = false
        self.title = title
        setAccessibilityLabel(title)
    }
}

// MARK: - Floating recording panel (spec 6.8)

@MainActor
final class FloatingRecordingPanelController: NSObject, NSWindowDelegate {
    static let shared = FloatingRecordingPanelController()
    private var panel: NonActivatingPanel?
    private var observers = Set<AnyCancellable>()
    static let compact = NSSize(width: 300, height: 52)
    static let expanded = NSSize(width: 300, height: 120)

    private override init() {
        super.init()
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .merge(with: NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification))
            .merge(with: NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification))
            .merge(with: NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification))
            .merge(with: NotificationCenter.default.publisher(for: NSWindow.willCloseNotification))
            .debounce(for: .milliseconds(80), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.update() }
            .store(in: &observers)
        WorkspaceState.shared.$route
            .debounce(for: .milliseconds(50), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.update() }
            .store(in: &observers)
    }

    /// Shown while recording unless the main window is in front showing the live view
    /// (no duplicated controls). Also shows «Procesando…» and capture errors.
    func update() {
        let controller = RecordingController.shared
        let relevant: Bool
        switch controller.phase {
        case .recording, .processing, .failed: relevant = true
        default: relevant = false
        }
        let windowShowsLive = WindowCoordinator.isMainWindowFrontmost && WorkspaceState.shared.route == .live
        if relevant && !windowShowsLive { show() } else { hide() }
    }

    private func show() {
        if panel == nil {
            let panel = NonActivatingPanel(size: Self.compact, title: TXL.t("recordingPanel.title", "Panel de grabación"))
            panel.isMovableByWindowBackground = true
            let host = NSHostingView(rootView: FloatingRecordingPanelView()
                .environmentObject(RecordingController.shared))
            host.frame = NSRect(origin: .zero, size: Self.compact)
            host.autoresizingMask = [.width, .height]
            panel.contentView = host
            panel.delegate = self
            self.panel = panel
            restorePosition(panel)
        }
        guard let panel, !panel.isVisible else { return }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 1
        }
    }

    private func hide() {
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
    }

    /// Hover grows the panel to 96 pt (keeps the top edge).
    func setExpanded(_ expanded: Bool) {
        guard let panel else { return }
        let size = expanded ? Self.expanded : Self.compact
        var frame = panel.frame
        frame.origin.y += frame.height - size.height
        frame.size = size
        panel.setFrame(frame, display: true, animate: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    // Remembers its position per screen.
    private func key(for screen: NSScreen?) -> String {
        let id = (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue ?? "main"
        return "recordingPanel.origin.\(id)"
    }

    private func restorePosition(_ panel: NSPanel) {
        let screen = NSScreen.main ?? NSScreen.screens.first
        if let raw = UserDefaults.standard.string(forKey: key(for: screen)) {
            panel.setFrameOrigin(NSPointFromString(raw))
        } else if let visible = screen?.visibleFrame {
            // Top right, 12 pt below the menu bar.
            panel.setFrameOrigin(NSPoint(x: visible.maxX - Self.compact.width - 12,
                                         y: visible.maxY - Self.compact.height - 12))
        }
    }

    nonisolated func windowDidMove(_ notification: Notification) {
        Task { @MainActor in
            guard let panel = self.panel else { return }
            UserDefaults.standard.set(NSStringFromPoint(panel.frame.origin), forKey: self.key(for: panel.screen))
        }
    }
}

struct FloatingRecordingPanelView: View {
    @EnvironmentObject var controller: RecordingController
    @ObservedObject private var recorder = SystemAudioRecorder.shared
    @ObservedObject private var jobs = JobManager.shared
    @ObservedObject private var live = LiveTranscription.shared
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                indicator
                content
                Spacer(minLength: 4)
                actions
            }
            .frame(height: 36)
            if hovering, case .recording = controller.phase {
                VStack(alignment: .leading, spacing: 4) {
                    if live.text.isEmpty {
                        Text(TXL.t("recordingPanel.noLiveText", "El texto aparecerá cuando termine la grabación."))
                            .font(.system(size: 13))
                            .foregroundStyle(TX.Colors.textSecondary)
                            .lineLimit(2)
                    } else {
                        Text(LiveTranscription.lastSentence(of: live.text))
                            .font(.system(size: 13))
                            .foregroundStyle(TX.Colors.textPrimary)
                            .lineLimit(2)
                    }
                    if let id = live.modelId, live.state == .running || live.state == .loading {
                        ModelInUseChip(modelId: id)
                    }
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(background)
        .overlay(
            RoundedRectangle(cornerRadius: TX.Radius.panel, style: .continuous)
                .strokeBorder(isError ? TX.Colors.error : Color.white.opacity(0.06), lineWidth: isError ? 2 : 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: TX.Radius.panel, style: .continuous))
        .environment(\.colorScheme, .dark)
        .onHover { h in
            hovering = h
            FloatingRecordingPanelController.shared.setExpanded(h && controller.phase == .recording)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(TXL.t("recordingPanel.title", "Panel de grabación"))
    }

    private var isError: Bool { if case .failed = controller.phase { return true }; return false }

    @ViewBuilder private var background: some View {
        if reduceTransparency {
            Color(nsColor: TX.Palette.surface)
        } else {
            ZStack {
                VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                Color(nsColor: TX.Palette.window).opacity(0.88)
            }
        }
    }

    @ViewBuilder private var indicator: some View {
        switch controller.phase {
        case .recording:
            Circle().fill(TX.Colors.record).frame(width: 8, height: 8).accessibilityHidden(true)
        case .processing, .starting:
            ProgressView().controlSize(.small).accessibilityHidden(true)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(TX.Colors.error).accessibilityHidden(true)
        case .idle:
            EmptyView()
        }
    }

    @ViewBuilder private var content: some View {
        switch controller.phase {
        case .recording:
            Text(TXFormat.clock(recorder.recordingDuration))
                .font(.system(size: 15, weight: .medium, design: .monospaced).monospacedDigit())
                .foregroundStyle(TX.Colors.textPrimary)
                .accessibilityLabel(TXL.f("recordingPanel.a11y.elapsed", "Grabando, %@", TXFormat.spokenDuration(recorder.recordingDuration)))
            LevelFragments(level: recorder.audioLevel, color: TX.Colors.purpleX, height: 16)
        case .processing, .starting:
            Text(TXL.t("recordingPanel.processing", "Procesando…"))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(TX.Colors.textPrimary)
        case .failed:
            Text(TXL.t("recordingPanel.interrupted", "La grabación se ha interrumpido"))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(TX.Colors.textPrimary)
                .lineLimit(1)
        case .idle:
            EmptyView()
        }
    }

    @ViewBuilder private var actions: some View {
        switch controller.phase {
        case .recording:
            Button { controller.stop() } label: {
                Image(systemName: "stop.fill").foregroundStyle(TX.Colors.record)
            }
            .buttonStyle(TXIconButtonStyle())
            .help(TXL.t("recording.stop.help", "Detener ⌘."))
            .accessibilityLabel(TXL.t("recording.stop", "Detener"))
            showWindowButton
        case .failed:
            Button(TXL.t("recordingPanel.show", "Mostrar")) {
                controller.dismissError()
                WindowCoordinator.showMainWindow()
                WorkspaceState.shared.route = .live
            }
            .buttonStyle(TXBorderlessButtonStyle())
        default:
            EmptyView()
        }
    }

    private var showWindowButton: some View {
        Button {
            WindowCoordinator.showMainWindow()
            WorkspaceState.shared.route = .live
        } label: {
            Image(systemName: "macwindow")
        }
        .buttonStyle(TXIconButtonStyle())
        .help(TXL.t("recordingPanel.showWindow", "Mostrar ventana"))
        .accessibilityLabel(TXL.t("recordingPanel.showWindow", "Mostrar ventana"))
    }
}

// MARK: - On-screen captions (spec 6.24)

/// Shows the last stable sentence of the transcription being produced over any app.
/// Ignores the mouse (clicks pass through) and is hidden from accessibility (it duplicates the window).
@MainActor
final class LiveCaptionCenter: ObservableObject {
    static let shared = LiveCaptionCenter()

    @Published private(set) var text: String = ""
    @Published private(set) var visible = false
    private var panel: NonActivatingPanel?
    private var hideTask: Task<Void, Never>?
    private var pending: [Task<Void, Never>] = []

    var isEnabled: Bool { UserDefaults.standard.bool(forKey: "liveCaptionEnabled") }
    /// 1…4 s (Ajustes › Subtítulos en pantalla).
    var delay: Double {
        let v = UserDefaults.standard.double(forKey: "liveCaptionDelay")
        return v == 0 ? 2 : min(max(v, 1), 4)
    }

    private init() {
        JobManager.shared.onStreamSegment = { [weak self] _, segment in
            self?.received(segment.text)
        }
    }

    /// Emite un segmento de texto en vivo para subtítulos en pantalla (Nemotron streaming).
    func emitLiveSegment(_ sentence: String) {
        received(sentence)
    }

    /// Texto en vivo (Nemotron): se muestra al momento y se va sustituyendo; sin el retraso de los
    /// subtítulos de una transcripción en curso, que haría llegar las frases tarde y a trompicones.
    func showLive(_ text: String) {
        guard isEnabled, !text.isEmpty else { return }
        show(text)
    }

    private func received(_ sentence: String) {
        guard isEnabled else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(self.delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self.show(sentence)
        }
        pending.append(task)
        if pending.count > 20 { pending.removeFirst() }
    }

    private func show(_ sentence: String) {
        ensurePanel()
        withAnimation(.easeOut(duration: 0.12)) { text = sentence }
        if !visible {
            panel?.orderFrontRegardless()
            withAnimation(.easeOut(duration: 0.2)) { visible = true }
        }
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled, let self else { return }
            withAnimation(.easeOut(duration: 0.2)) { self.visible = false }
            try? await Task.sleep(nanoseconds: 220_000_000)
            if !self.visible { self.panel?.orderOut(nil) }
        }
    }

    func hideNow() {
        pending.forEach { $0.cancel() }
        pending.removeAll()
        hideTask?.cancel()
        visible = false
        panel?.orderOut(nil)
    }

    private func ensurePanel() {
        guard panel == nil, let screen = NSScreen.main else { return }
        let width = min(screen.frame.width * 0.7, 900)
        let size = NSSize(width: width, height: 2 * 28 + 28)
        let panel = NonActivatingPanel(size: size, ignoresMouse: true, title: "")
        panel.setAccessibilityElement(false)
        let host = NSHostingView(rootView: LiveCaptionCapsule().environmentObject(self))
        host.frame = NSRect(origin: .zero, size: size)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        // Centred, 120 pt above the bottom edge of the main screen.
        panel.setFrameOrigin(NSPoint(x: screen.frame.midX - width / 2, y: screen.frame.minY + 120))
        self.panel = panel
    }
}

struct LiveCaptionCapsule: View {
    @EnvironmentObject var center: LiveCaptionCenter
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            if center.visible, !center.text.isEmpty {
                CaptionText(text: center.text, reduceTransparency: reduceTransparency)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityHidden(true)
    }
}

/// Shared look of the caption capsule (also used by the static sample in Ajustes).
struct CaptionText: View {
    let text: String
    var reduceTransparency = false

    var body: some View {
        Text(text)
            .font(.system(size: 22, weight: .semibold))
            .lineSpacing(6)
            .foregroundStyle(Color(nsColor: TX.Palette.paper))
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .truncationMode(.head)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: TX.Radius.caption, style: .continuous)
                    .fill(Color(nsColor: TX.Palette.hud).opacity(reduceTransparency ? 1 : 0.82))
            )
    }
}
