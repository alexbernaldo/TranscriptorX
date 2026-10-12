import SwiftUI
import Sparkle

// MARK: - #19 — Sparkle: actualizaciones propias (appcast autoalojado, sin telemetría)
@MainActor
final class UpdaterModel: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let shared = UpdaterModel()

    @Published private(set) var isChecking = false
    @Published private(set) var availableVersion: String?
    @Published private(set) var lastError: String?
    @Published private(set) var lastCheck: Date?

    // Comprobación automática semanal silenciosa (decisión registrada en el plan);
    // el menú Ayuda fuerza una comprobación manual.
    private(set) lazy var controller = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: self,
        userDriverDelegate: nil
    )

    private override init() {
        super.init()
        _ = controller
        lastCheck = controller.updater.lastUpdateCheckDate
    }

    /// Sparkle quits the app to install: that quit is wanted.
    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        MainActor.assumeIsolated { QuitIntent.userAsked = true }
    }

    func checkForUpdates() {
        isChecking = true
        lastError = nil
        controller.checkForUpdates(nil)
    }

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        Task { @MainActor in self.availableVersion = version }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        Task { @MainActor in self.availableVersion = nil }
    }

    nonisolated func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        Task { @MainActor in
            self.isChecking = false
            self.lastCheck = self.controller.updater.lastUpdateCheckDate
            if let error = error as NSError?, error.domain == SUSparkleErrorDomain, error.code != Int(SUError.noUpdateError.rawValue) {
                self.lastError = error.localizedDescription
            }
        }
    }
}

/// Unit tests run inside the app as their host. Under XCTest the app does not start
/// (no database, recovery, queue or windows), so tests never touch the user's data.
@main
enum AppLauncher {
    static func main() {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            let app = NSApplication.shared
            app.setActivationPolicy(.prohibited)
            app.run()
        } else {
            TranscriptorApp.main()
        }
    }
}

struct TranscriptorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var localizationManager = LocalizationManager()
    @StateObject private var workspace = WorkspaceState.shared

    // Menú de barra (#10)
    @AppStorage("showMenuBarExtra") var showMenuBarExtra = true

    var body: some Scene {
        // One window (spec 4): 1280 × 820 initial, 720 × 520 minimum.
        Window("Transcriptor X", id: WindowCoordinator.mainWindowID) {
            MainWindowView()
                .id(localizationManager.appLanguage.rawValue)
                .environmentObject(workspace)
                .environmentObject(localizationManager)
                .environment(\.locale, localizationManager.locale)
                .tint(TX.Colors.purpleX)
        }
        .defaultSize(width: TX.Window.initial.width, height: TX.Window.initial.height)
        .windowToolbarStyle(.unified)
        .commands {
            SidebarCommands()
            AppCommands(exportDiagnostics: exportDiagnostics)
        }

        // Menú de barra (#10): native menu (spec 6.25).
        MenuBarExtra(isInserted: $showMenuBarExtra) {
            MenuBarMenu()
                .environmentObject(localizationManager)
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
                .environmentObject(localizationManager)
                .environment(\.locale, localizationManager.locale)
                .tint(TX.Colors.purpleX)
        }
    }

    private func exportDiagnostics() {
        guard let logURL = AppLogger.shared.exportLogsToFile() else { return }

        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.plainText]
        savePanel.nameFieldStringValue = localizationManager.appLanguage == .es
            ? "transcriptor_diagnosticos.txt"
            : "transcriptor_diagnostics.txt"

        if savePanel.runModal() == .OK, let destURL = savePanel.url {
            try? FileManager.default.copyItem(at: logURL, to: destURL)
            try? FileManager.default.removeItem(at: logURL)
            NSWorkspace.shared.activateFileViewerSelecting([destURL])
        }
    }
}
