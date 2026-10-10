import AppKit
import SwiftUI

/// #13 — Overlay compacto de dictación: cápsula "Escuchando…" abajo-derecha.
/// NSPanel no-activante; se muestra mientras dura la grabación del micrófono.
@MainActor
final class DictationOverlayController {
    static let shared = DictationOverlayController()
    private var panel: NSPanel?

    func show() {
        if panel == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 220, height: 64),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isFloatingPanel = true
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hidesOnDeactivate = false
            panel.isMovableByWindowBackground = true
            let host = NSHostingView(rootView: DictationOverlay())
            host.frame = panel.contentView!.bounds
            host.autoresizingMask = [.width, .height]
            panel.contentView = host
            self.panel = panel
        }
        position(panel!)
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let frame = panel.frame
        panel.setFrameOrigin(NSPoint(
            x: screen.visibleFrame.maxX - frame.width - 40,
            y: screen.visibleFrame.minY + 40
        ))
    }
}
