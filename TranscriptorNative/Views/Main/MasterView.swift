import SwiftUI
import UniformTypeIdentifiers
import AVFoundation

// MARK: - Master View
/// Vista maestra única que contiene tanto el Splash como el Home.
/// Usa matchedGeometryEffect para una transición orgánica del logo.
struct MasterView: View {
    @EnvironmentObject var viewModel: TranscriptionViewModel
    @EnvironmentObject var localizationManager: LocalizationManager
    @Environment(\.responsiveMetrics) private var metrics
    @Binding var showingRecorder: Bool
    @Binding var showingNewTranscription: Bool
    @Binding var dependencyCheckComplete: Bool
    @Binding var hasPlayedHomeOpeningAnimation: Bool
    
    // Drawer/Sheet bindings from ContentView
    @Binding var showLibraryDrawer: Bool
    @Binding var showSettingsSheet: Bool
    @Binding var showQueuePanel: Bool
    
    // Job Manager for queue-based transcription
    @StateObject private var jobManager = JobManager.shared
    
    // Phase control - the single source of truth
    @State private var isAppReady = false
    
    // TopBar state
    @State private var selectedTab: TopBarView.AppTab = .home
    @State private var showTopBar = false
    
    // URL Input Sheet
    @State private var showingURLInput = false
    
    // Matched geometry for logo morph
    @Namespace private var animation
    
    // Splash timing
    @State private var minimumTimeElapsed = false
    
    // Splash breathing animation
    @State private var breatheScale: CGFloat = 1.0
    
    // Glow animation states
    @State private var glowScale: CGFloat = 1.0
    @State private var glowOpacity: Double = 0.6
    
    // Home elements entrance (staggered)
    @State private var showDropText = false
    @State private var showDropZone = false
    @State private var showDock = false
    @State private var skipHomeEntryAnimation = false
    
    // Drop zone interaction
    @State private var isDropTargeted = false
    
    // Spring configuration - feels native with weight
    private let logoSpring = Animation.spring(response: 0.7, dampingFraction: 0.75, blendDuration: 0)
    private let elementSpring = Animation.spring(response: 0.6, dampingFraction: 0.8)
    
    var body: some View {
        ZStack {
            // Main content
            mainContentArea
            
            // Queue Panel Overlay (dark background - tap to dismiss)
            if showQueuePanel {
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.snappy(duration: 0.2)) {
                            showQueuePanel = false
                        }
                    }
                    .transition(.opacity)
            }
            
            // Queue Panel (floating from right - exactly like LibraryDrawer)
            HStack {
                Spacer()
                
                if showQueuePanel {
                    JobQueuePanel(
                        jobManager: jobManager,
                        isPresented: $showQueuePanel
                    ) { job in
                        viewModel.openTranscriptionJob(job)
                    }
                    .frame(maxHeight: .infinity)
                    .padding(.vertical, metrics.sectionPadding)
                    .padding(.trailing, 16)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(.snappy(duration: 0.25), value: showQueuePanel)
        }
        // URL Input Sheet - must be at root level
        .sheet(isPresented: $showingURLInput) {
            URLInputSheet()
                .environmentObject(viewModel)
        }
    }
    
