import SwiftUI

struct ContentView: View {
    @EnvironmentObject var transcriptionVM: TranscriptionViewModel
    
    // Binding from App level for splash coordination
    @Binding var dependencyCheckComplete: Bool
    
    @State private var modelDownloadInfo: ModelDownloadInfo?
    @State private var showingRecorder = false
    @State private var showingNewTranscription = false
    @State private var showingRecoveryBanner = false
    @State private var showingRecoverySheet = false
    @State private var recoveredItems: [RecoveryManager.RecoveredItem] = []
    @State private var selectedTab: TopBarView.AppTab = .home
    @State private var showingSettings = false
    @State private var showLibraryDrawer = false
    @State private var showSettingsSheet = false
    @State private var showQueuePanel = false
    @State private var hasPlayedHomeOpeningAnimation = false
    @StateObject private var jobManager = JobManager.shared

    private var shouldShowHomeView: Bool {
        transcriptionVM.transcriptionResult == nil &&
        (!transcriptionVM.isTranscribing || transcriptionVM.isMinimizedToBackground)
    }

    private var homeTransition: AnyTransition {
        .asymmetric(
            insertion: .modifier(
                active: BlurScaleModifier(blur: 12, scale: 0.96, opacity: 0),
                identity: BlurScaleModifier(blur: 0, scale: 1, opacity: 1)
            ),
            removal: .modifier(
                active: BlurScaleModifier(blur: 8, scale: 1.03, opacity: 0),
                identity: BlurScaleModifier(blur: 0, scale: 1, opacity: 1)
            )
        )
    }

    private var transcriptionTransition: AnyTransition {
        .asymmetric(
            insertion: .modifier(
                active: BlurScaleModifier(blur: 12, scale: 1.04, opacity: 0),
                identity: BlurScaleModifier(blur: 0, scale: 1, opacity: 1)
            ),
            removal: .modifier(
                active: BlurScaleModifier(blur: 14, scale: 0.94, opacity: 0),
                identity: BlurScaleModifier(blur: 0, scale: 1, opacity: 1)
            )
        )
    }
    
