import SwiftUI
import AppKit

/// cubic-bezier(x1, y1, x2, y2) evaluated at time fraction t (for the keyed timeline of spec 9.2).
struct CubicBezier {
    let x1, y1, x2, y2: Double

    func callAsFunction(_ t: Double) -> Double {
        let t = min(max(t, 0), 1)
        // Solve x(u) = t with Newton steps, then return y(u).
        var u = t
        for _ in 0..<8 {
            let x = bez(u, x1, x2) - t
            let dx = dbez(u, x1, x2)
            if abs(x) < 1e-5 || dx == 0 { break }
            u -= x / dx
            u = min(max(u, 0), 1)
        }
        return bez(u, y1, y2)
    }

    private func bez(_ u: Double, _ a: Double, _ b: Double) -> Double {
        let iu = 1 - u
        return 3 * iu * iu * u * a + 3 * iu * u * u * b + u * u * u
    }
    private func dbez(_ u: Double, _ a: Double, _ b: Double) -> Double {
        let iu = 1 - u
        return 3 * iu * iu * a + 6 * iu * u * (b - a) + 3 * u * u * (1 - b)
    }

    static let enter = CubicBezier(x1: 0.2, y1: 0.8, x2: 0.2, y2: 1)
    static let draw = CubicBezier(x1: 0.3, y1: 0, x2: 0.1, y2: 1)
    static let travel = CubicBezier(x1: 0.4, y1: 0, x2: 0.2, y2: 1)
    static let exit = CubicBezier(x1: 0.4, y1: 0, x2: 1, y2: 1)
}

/// Progress of a segment [start, end] (ms) of the timeline at `ms`, eased.
func timelineProgress(_ ms: Double, _ start: Double, _ end: Double, _ curve: CubicBezier) -> CGFloat {
    CGFloat(curve((ms - start) / (end - start)))
}

/// Drives the opening (spec 9): the window is usable from millisecond 0 because the layer
/// never intercepts events; any interaction jumps to the final state with a 120 ms fade.
@MainActor
final class OpeningAnimator: ObservableObject {
    static let shared = OpeningAnimator()

    @Published private(set) var start = Date()
    @Published private(set) var skipped = false
    @Published var contentVisible = true
    private var monitor: Any?
    private var finishTask: Task<Void, Never>?
    private var launchedAt = Date()

    /// Only the first window of a launch animates (reopening uses the standard window animation).
    private var hasRun = false

    func runIfNeeded(workspace: WorkspaceState, reduceMotion: Bool) {
        // A window opened long after launch (tx, Shortcuts, watched folder, login item) opens without animation.
        guard !hasRun, Date().timeIntervalSince(launchedAt) < 4 else { return }
        hasRun = true
        start = Date()
        skipped = false
        contentVisible = false
        workspace.openingAnimationActive = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown, .scrollWheel]) { [weak self] event in
            self?.skip(workspace)
            return event
        }
        let reveal: Double = reduceMotion ? 0.40 : 0.68
        Task {
            try? await Task.sleep(nanoseconds: UInt64(reveal * 1_000_000_000))
            guard !skipped else { return }
            withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.22)) {
                contentVisible = true
            }
        }
        finishTask = Task {
            try? await Task.sleep(nanoseconds: UInt64((reduceMotion ? 0.55 : 0.9) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            // Restoration still in progress: hold until the document is ready (spec 9.3).
            while LibraryStore.shared.state != .ready, !skipped {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            finish(workspace, delay: LibraryStore.shared.state == .ready ? 0 : 0.28)
        }
    }

    var isHolding: Bool { LibraryStore.shared.state != .ready && Date().timeIntervalSince(start) > 0.9 }

    func skip(_ workspace: WorkspaceState) {
        guard workspace.openingAnimationActive, !skipped else { return }
        skipped = true
        withAnimation(.easeOut(duration: 0.12)) {
            contentVisible = true
            workspace.openingAnimationActive = false
        }
        cleanup()
    }

    private func finish(_ workspace: WorkspaceState, delay: Double) {
        withAnimation(.easeOut(duration: max(delay, 0.01))) {
            contentVisible = true
            workspace.openingAnimationActive = false
        }
        cleanup()
    }

    private func cleanup() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        finishTask?.cancel()
    }
}