    // MARK: - Main Content Area
    private var mainContentArea: some View {
        ZStack {
            // MARK: Layer 0 - Persistent Background (never disappears)
            Color.bgPrimary
                .ignoresSafeArea()
            
            // MARK: Layer 1 - Persistent Glow (transforms during transition)
            RadialGradient(
                colors: [
                    Color.accentPrimary.opacity(isAppReady ? 0.15 : 0.5 * glowOpacity),
                    Color.accentSecondary.opacity(isAppReady ? 0.08 : 0.3 * glowOpacity),
                    Color.clear
                ],
                center: .center,
                startRadius: isAppReady ? 50 : 20,
                endRadius: isAppReady ? 400 : 150
            )
            .scaleEffect(isAppReady ? 1.5 : glowScale)
            .blur(radius: isAppReady ? 60 : 40)
            .offset(y: isAppReady ? -50 : 0)
            .animation(skipHomeEntryAnimation ? nil : logoSpring, value: isAppReady)
            
            // MARK: Layer 2 - Main Content with TopBar
            VStack(spacing: 0) {
                // TopBar - only appears when ready (staggered with other elements)
                if isAppReady {
                    TopBarView(
                        selectedTab: $selectedTab,
                        showLibraryDrawer: $showLibraryDrawer,
                        showSettingsSheet: $showSettingsSheet,
                        showQueuePanel: $showQueuePanel
                    )
                    .opacity(showTopBar ? 1 : 0)
                    .offset(y: showTopBar ? 0 : -10)
                }
                
                Spacer(minLength: metrics.isCompactHeight ? 8 : 20)
                
                // Hero area with logo and drop zone
                heroSection
                    .padding(.horizontal, metrics.horizontalPadding)
                
                Spacer(minLength: metrics.isCompactHeight ? 8 : 20)
                
                // Recent section (only when ready)
                if isAppReady && (!viewModel.transcriptions.isEmpty || !viewModel.activeTranscriptions.isEmpty) {
                    recentSection
                        .padding(.bottom, metrics.isCompactHeight ? 96 : metrics.dockBottomPadding)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            
            // MARK: Layer 3 - Bottom Dock (enters from bottom)
            if isAppReady {
                VStack {
                    Spacer()
                    BottomDockView(
                        onRecord: {
                            withAnimation(.snappy) {
                                showingRecorder = true
                            }
                        },
                        onPasteLink: {
                            withAnimation(.snappy) {
                                showingURLInput = true
                            }
                        }
                    )
                    .padding(.bottom, metrics.isCompactHeight ? 18 : 30)
                    .offset(y: showDock ? 0 : 30)
                    .opacity(showDock ? 1 : 0)
                }
                .transition(.opacity)
            }
            
            // Quick transcribe toast removed — drag-and-drop now opens the transcription sheet directly
        }
        .onAppear {
            if hasPlayedHomeOpeningAnimation {
                showHomeImmediately()
            } else {
                startSplashSequence()
            }
        }
        .onChange(of: dependencyCheckComplete) { complete in
            if complete {
                checkReadyToTransition()
            }
        }
    }
    
    
    // MARK: - Hero Section
    private var heroSection: some View {
        VStack(spacing: metrics.isCompactHeight ? 18 : 32) {
            // Logo + Title area
            VStack(spacing: metrics.isCompactHeight ? 10 : 16) {
                // The Logo - uses matchedGeometryEffect for seamless morph
                logoView
                
                // Subtitle (only when ready, fades in from bottom)
                if isAppReady {
                    Text(localizationManager.text("home.subtitle", fallback: "Convierte audio a texto con inteligencia artificial"))
                        .font(.bodyLarge)
                        .foregroundColor(.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .offset(y: showDropText ? 0 : 15)
                        .opacity(showDropText ? 1 : 0)
                        .transition(.opacity)
                }
            }
            
            // Drop Area (only when ready)
            if isAppReady {
                dropArea
                    .offset(y: showDropZone ? 0 : 25)
                    .opacity(showDropZone ? 1 : 0)
                    .transition(.opacity)
            }
        }
    }
    
    // MARK: - Logo View (The Magic!)
    @ViewBuilder
    private var logoView: some View {
        // The logo transforms between two states using matchedGeometryEffect
        Image("Logo")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(height: 72)
            // Scale: larger in splash (1.2x), normal in home (1.0x)
            .scaleEffect(isAppReady ? (isDropTargeted ? 1.05 : 1.0) : 1.2 * breatheScale)
            // matchedGeometryEffect makes SwiftUI interpolate position & size automatically
            .matchedGeometryEffect(id: "logo", in: animation)
            // Subtle drop target feedback in home state
            .animation(.easeInOut(duration: 0.3), value: isDropTargeted)
            // Main transition uses spring physics
            .animation(skipHomeEntryAnimation ? nil : logoSpring, value: isAppReady)
    }
    
    // MARK: - Drop Area
    private var dropArea: some View {
        let isCompact = metrics.isCompactHeight
        let verticalPadding: CGFloat = isCompact ? 22 : 40
        let contentSpacing: CGFloat = isCompact ? 12 : 20
        let iconGlowSize: CGFloat = isCompact ? 86 : 110
        let iconSize: CGFloat = isCompact ? 34 : 44
        let textSpacing: CGFloat = isCompact ? 4 : 6
        let separatorHeight: CGFloat = isCompact ? 8 : 28
        let buttonHorizontalPadding: CGFloat = isCompact ? 18 : 22
        let buttonVerticalPadding: CGFloat = isCompact ? 9 : 11
        
        return ZStack {
            // Background — subtle atmosphere fill, always shows dashed border
            RoundedRectangle(cornerRadius: 24)
                .fill(isDropTargeted ? Color.accentPrimary.opacity(0.08) : Color.accentPrimary.opacity(0.03))
                .overlay(
                    RoundedRectangle(cornerRadius: 24)
                        .strokeBorder(
                            isDropTargeted ? Color.accentPrimary : Color.accentPrimary.opacity(0.22),
                            style: StrokeStyle(
                                lineWidth: isDropTargeted ? 2 : 1.5,
                                dash: isDropTargeted ? [] : [8, 6]
                            )
                        )
                )
                .shadow(
                    color: isDropTargeted ? Color.accentPrimary.opacity(0.30) : Color.accentPrimary.opacity(0.08),
                    radius: isDropTargeted ? 30 : 20
                )

            // Content
            VStack(spacing: contentSpacing) {
                // Icon with ambient brand glow — same atmosphere as Screen 3
                ZStack {
                    RadialGradient(
                        colors: [
                            Color.accentPrimary.opacity(isDropTargeted ? 0.30 : 0.16),
                            Color.clear
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: 52
                    )
                    .frame(width: iconGlowSize, height: iconGlowSize)
                    .blur(radius: 18)

                    Image(systemName: isDropTargeted ? "arrow.down.doc.fill" : "doc.badge.plus")
                        .font(.system(size: iconSize))
                        .foregroundColor(.accentPrimary)
                        .scaleEffect(isDropTargeted ? 1.1 : 1.0)
                        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isDropTargeted)
                }

                VStack(spacing: textSpacing) {
                    Text(
                        isDropTargeted
                            ? localizationManager.text("home.drop.release", fallback: "Suelta para transcribir")
                            : localizationManager.text("home.drop.prompt", fallback: "Arrastra un archivo aquí")
                    )
                        .font(.titleMedium)
                        .foregroundColor(isDropTargeted ? .accentPrimary : .textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.9)

                    Text(localizationManager.text("home.drop.formats", fallback: "MP3, WAV, M4A, MP4, MOV y más"))
                        .font(.bodySmall)
                        .foregroundColor(.textMuted)
                }

                Spacer()
                    .frame(height: separatorHeight)

                Button {
                    openFilePicker()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "folder")
                            .font(.bodyDefault)
                        Text(localizationManager.text("home.selectFile", fallback: "Seleccionar archivo"))
                            .font(.labelLarge)
                    }
                    .padding(.horizontal, buttonHorizontalPadding)
                    .padding(.vertical, buttonVerticalPadding)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.gradientBrand)
                    )
                    .foregroundColor(.white)
                    .shadow(color: Color.accentPrimary.opacity(0.35), radius: 12, y: 4)
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, verticalPadding)
        }
        .frame(maxWidth: metrics.dropAreaMaxWidth, minHeight: metrics.dropAreaMinHeight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(localizationManager.text("home.drop.area", fallback: "File drop area"))
        .accessibilityHint(localizationManager.text("home.drop.accessibilityHint", fallback: "Arrastra un archivo aquí o usa el botón para seleccionar"))
        .onDrop(of: [.audio, .movie, .fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
        .animation(.smooth(duration: 0.2), value: isDropTargeted)
    }
    
    // MARK: - Recent Section
    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(localizationManager.text("home.recent", fallback: "Recientes"))
                    .font(.titleSmall)
                    .foregroundColor(.textSecondary)
                
                Spacer()
                
                Button(localizationManager.text("home.seeAll", fallback: "Ver todo")) {
                    withAnimation(.snappy(duration: 0.25)) {
                        showLibraryDrawer = true
                    }
                }
                .font(.labelMedium)
                .foregroundColor(.accentPrimary)
                .buttonStyle(.plain)
            }
            .padding(.horizontal, metrics.sectionPadding)
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    // Active (in-progress) transcriptions first
                    ForEach(viewModel.activeTranscriptions) { active in
                        ActiveTranscriptionCard(
                            fileName: active.fileName,
                            progress: active.progress,
                            statusMessage: active.statusMessage,
                            streamingText: active.streamingText,
                            onExpand: {
                                viewModel.restoreFromBackground()
                            },
                            onCancel: {
                                viewModel.cancelActiveTranscription(active.id)
                            }
                        )
                        .accessibilityLabel(String(
                            format: localizationManager.text("home.recent.activeTranscription.label", fallback: "Transcribing: %@"),
                            active.fileName
                        ))
                        .accessibilityHint(localizationManager.text("home.recent.activeTranscription.hint", fallback: "Return to the transcription screen"))
                    }

                    // Saved transcriptions
                    ForEach(Array(viewModel.transcriptions.prefix(5))) { transcription in
                        Button {
                            viewModel.selectTranscription(transcription)
                        } label: {
                            RecentTranscriptionCard(transcription: transcription)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(String(
                            format: localizationManager.text("home.recent.savedTranscription.label", fallback: "Transcription: %@"),
                            transcription.title
                        ))
                        .accessibilityHint(localizationManager.text("home.recent.savedTranscription.hint", fallback: "Open transcript"))
                    }
                }
                .padding(.horizontal, metrics.sectionPadding)
            }
        }
    }
    
    // MARK: - Splash Sequence
    
    private func startSplashSequence() {
        print("🎬 [Master] Starting splash sequence")
        
        // Start breathing animation for splash phase
        withAnimation(
            .easeInOut(duration: 1.4)
            .repeatForever(autoreverses: true)
        ) {
            breatheScale = 1.05
            glowScale = 1.04
        }
        
        // Minimum splash duration (1.5 seconds of breathing)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            print("🎬 [Master] Minimum time elapsed")
            self.minimumTimeElapsed = true
            self.checkReadyToTransition()
        }
    }
    
    private func checkReadyToTransition() {
        print("🎬 [Master] Check ready - minimum: \(minimumTimeElapsed), deps: \(dependencyCheckComplete)")
        
        guard minimumTimeElapsed && dependencyCheckComplete else { return }
        guard !isAppReady else { return }
        
        print("🎬 [Master] ✨ Starting transition to Home")
        startTransitionToHome()
    }
    
    private func startTransitionToHome() {
        // Stop breathing animation by setting fixed scale
        breatheScale = 1.0
        skipHomeEntryAnimation = false
        hasPlayedHomeOpeningAnimation = true
        
        // Transition to home state with spring physics
        withAnimation(logoSpring) {
            isAppReady = true
        }
        
        // Staggered entrance of home elements
        triggerEntranceAnimations()
    }

    private func showHomeImmediately() {
        skipHomeEntryAnimation = true
        minimumTimeElapsed = true
        breatheScale = 1.0
        glowScale = 1.0
        isAppReady = true
        showTopBar = true
        showDropText = true
        showDropZone = true
        showDock = true
    }
    
    private func triggerEntranceAnimations() {
        // T=0.08s: TopBar appears first
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            withAnimation(.easeOut(duration: 0.22)) {
                showTopBar = true
            }
        }
        
        // T=0.16s: Drop text + zone appear together (fewer concurrent effects)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
            withAnimation(.easeOut(duration: 0.24)) {
                showDropText = true
                showDropZone = true
            }
        }
        
        // T=0.24s: Bottom dock appears
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
            withAnimation(.easeOut(duration: 0.22)) {
                showDock = true
            }
        }
    }
    
    // MARK: - Actions

    private func openFilePicker() {
        guard let url = FileInputService.pickSingleFile() else { return }
        handleSelectedFile(url)
    }
    
    private func handleSelectedFile(_ url: URL) {
        viewModel.selectedFileURL = url
        showingNewTranscription = true
    }
    
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        AppLogger.shared.log("🔵 [MasterView] handleDrop called with \(providers.count) providers", category: .transcription)
        
        guard !providers.isEmpty else {
            AppLogger.shared.log("❌ [MasterView] No providers found", level: .warning, category: .transcription)
            return false
        }
        
        // Process all providers asynchronously and collect URLs
        Task {
            var collectedURLs: [URL] = []
            
            for (index, provider) in providers.enumerated() {
                AppLogger.shared.log("🔵 [MasterView] Processing provider \(index + 1)/\(providers.count)", category: .transcription)
                
                if let url = await loadURLFromProvider(provider) {
                    collectedURLs.append(url)
                    AppLogger.shared.log("✅ [MasterView] Got URL: \(url.lastPathComponent)", category: .transcription)
                }
            }
            
            await MainActor.run {
                if !collectedURLs.isEmpty {
                    AppLogger.shared.log("✅ [MasterView] Collected \(collectedURLs.count) files", category: .transcription)
                    // Set URLs in viewModel for the sheet
                    viewModel.selectedFileURLs = collectedURLs
                    if let first = collectedURLs.first {
                        viewModel.selectedFileURL = first
                    }
                    
                    // Show configuration sheet
                    showingNewTranscription = true
                } else {
                    AppLogger.shared.log("❌ [MasterView] No valid URLs collected", level: .warning, category: .transcription)
                }
            }
        }
        
        return true
    }
    
    /// Load URL from a single provider (tries different types)
    private func loadURLFromProvider(_ provider: NSItemProvider) async -> URL? {
        // Try fileURL first
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            return await withCheckedContinuation { continuation in
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { data, error in
                    if let data = data as? Data,
                       let url = URL(dataRepresentation: data, relativeTo: nil) {
                        continuation.resume(returning: url)
                    } else {
                        continuation.resume(returning: nil)
                    }
                }
            }
        }
        
        // Try audio type
        if provider.hasItemConformingToTypeIdentifier(UTType.audio.identifier) {
            return await withCheckedContinuation { continuation in
                provider.loadItem(forTypeIdentifier: UTType.audio.identifier) { item, error in
                    if let url = item as? URL {
                        continuation.resume(returning: url)
                    } else if let data = item as? Data,
                              let url = URL(dataRepresentation: data, relativeTo: nil) {
                        continuation.resume(returning: url)
                    } else {
                        continuation.resume(returning: nil)
                    }
                }
            }
        }
        
        // Try movie type
        if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
            return await withCheckedContinuation { continuation in
                provider.loadItem(forTypeIdentifier: UTType.movie.identifier) { item, error in
                    if let url = item as? URL {
                        continuation.resume(returning: url)
                    } else if let data = item as? Data,
                              let url = URL(dataRepresentation: data, relativeTo: nil) {
                        continuation.resume(returning: url)
                    } else {
                        continuation.resume(returning: nil)
                    }
                }
            }
        }
        
        return nil
    }
    
    private func startQuickTranscribe(url: URL) {
        AppLogger.shared.log("🔵 [MasterView] startQuickTranscribe: \(url.lastPathComponent)", category: .transcription)
        viewModel.selectedFileURL = url
        
        // Always show the transcription sheet so user can configure options
        // The sheet has a "Transcribir" button that will trigger the actual enqueue
        showingNewTranscription = true
        
        AppLogger.shared.log("✅ [MasterView] Showing transcription options sheet", category: .transcription)
    }
    
    private func pasteFromClipboard() {
        let pasteboard = NSPasteboard.general
        
        // Check for file URLs
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
           let url = urls.first {
            handleSelectedFile(url)
            return
        }
        
        // Check for file paths as strings
        if let string = pasteboard.string(forType: .string),
           string.hasPrefix("/") || string.hasPrefix("file://") {
            let url = string.hasPrefix("file://") 
                ? URL(string: string)! 
                : URL(fileURLWithPath: string)
            handleSelectedFile(url)
        }
    }
}

