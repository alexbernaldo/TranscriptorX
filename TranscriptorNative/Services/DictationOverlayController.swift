import AppKit
import SwiftUI

/// #13 — Dictation capsule (spec 6.23): non-activating, never takes focus or the keyboard.
/// Centred on the screen in use, 80 pt above the bottom or just under the menu bar
/// (Ajustes › Dictado › Indicador). The panel is wide enough for the longest message; the
/// pill inside sits flush with the chosen edge and changes width on its own.
@MainActor
final class DictationOverlayController {
    static let shared = DictationOverlayController()
    private var panel: NonActivatingPanel?
    private var host: NSHostingView<DictationOverlay>?
    private var hiding = false
    static let size = NSSize(width: 420, height: 52)

    func show() {
        // «Oculto» in Ajustes › Dictado: only the permission problems still appear,
        // because without them the user would not know why nothing was pasted.
        if DictationPreferences.overlay == .hidden {
            switch DictationManager.shared.phase {
            case .noAccessibility, .noMicrophone, .unavailable: break
            default: hide(); return
            }
        }
        if panel == nil {
            let panel = NonActivatingPanel(size: Self.size, title: "")
            panel.setAccessibilityElement(false)
            let host = NSHostingView(rootView: DictationOverlay())
            host.frame = NSRect(origin: .zero, size: Self.size)
            host.autoresizingMask = [.width, .height]
            panel.contentView = host
            self.panel = panel
            self.host = host
        }
        guard let panel else { return }
        position(panel)
        if !panel.isVisible || hiding {
            hiding = false
            // A fresh view each time so the pop-in plays again.
            host?.rootView = DictationOverlay()
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        }
    }

    /// Fades out in 200 ms, like Handy's pill.
    func hide() {
        guard let panel, panel.isVisible, !hiding else { return }
        hiding = true
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.hiding else { return }
                self.hiding = false
                panel.orderOut(nil)
                panel.alphaValue = 1
            }
        }
    }

    /// The screen of the app in use: the one under the pointer (the active app's window is not visible to us).
    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let screen else { return }
        let y = DictationPreferences.overlay == .top
            ? screen.visibleFrame.maxY - 10 - Self.size.height
            : screen.frame.minY + 80
        panel.setFrameOrigin(NSPoint(x: screen.frame.midX - Self.size.width / 2, y: y))
    }
}