    var body: some View {
        GeometryReader { geometry in
            let metrics = ResponsiveMetrics(size: geometry.size)
            ZStack {
                // Background
                Color.bgPrimary
                    .ignoresSafeArea()
                
                // Main Content - MasterView now contains TopBar internally
                ZStack {
                    if shouldShowHomeView {
                        MasterView(
                            showingRecorder: $showingRecorder,
                            showingNewTranscription: $showingNewTranscription,
                            dependencyCheckComplete: $dependencyCheckComplete,
                            hasPlayedHomeOpeningAnimation: $hasPlayedHomeOpeningAnimation,
                            showLibraryDrawer: $showLibraryDrawer,
                            showSettingsSheet: $showSettingsSheet,
                            showQueuePanel: $showQueuePanel
                        )
                        .transition(homeTransition)
                        .zIndex(shouldShowHomeView ? 1 : 0)
                    }

                    if !shouldShowHomeView {
                        HStack(spacing: 0) {
                            VStack(spacing: 0) {
                                // TopBar for TranscriptViewer
                                TopBarView(
                                    selectedTab: $selectedTab,
                                    showLibraryDrawer: $showLibraryDrawer,
                                    showSettingsSheet: $showSettingsSheet,
                                    showQueuePanel: $showQueuePanel
                                )
                                TranscriptViewer()
                            }
                            
                            if showQueuePanel {
                                JobQueuePanel(
                                    jobManager: jobManager,
                                    isPresented: $showQueuePanel
                                ) { job in
                                    transcriptionVM.openTranscriptionJob(job)
                                    withAnimation(.snappy(duration: 0.2)) {
                                        showQueuePanel = false
                                    }
                                }
                                .transition(.move(edge: .trailing).combined(with: .opacity))
                            }
                        }
                        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: showQueuePanel)
                        .transition(transcriptionTransition)
                        .zIndex(shouldShowHomeView ? 0 : 1)
                    }
                }
                .animation(.spring(response: 0.55, dampingFraction: 0.88), value: shouldShowHomeView)
                
                // Library Drawer Overlay
                if showLibraryDrawer {
                    Color.black.opacity(0.3)
                        .ignoresSafeArea()
                        .onTapGesture {
                            withAnimation(.snappy(duration: 0.2)) {
                                showLibraryDrawer = false
                            }
                        }
                        .transition(.opacity)
                }
                
                // Library Drawer (from right)
                HStack {
                    Spacer()
                    
                    if showLibraryDrawer {
                        LibraryDrawerView(isPresented: $showLibraryDrawer)
                            .frame(maxHeight: .infinity)
                            .padding(.vertical, metrics.sectionPadding)
                            .padding(.trailing, 16)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .animation(.snappy(duration: 0.25), value: showLibraryDrawer)
            }
            .environment(\.responsiveMetrics, metrics)
            // Recovery Banner (top)
            .overlay(alignment: .top) {
                if showingRecoveryBanner && !recoveredItems.isEmpty {
                    RecoveryBanner(
                        items: recoveredItems,
                        onDismiss: {
                            withAnimation(.snappy) {
                                showingRecoveryBanner = false
                            }
                        },
                        onViewItems: {
                            showingRecoveryBanner = false
                            showingRecoverySheet = true
                        }
                    )
                    .padding(.top, metrics.sectionPadding)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            // Toast overlay (bottom)
            .overlay(alignment: .bottom) {
                ToastOverlay()
                    .padding(.bottom, metrics.dockBottomPadding) // Above dock
            }
            // Floating Recording Panel
            .overlay {
                if showingRecorder {
                    ZStack {
                        Color.black.opacity(0.4)
                            .ignoresSafeArea()
                            .onTapGesture {
                                withAnimation(.snappy(duration: 0.2)) {
                                    showingRecorder = false
                                }
                            }
                        
                        RecordingFloatingPanel(isPresented: $showingRecorder)
                            .transition(.asymmetric(
                                insertion: .scale(scale: 0.9).combined(with: .opacity),
                                removal: .scale(scale: 0.95).combined(with: .opacity)
                            ))
                    }
                    .animation(.snappy(duration: 0.25), value: showingRecorder)
                }
            }
            // Recovery Manager Sheet
            .sheet(isPresented: $showingRecoverySheet) {
                RecoveryManagerView()
            }
            // Settings/Preferences Sheet
            .sheet(isPresented: $showSettingsSheet) {
                PreferencesSheet()
            }
            // New Transcription Sheet
            .sheet(isPresented: $showingNewTranscription) {
                NewTranscriptionSheet()
            }
            // Model Download Sheet
            .sheet(item: $modelDownloadInfo) { info in
                ModelDownloadSheet(
                    modelId: info.modelId,
                    modelName: info.modelName,
                    onComplete: {
                        modelDownloadInfo = nil
                        transcriptionVM.startTranscription()
                    },
                    onCancel: {
                        modelDownloadInfo = nil
                    }
                )
            }
            .onReceive(NotificationCenter.default.publisher(for: .needsModelDownload)) { notification in
                if let userInfo = notification.userInfo,
                   let modelId = userInfo["modelId"] as? String,
                   let modelName = userInfo["modelName"] as? String {
                    modelDownloadInfo = ModelDownloadInfo(modelId: modelId, modelName: modelName)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .openNewTranscriptionWithFile)) { notification in
                if let userInfo = notification.userInfo,
                   let fileURL = userInfo["fileURL"] as? URL {
                    transcriptionVM.selectedFileURL = fileURL
                    showingNewTranscription = true
                }
            }
            // Listen for recovered items notification
            .onReceive(NotificationCenter.default.publisher(for: .recoveredItemsFound)) { notification in
                if let items = notification.userInfo?["items"] as? [RecoveryManager.RecoveredItem] {
                    recoveredItems = items
                    withAnimation(.snappy.delay(0.5)) {
                        showingRecoveryBanner = true
                    }
                }
            }
            // Menu keyboard shortcuts: ⌘N → new transcription, ⌘R → record
            .onReceive(NotificationCenter.default.publisher(for: .showNewTranscription)) { _ in
                showingNewTranscription = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .showRecorder)) { _ in
                showingRecorder = true
            }
        }
    }
}



// MARK: - Blur + Scale Morph Modifier
/// Custom ViewModifier used for depth-of-field morph transitions between views.
struct BlurScaleModifier: ViewModifier {
    let blur: CGFloat
    let scale: CGFloat
    let opacity: Double
    
    func body(content: Content) -> some View {
        content
            .blur(radius: blur)
            .scaleEffect(scale)
            .opacity(opacity)
    }
}

// MARK: - Model Download Info
struct ModelDownloadInfo: Identifiable {
    let id = UUID()
    let modelId: String
    let modelName: String
}

// MARK: - Notification for model download
extension Notification.Name {
    static let needsModelDownload = Notification.Name("needsModelDownload")
    static let openNewTranscriptionWithFile = Notification.Name("openNewTranscriptionWithFile")
    static let showNewTranscription = Notification.Name("showNewTranscription")
    static let showRecorder = Notification.Name("showRecorder")
}

#if DEBUG
struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView(dependencyCheckComplete: .constant(true))
            .environmentObject(TranscriptionViewModel())
            .environmentObject(LocalizationManager())
            .frame(width: 1200, height: 800)
    }
}
#endif