// MARK: - Preview
#if DEBUG
struct MasterView_Previews: PreviewProvider {
    static var previews: some View {
        MasterView(
            showingRecorder: .constant(false),
            showingNewTranscription: .constant(false),
            dependencyCheckComplete: .constant(false),
            hasPlayedHomeOpeningAnimation: .constant(false),
            showLibraryDrawer: .constant(false),
            showSettingsSheet: .constant(false),
            showQueuePanel: .constant(false)
        )
        .environmentObject(TranscriptionViewModel())
        .environmentObject(LocalizationManager())
        .frame(width: 1200, height: 700)
    }
}
#endif

// MARK: - Active Transcription Card Component
struct ActiveTranscriptionCard: View {
    @EnvironmentObject var localizationManager: LocalizationManager
    @Environment(\.responsiveMetrics) private var metrics
    let fileName: String
    let progress: Int
    let statusMessage: String
    let streamingText: String
    let onExpand: () -> Void
    let onCancel: () -> Void

    @State private var isHovered = false
    @State private var cancelHovered = false

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: 3.0) / 3.0

            content(trimPosition: t)
        }
    }

    private func content(trimPosition: Double) -> some View {
        // Card content wrapped in expand button
        Button(action: onExpand) {
            VStack(alignment: .leading, spacing: 8) {
                // Title (mirrors RecentTranscriptionCard exactly)
                HStack(spacing: 0) {
                    Text(fileName)
                        .font(.labelLarge)
                        .foregroundColor(.textPrimary)
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    // Invisible spacer matching cancel button size (actual button is overlaid)
                    Color.clear.frame(width: 20, height: 20)
                }

                // % · estado (mirrors date · duration row)
                HStack(spacing: 6) {
                    Text("\(progress)%")
                        .font(.caption)
                        .foregroundColor(.accentPrimary)
                        .monospacedDigit()

                    Text("·")
                        .font(.caption)
                        .foregroundColor(.textTertiary)

                    Text(localizedStatusMessage)
                        .font(.caption)
                        .foregroundColor(.textTertiary)
                        .lineLimit(1)
                }

                // "En proceso" badge (mirrors language badge)
                Text(localizationManager.text("home.recent.active.badge", fallback: "In progress"))
                    .font(.labelSmall)
                    .foregroundColor(.accentPrimary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentPrimary.opacity(0.12)))
            }
            .padding(16)
            .frame(width: metrics.cardWidth, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Cancel button overlaid on top-right
        .overlay(alignment: .topTrailing) {
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(cancelHovered ? Color(hex: "#FF6B6B") : .textTertiary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(cancelHovered ? Color(hex: "#FF6B6B").opacity(0.15) : Color.bgSecondary.opacity(0.6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 5)
                                    .stroke(cancelHovered ? Color(hex: "#FF6B6B").opacity(0.3) : Color.borderSubtle, lineWidth: 1)
                            )
                    )
            }
            .buttonStyle(.borderless)
            .onHover { hovering in
                withAnimation(.smooth(duration: 0.15)) { cancelHovered = hovering }
            }
            .help("Cancelar")
            .padding(16)
        }
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(isHovered ? Color.bgSecondary : Color.bgElevated)
        )
        // Border base
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.borderSubtle, lineWidth: 1)
        )
        // Travelling glow — Canvas draws N small segments, each fading from transparent to bright
        .overlay(
            Canvas { ctx, size in
                let steps = 80
                let trailLength: Double = 0.25
                let lineWidth: CGFloat = 2.5

                let inset = lineWidth / 2
                let drawRect = CGRect(x: inset, y: inset,
                                      width: size.width - lineWidth,
                                      height: size.height - lineWidth)
                let fullPath = RoundedRectangle(cornerRadius: 16 - inset)
                    .path(in: drawRect)

                let style = StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                let head = trimPosition
                let tail = head - trailLength

                for i in 0..<steps {
                    let frac = Double(i) / Double(steps)

                    // Raw positions along the trail (may be negative)
                    var segStart = tail + frac * trailLength
                    var segEnd   = tail + Double(i + 1) / Double(steps) * trailLength

                    // Normalize to [0, 1)
                    segStart = segStart - floor(segStart)
                    segEnd   = segEnd   - floor(segEnd)

                    // Brightness: quadratic ramp — transparent tail → bright head
                    let brightness = frac * frac * 0.9

                    if segEnd > segStart {
                        // Normal segment — no wrapping
                        let trimmed = fullPath.trimmedPath(from: segStart, to: segEnd)
                        ctx.stroke(trimmed,
                                   with: .color(Color.accentSecondary.opacity(brightness)),
                                   style: style)
                    } else {
                        // Segment wraps around the 0/1 boundary — split in two
                        let part1 = fullPath.trimmedPath(from: segStart, to: 0.999)
                        let part2 = fullPath.trimmedPath(from: 0.001, to: segEnd)
                        ctx.stroke(part1,
                                   with: .color(Color.accentSecondary.opacity(brightness)),
                                   style: style)
                        ctx.stroke(part2,
                                   with: .color(Color.accentSecondary.opacity(brightness)),
                                   style: style)
                    }
                }
            }
            .allowsHitTesting(false)
        )
        .shadow(
            color: Color.accentPrimary.opacity(isHovered ? 0.18 : 0.08),
            radius: isHovered ? 16 : 6,
            y: isHovered ? 6 : 2
        )
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .onHover { hovering in
            withAnimation(.smooth(duration: 0.15)) { isHovered = hovering }
        }
    }

    private var localizedStatusMessage: String {
        if statusMessage.isEmpty {
            return localizationManager.text("home.recent.active.status", fallback: "Transcribing...")
        }

        let lower = statusMessage.lowercased()
        if lower.contains("transcrib") || lower.contains("whisper") {
            return localizationManager.text("queue.status.processing", fallback: "Processing")
        }
        if lower.contains("iniciando") || lower.contains("starting") {
            return localizationManager.appLanguage == .es ? "Iniciando transcripción..." : "Starting transcription..."
        }
        if lower.contains("detectando idioma") || lower.contains("detecting language") {
            return localizationManager.appLanguage == .es ? "Detectando idioma..." : "Detecting language..."
        }
        if lower.contains("cancelad") || lower.contains("cancel") {
            return localizationManager.text("queue.status.cancelled", fallback: "Cancelled")
        }

        return statusMessage
    }
}

