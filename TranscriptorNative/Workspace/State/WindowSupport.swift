import SwiftUI
import AppKit

/// Shows and finds the main window without stealing focus from other apps unless the user asked.
@MainActor
enum WindowCoordinator {
    static let mainWindowID = "main"
    /// Captured from a view in the main scene (`openWindow` is only available in the view tree).
    static var openMainWindowAction: (() -> Void)?

    static var mainWindow: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix(mainWindowID) == true && $0.canBecomeMain }
            ?? NSApp.windows.first { $0.title == "Transcriptor X" && $0.canBecomeMain }
    }

    /// Brings the main window back (Dock, menu bar, transcriptorx://open). Called from explicit user actions.
    static func showMainWindow() {
        if let window = mainWindow {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            openMainWindowAction?()
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    static var isMainWindowFrontmost: Bool {
        guard let w = mainWindow else { return false }
        return w.isVisible && w.isKeyWindow && NSApp.isActive
    }
}

/// VoiceOver announcements that never move focus (spec 10.2).
enum AccessibilityAnnouncer {
    static func announce(_ text: String, highPriority: Bool = false) {
        guard !text.isEmpty else { return }
        let element = NSApp.mainWindow ?? NSApp.windows.first as Any
        NSAccessibility.post(element: element, notification: .announcementRequested, userInfo: [
            .announcement: text,
            .priority: (highPriority ? NSAccessibilityPriorityLevel.high : .medium).rawValue
        ])
    }
}

/// Requests that a view gives focus to a document's first segment once it appears.
@MainActor
final class DocumentFocus: ObservableObject {
    static let shared = DocumentFocus()
    @Published var pendingFocusFirstSegment: UUID?
}

/// Native alerts for .transcriptor projects (spec 6.15).
@MainActor
enum ProjectAlerts {
    static func showDamaged(url: URL, error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = TXL.f("project.damaged.title", "No se puede abrir «%@».", url.lastPathComponent)
        alert.informativeText = TXL.t("project.damaged.message", "El archivo está dañado o incompleto.")
        alert.addButton(withTitle: TXL.t("common.ok", "Aceptar"))
        alert.addButton(withTitle: TXL.t("common.showInFinder", "Mostrar en Finder"))
        let details = NSTextView(frame: NSRect(x: 0, y: 0, width: 360, height: 60))
        details.string = error.localizedDescription
        details.isEditable = false
        details.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        details.drawsBackground = false
        let disclosure = NSScrollView(frame: details.frame)
        disclosure.documentView = details
        disclosure.hasVerticalScroller = true
        alert.accessoryView = disclosure
        alert.showsHelp = false
        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}
