import SwiftUI

@main
struct TranscriptorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var dependencyManager = DependencyManager()
    @StateObject private var transcriptionVM = TranscriptionViewModel()
    @StateObject private var modelManager = ModelManager.shared
    @StateObject private var localizationManager = LocalizationManager()
    
    // Dependency check state - passed to MasterView via ContentView
    @State private var dependencyCheckComplete = false
    
    var body: some Scene {
        WindowGroup {
            GeometryReader { geometry in
                let metrics = ResponsiveMetrics(size: geometry.size)
                
                // Single unified view - MasterView handles splash internally
                Group {
                    if dependencyManager.isReady || !dependencyCheckComplete {
                        // Main app - ContentView contains MasterView with integrated splash
                        ContentView(dependencyCheckComplete: $dependencyCheckComplete)
                            .environmentObject(transcriptionVM)
                            .environmentObject(dependencyManager)
                            .environmentObject(modelManager)
                    } else {
                        // Setup view - need to install dependencies
                        SetupView()
                            .environmentObject(dependencyManager)
                    }
                }
                .id(localizationManager.appLanguage.rawValue)
                .environmentObject(localizationManager)
                .environment(\.locale, localizationManager.locale)
                .environment(\.responsiveMetrics, metrics)
            }
            .frame(minWidth: 900, minHeight: 600)
            .task {
                // Start dependency check immediately when app launches
                print("🚀 [App] Starting dependency check...")
                await dependencyManager.checkAll()
                print("🚀 [App] Dependency check complete! isReady: \(dependencyManager.isReady)")
                dependencyCheckComplete = true
                print("🚀 [App] Set dependencyCheckComplete = true")
            }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(localizationManager.text("menu.newTranscription", fallback: "Nueva transcripción")) {
                    NotificationCenter.default.post(name: .showNewTranscription, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)
                
                Button(localizationManager.text("menu.openAudioFile", fallback: "Abrir archivo de audio...")) {
                    transcriptionVM.openFilePicker()
                }
                .keyboardShortcut("o", modifiers: .command)
                
                Divider()
                
                Button(localizationManager.text("menu.recordAudio", fallback: "Grabar audio")) {
                    NotificationCenter.default.post(name: .showRecorder, object: nil)
                }
                .keyboardShortcut("r", modifiers: .command)
            }
            
            CommandGroup(after: .pasteboard) {
                Divider()
                Button(localizationManager.text("menu.copyTranscription", fallback: "Copiar transcripción")) {
                    transcriptionVM.copyTranscription()
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(transcriptionVM.transcriptionText.isEmpty)
            }

            CommandMenu(localizationManager.text("menu.segment", fallback: "Segment")) {
                Button(localizationManager.text("menu.segmentUndoLastEdit", fallback: "Undo Last Segment Edit")) {
                    transcriptionVM.undoLastSegmentEditOnActiveSegment()
                }
                .keyboardShortcut("z", modifiers: [.command, .option])
                .disabled(!transcriptionVM.canUndoLastSegmentEdit)

                Button(localizationManager.text("menu.segmentRestoreOriginal", fallback: "Restore Segment Original Text")) {
                    transcriptionVM.restoreOriginalTextOnActiveSegment()
                }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(!transcriptionVM.canRestoreOriginalSegmentText)
            }
            
            // Help menu with diagnostics
            CommandGroup(replacing: .help) {
                Button(localizationManager.text("menu.exportDiagnostics", fallback: "Exportar diagnósticos...")) {
                    exportDiagnostics()
                }
                
                Divider()
                
                Button(localizationManager.text("menu.releaseModelMemory", fallback: "Liberar memoria del modelo")) {
                    Task {
                        await modelManager.unloadModelNow()
                    }
                }
                .disabled(!modelManager.state.isReady)
                
                Divider()
                
                if modelManager.state.isReady, let modelId = modelManager.currentModelId {
                    Text(String(format: localizationManager.text("menu.loadedModel", fallback: "Modelo cargado: %@"), modelId))
                        .font(.caption)
                    Text(String(format: localizationManager.text("menu.modelRam", fallback: "RAM: ~%d MB"), Int(modelManager.memoryUsageMB)))
                        .font(.caption)
                    Divider()
                }
                
                Button(localizationManager.text("menu.help", fallback: "Ayuda de Transcriptor")) {
                    if let url = URL(string: "https://github.com/alexbernaldo/TranscriptorX#readme") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
        
        Settings {
            PreferencesSheet()
                .environmentObject(transcriptionVM)
                .environmentObject(localizationManager)
                .environment(\.locale, localizationManager.locale)
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
            
            // Show in Finder
            NSWorkspace.shared.activateFileViewerSelecting([destURL])
        }
    }
}