/// The animated symbol layer over the work area (no hit testing, hidden from accessibility).
struct OpeningAnimationLayer: View {
    /// Where the import-zone symbol sits (Inicio); nil when a document is restored.
    var target: CGRect?
    var documentTitle: String?
    @ObservedObject private var animator = OpeningAnimator.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation) { context in
                let ms = context.date.timeIntervalSince(animator.start) * 1000
                let center = CGPoint(x: geo.size.width / 2, y: geo.size.height * 0.40)
                ZStack {
                    TX.Colors.bgWindow.opacity(animator.contentVisible ? 0 : 1)
                    if reduceMotion {
                        reducedSymbol(ms: ms, center: center)
                    } else {
                        animatedSymbol(ms: ms, center: center)
                    }
                    if animator.isHolding, let documentTitle {
                        Text(TXL.f("opening.restoring", "Abriendo %@…", documentTitle))
                            .font(.system(size: 12))
                            .foregroundStyle(TX.Colors.textSecondary)
                            .position(x: center.x, y: center.y + 60)
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // 0–160 dot · 80–240 fragment · 160–420 continuous B · 240–500 stroke A · 500–620 pause · 620–900 exit/travel.
    @ViewBuilder private func animatedSymbol(ms: Double, center: CGPoint) -> some View {
        let dot = timelineProgress(ms, 0, 160, .enter)
        let frag = timelineProgress(ms, 80, 240, .enter)
        let bLine = timelineProgress(ms, 160, 420, .draw)
        let aLine = timelineProgress(ms, 240, 500, .draw)
        let holding = animator.isHolding
        let travel: CGFloat = holding ? 0 : (target != nil ? timelineProgress(ms, 620, 900, .travel) : 0)
        let fade: CGFloat = holding ? 0 : (target == nil ? timelineProgress(ms, 620, 900, .exit) : 0)
        let destination = target.map { CGPoint(x: $0.midX, y: $0.midY) } ?? center
        let size = 72 + (40 - 72) * travel
        let position = CGPoint(x: center.x + (destination.x - center.x) * travel,
                               y: center.y + (destination.y - center.y) * travel)
        ZStack {
            CruceSymbol(style: .brandOnDark, reduced: false,
                        dotProgress: dot, fragmentProgress: frag, continuousProgress: bLine, strokeAProgress: aLine)
                .opacity(1 - travel)
            CruceSymbol(style: .mono(TX.Colors.textTertiary), reduced: false)
                .opacity(travel)
        }
        .frame(width: size, height: size)
        .scaleEffect(1 - 0.08 * fade)
        .opacity(1 - fade)
        .position(position)
    }

    /// Reduce Motion: complete symbol fades in 150 ms, holds 250 ms, fades with the content in 150 ms.
    /// In Inicio the zone symbol simply appears in place.
    @ViewBuilder private func reducedSymbol(ms: Double, center: CGPoint) -> some View {
        if target == nil {
            let opacity = ms < 150 ? ms / 150 : (ms < 400 ? 1 : max(0, 1 - (ms - 400) / 150))
            CruceSymbol(style: .brandOnDark)
                .frame(width: 72, height: 72)
                .opacity(opacity)
                .position(center)
        }
    }
}

/// First launch variant (spec 9.4): 1400 ms, fragments offset by 140 ms, 400 ms strokes, stays at 64 pt.
struct WelcomeSymbol: View {
    @State private var start = Date()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let ms = reduceMotion ? 10_000 : context.date.timeIntervalSince(start) * 1000
            CruceSymbol(style: .brand, reduced: false,
                        dotProgress: timelineProgress(ms, 0, 200, .enter),
                        fragmentProgress: timelineProgress(ms, 140, 340, .enter),
                        continuousProgress: timelineProgress(ms, 280, 680, .draw),
                        strokeAProgress: timelineProgress(ms, 420, 820, .draw))
        }
        .frame(width: 64, height: 64)
        .onAppear { start = Date() }
        .accessibilityHidden(true)
    }
}
