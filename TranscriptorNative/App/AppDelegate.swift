import SwiftUI
import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    
    // Recovery check state
    @Published var recoveredItems: [RecoveryManager.RecoveredItem] = []
    @Published var hasRecoveredItems = false
    static var recoveredItemsForUI: [RecoveryManager.RecoveredItem] = []
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Respect system appearance (light/dark) — cinema views override locally
        
        // Claves de la app con defaults (#10): menú de barra + segundo plano
        UserDefaults.standard.register(defaults: [
            "showMenuBarExtra": true,
            "keepRunningInBackground": true,
            "liveCaptionEnabled": false   // #11 — subtítulos en pantalla, off por defecto
        ])
        
        // Initialize logging
        AppLogger.shared.log("Application launched", category: .app)
        
        // Check for recoverable items from previous crash
        Task {
            let items = await RecoveryManager.shared.checkForRecoverableItems()
            await MainActor.run {
                self.recoveredItems = items
                AppDelegate.recoveredItemsForUI = items
                self.hasRecoveredItems = !items.isEmpty
                
                if !items.isEmpty {
                    AppLogger.shared.log("Found recovered items", category: .recovery, metadata: [
                        "count": "\(items.count)"
                    ])
                    self.showRecoveryNotification(count: items.count)
                }
            }
        }
        
        CLIServer.shared.start()
        
        // Start persistent folder watchers without requiring Preferences to be opened
        _ = WatchedFoldersManager.shared
    }
    
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.pathExtension == ProjectPackage.fileExtension {
            do {
                let (transcription, _) = try ProjectPackage.open(from: url)
                TranscriptionStorage.shared.saveTranscription(transcription)
                // saveTranscription → saveTranscriptions ya postea .transcriptionsDidChange (Storage:66)
                AppLogger.shared.log("Opened project package \(url.lastPathComponent)",
                                     category: .app)
            } catch {
                AppLogger.shared.logError(error, context: "openProject", category: .app)
            }
        }
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        CLIServer.shared.stop()
        AppLogger.shared.log("Application terminating", category: .app)
    }
    
    func applicationDidResignActive(_ notification: Notification) {
        AppLogger.shared.log("Application went to background", category: .app)
    }
    
    func applicationDidBecomeActive(_ notification: Notification) {
        AppLogger.shared.log("Application became active", category: .app)
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // #10: con menú de barra + segundo plano activos, cerrar la ventana
        // no termina la app (registro de defaults en applicationDidFinishLaunching).
        let menubar = UserDefaults.standard.bool(forKey: "showMenuBarExtra")
        let keepRunning = UserDefaults.standard.bool(forKey: "keepRunningInBackground")
        return !(menubar && keepRunning)
    }
    
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // #10 (macOS 27): cerrar la ventana principal o alternar el panel del menú
        // postea un kAEQuit (vía _handleAEQuit) que llega aquí. Con el menú de barra
        // activo y sin ventana principal visible, ese quit automático se cancela;
        // los quits explícitos (Salir con ratón, Cmd+Q con teclado) traen evento de
        // teclado/ratón y pasan. Finder/menú Apple con ventana abierta también pasa
        // (visibleWindow = true).
        let menubar = UserDefaults.standard.bool(forKey: "showMenuBarExtra")
        let keepRunning = UserDefaults.standard.bool(forKey: "keepRunningInBackground")
        let explicitUserAction: Bool
        if let ev = NSApp.currentEvent {
            switch ev.type {
            case .keyDown, .leftMouseDown, .rightMouseDown, .leftMouseUp, .rightMouseUp:
                explicitUserAction = true
            default:
                explicitUserAction = false
            }
        } else {
            explicitUserAction = false
        }
        let visibleNormalWindow = NSApp.windows.contains {
            $0.isVisible && $0.level != .statusBar
        }
        AppLogger.shared.log("applicationShouldTerminate consulted", category: .app, metadata: [
            "menubar": "\(menubar)",
            "keepRunning": "\(keepRunning)",
            "eventType": "\(NSApp.currentEvent.map { String(describing: $0.type) } ?? "nil")",
            "explicit": "\(explicitUserAction)",
            "visibleWindow": "\(visibleNormalWindow)"
        ])
        if menubar && keepRunning && !explicitUserAction && !visibleNormalWindow {
            return .terminateCancel
        }
        return .terminateNow
    }
    
    // MARK: - Recovery Notification
    
    private func showRecoveryNotification(count: Int) {
        // Post notification to show recovery alert in UI
        NotificationCenter.default.post(
            name: .recoveredItemsFound,
            object: nil,
            userInfo: ["count": count, "items": recoveredItems]
        )
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let recoveredItemsFound = Notification.Name("recoveredItemsFound")
}
