import AppKit
import SwiftUI

/// #11 — Overlay de subtítulos en pantalla.
/// NSPanel borderless no-activante, por encima de las apps de vídeo,
/// centrado abajo sobre todo espacio; el texto lo alimenta el ViewModel
/// vía `LiveCaptionView` (lectura reactiva de `liveCaptionText`).
@MainActor
final class LiveCaptionOverlayController {
    static let shared = LiveCaptionOverlayController()
    private var panel: NSPanel?

    func show(viewModel: TranscriptionViewModel) {
        if panel == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 720, height: 90),
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
            let host = NSHostingView(rootView: LiveCaptionView().environmentObject(viewModel))
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
            x: screen.visibleFrame.midX - frame.width / 2,
            y: screen.visibleFrame.minY + 40
        ))
    }
}
