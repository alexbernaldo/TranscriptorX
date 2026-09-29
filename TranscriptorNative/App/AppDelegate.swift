import SwiftUI
import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    
    // Recovery check state
    @Published var recoveredItems: [RecoveryManager.RecoveredItem] = []
    @Published var hasRecoveredItems = false
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Respect system appearance (light/dark) — cinema views override locally
        
        // Initialize logging
        AppLogger.shared.log("Application launched", category: .app)
        
        // Check for recoverable items from previous crash
        Task {
            let items = await RecoveryManager.shared.checkForRecoverableItems()
            await MainActor.run {
                self.recoveredItems = items
                self.hasRecoveredItems = !items.isEmpty
                
                if !items.isEmpty {
                    AppLogger.shared.log("Found recovered items", category: .recovery, metadata: [
                        "count": "\(items.count)"
                    ])
                    self.showRecoveryNotification(count: items.count)
                }
            }
        }
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        AppLogger.shared.log("Application terminating", category: .app)
    }
    
    func applicationDidResignActive(_ notification: Notification) {
        AppLogger.shared.log("Application went to background", category: .app)
    }
    
    func applicationDidBecomeActive(_ notification: Notification) {
        AppLogger.shared.log("Application became active", category: .app)
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
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