// MARK: - Recent Transcription Card Component
struct RecentTranscriptionCard: View {
    let transcription: Transcription
    @Environment(\.responsiveMetrics) private var metrics
    
    @State private var isHovered = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Title
            Text(transcription.title)
                .font(.labelLarge)
                .foregroundColor(.textPrimary)
                .lineLimit(1)
            
            // Date + duration
            HStack(spacing: 6) {
                Text(transcription.formattedDate)
                    .font(.caption)
                    .foregroundColor(.textTertiary)
                
                if transcription.duration > 0 {
                    Text("·")
                        .foregroundColor(.textTertiary)
                    Text(transcription.formattedDuration)
                        .font(.caption)
                        .foregroundColor(.textTertiary)
                }
            }
            
            // Language badge
            Text(transcription.languageDisplayName)
                .font(.labelSmall)
                .foregroundColor(.accentPrimary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule()
                        .fill(Color.accentPrimary.opacity(0.12))
                )
        }
        .padding(16)
        .frame(width: metrics.cardWidth, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(isHovered ? Color.bgSecondary : Color.bgElevated)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(
                            isHovered ? Color.accentPrimary.opacity(0.25) : Color.borderSubtle,
                            lineWidth: 1
                        )
                )
        )
        .shadow(
            color: isHovered ? Color.accentPrimary.opacity(0.12) : Color.black.opacity(0.08),
            radius: isHovered ? 16 : 6,
            y: isHovered ? 6 : 2
        )
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .onHover { hovering in
            withAnimation(.smooth(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}
