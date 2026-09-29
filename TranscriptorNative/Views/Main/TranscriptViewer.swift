import SwiftUI

// MARK: - Transcript Viewer (Cinema Glassmorphism Style)
struct TranscriptViewer: View {
    @EnvironmentObject var viewModel: TranscriptionViewModel
    @EnvironmentObject var localizationManager: LocalizationManager
    @Environment(\.responsiveMetrics) private var metrics
    @State private var searchText = ""
    @State private var isSearching = false
    @State private var editableTitle = "Nueva Transcripción"
    @FocusState private var isTitleFocused: Bool
    @AppStorage("showTimestamps") private var showTimestamps = true
    
    // Cinema background animation
    @State private var wavePhase: Double = 0
    private let waveTimer = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()
    
    // === SEAMLESS TRANSITION STATES ===
    // Master transition progress (0 = processing, 1 = result)
    @State private var transitionProgress: CGFloat = 0
    
    // Phase timing
    @State private var isInTransition = false
    @State private var showCompletionGlow = false
    
    // Individual element states for fine control
    @State private var headerOpacity: CGFloat = 0
    @State private var headerOffset: CGFloat = -30
    @State private var processingOpacity: CGFloat = 1
    @State private var processingScale: CGFloat = 1
    @State private var resultOpacity: CGFloat = 0
    @State private var resultScale: CGFloat = 0.95
    @State private var playerOffset: CGFloat = 80
    @State private var playerOpacity: CGFloat = 0
    @State private var textCascadeProgress: Double = 0
    
    // Track state changes
    @State private var wasTranscribing = false
    @State private var hasResult = false
    
    // Computed visibility
    private var shouldShowTranscriptionView: Bool {
        viewModel.isTranscribing && !viewModel.isMinimizedToBackground ||
        viewModel.transcriptionResult != nil ||
        isInTransition
    }
    
    private var showProcessingView: Bool {
        (viewModel.isTranscribing && !viewModel.isMinimizedToBackground) || isInTransition
    }
    
    private var showResultView: Bool {
        viewModel.transcriptionResult != nil || isInTransition
    }
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Cinema Background System - always present, morphs color
                fullCinemaBackground(in: geometry)
                    .overlay(completionGlowOverlay)
                
                if shouldShowTranscriptionView {
                    ZStack {
                        // === PROCESSING PANEL (manages its own glass panel internally) ===
                        if showProcessingView {
                            TranscriptionProgressIndicator()
                                .opacity(processingOpacity)
                                .scaleEffect(processingScale)
                                .allowsHitTesting(processingOpacity > 0.5)
                        }

                        // === RESULT PANEL (unified glass panel, mirrors processing screen) ===
                        if showResultView && viewModel.transcriptionResult != nil {
                            resultGlassPanel
                                .frame(
                                    width: geometry.size.width * metrics.viewerWidthRatio,
                                    height: geometry.size.height * metrics.viewerHeightRatio
                                )
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .offset(y: metrics.viewerOffset)
                                .scaleEffect(resultScale)
                                .opacity(resultOpacity)
                                .allowsHitTesting(resultOpacity > 0.5)
                        }
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .onAppear {
            setupInitialState()
        }
        .onChange(of: viewModel.isTranscribing) { isNowTranscribing in
            handleTranscribingStateChange(isNowTranscribing)
        }
        .onChange(of: viewModel.transcriptionResult != nil) { hasNewResult in
            if hasNewResult && !hasResult {
                hasResult = true
                // If we get a result without going through transcription (e.g., from URL),
                // immediately show the result
                if !viewModel.isTranscribing {
                    print("🎬 [TranscriptViewer] Got new result without transcription, showing immediately")
                    setResultState()
                }
            }
        }
        .onChange(of: viewModel.selectedTranscription?.id) { _ in
            guard !isTitleFocused else { return }
            if let selected = viewModel.selectedTranscription {
                editableTitle = selected.title
            } else if let file = viewModel.selectedFile {
                editableTitle = file.name.replacingOccurrences(of: ".\(file.url.pathExtension)", with: "")
            }
        }
        .onReceive(waveTimer) { _ in
            wavePhase += 0.03
        }
        .background(keyboardShortcuts)
    }
    
    // MARK: - Initial State Setup
    private func setupInitialState() {
        if let file = viewModel.selectedFile {
            editableTitle = file.name.replacingOccurrences(of: ".\(file.url.pathExtension)", with: "")
        }
        
        // If we have a selectedTranscription, use its title
        if let selected = viewModel.selectedTranscription {
            editableTitle = selected.title
        }
        
        wasTranscribing = viewModel.isTranscribing
        hasResult = viewModel.transcriptionResult != nil
        
        // If we have a result (from URL or file), always show it immediately
        if viewModel.transcriptionResult != nil {
            print("🎬 [TranscriptViewer] setupInitialState - has result, setting result state")
            setResultState()
        } else if viewModel.isTranscribing {
            setProcessingState()
        }
    }
    
    // MARK: - State Handlers
    private func handleTranscribingStateChange(_ isNowTranscribing: Bool) {
        if wasTranscribing && !isNowTranscribing && viewModel.transcriptionResult != nil {
            // Transition: Processing → Result
            performSeamlessTransition()
        } else if isNowTranscribing && !wasTranscribing {
            // Starting new transcription
            resetToProcessingState()
        }
        wasTranscribing = isNowTranscribing
    }
    
    private func setProcessingState() {
        headerOpacity = 0
        headerOffset = -30
        processingOpacity = 1
        processingScale = 1
        resultOpacity = 0
        resultScale = 0.95
        playerOffset = 80
        playerOpacity = 0
        textCascadeProgress = 0
        transitionProgress = 0
    }
    
    private func setResultState() {
        headerOpacity = 1
        headerOffset = 0
        processingOpacity = 0
        processingScale = 1.02
        resultOpacity = 1
        resultScale = 1
        playerOffset = 0
        playerOpacity = 1
        textCascadeProgress = 1
        transitionProgress = 1
    }
    
    private func resetToProcessingState() {
        withAnimation(.easeOut(duration: 0.3)) {
            setProcessingState()
        }
        hasResult = false
        isInTransition = false
        showCompletionGlow = false
    }
    
    // MARK: - Seamless Transition Choreography
    private func performSeamlessTransition() {
        print("🎬 Starting seamless transition")
        isInTransition = true
        
        // Phase 1: feedback breve de finalización
        withAnimation(.easeOut(duration: 0.2)) {
            showCompletionGlow = true
        }
        
        // Phase 2: transición principal (menos capas en paralelo)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            withAnimation(.easeInOut(duration: 0.35)) {
                self.processingOpacity = 0
                self.processingScale = 1.01
                self.resultOpacity = 1
                self.resultScale = 1
                self.headerOpacity = 1
                self.headerOffset = 0
            }
        }
        
        // Phase 3: controles y texto secundarios
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
            withAnimation(.easeOut(duration: 0.28)) {
                self.playerOffset = 0
                self.playerOpacity = 1
                self.textCascadeProgress = 1
                self.showCompletionGlow = false
            }
        }
        
        // Cleanup
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) {
            self.isInTransition = false
            self.transitionProgress = 1
            print("🎬 Transition complete")
        }
    }
    
    // MARK: - Result Glass Panel (mirrors processing panel structure)
    private var resultGlassPanel: some View {
        VStack(spacing: 0) {
            // Header inside the panel (matches processingHeaderBar style)
            TranscriptHeaderView(
                title: $editableTitle,
                isTitleFocused: _isTitleFocused,
                searchText: $searchText,
                isSearching: $isSearching
            )

            // Separator
            Rectangle()
                .fill(Color.borderSubtle)
                .frame(height: 1)

            // Transcript content (fills remaining space)
            TranscriptContentView(
                searchText: searchText,
                showTimestamps: showTimestamps,
                cascadeProgress: textCascadeProgress
            )

            // Audio player docked at bottom inside panel
            if viewModel.hasAudioLoaded {
                CinemaAudioPlayer()
                    .offset(y: playerOffset)
                    .opacity(playerOpacity)
                    .allowsHitTesting(playerOpacity > 0.5)
            }
        }
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 28)
                    .fill(Color.bgSecondary.opacity(0.62))
                RoundedRectangle(cornerRadius: 28)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.primary.opacity(0.04),
                                Color.clear,
                                Color.accentPrimary.opacity(0.02)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 28)
                .stroke(Color.borderSubtle, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.18), radius: 40, x: 0, y: 16)
        .shadow(color: Color.accentPrimary.opacity(0.07), radius: 60, x: 0, y: 10)
        .clipShape(RoundedRectangle(cornerRadius: 28))
    }

    // MARK: - Completion Glow Overlay
    private var completionGlowOverlay: some View {
        ZStack {
            if showCompletionGlow {
                // Radial pulse from center
                RadialGradient(
                    colors: [
                        Color.accentPrimary.opacity(0.22),
                        Color.accentSecondary.opacity(0.10),
                        Color.clear
                    ],
                    center: .center,
                    startRadius: 0,
                    endRadius: 500
                )
                .scaleEffect(showCompletionGlow ? 1.5 : 0.8)
                .opacity(showCompletionGlow ? 1 : 0)
                .animation(.easeOut(duration: 0.35), value: showCompletionGlow)
                .allowsHitTesting(false)
            }
        }
    }
    
    // MARK: - Keyboard Shortcuts
    private var keyboardShortcuts: some View {
        Button("") {
            if viewModel.transcriptionResult != nil {
                withAnimation(.smooth) { isSearching.toggle() }
            }
        }
        .keyboardShortcut("f", modifiers: .command)
        .hidden()
    }
    
    // MARK: - Unified Background (aligned with Home aesthetics)
    @ViewBuilder
    private func fullCinemaBackground(in geometry: GeometryProxy) -> some View {
        ZStack {
            // Base layer shared with Home
            Color.bgPrimary
                .ignoresSafeArea()
            
            // Primary ambient glow (same language as Home)
            RadialGradient(
                colors: [
                    Color.accentPrimary.opacity(0.16),
                    Color.accentSecondary.opacity(0.08),
                    Color.clear
                ],
                center: .center,
                startRadius: 40,
                endRadius: min(geometry.size.width, geometry.size.height) * 0.8
            )
            .blur(radius: 90)

            // Secondary offset glow for depth
            RadialGradient(
                colors: [
                    Color.accentSecondary.opacity(0.10),
                    Color.clear
                ],
                center: UnitPoint(x: 0.28, y: 0.62),
                startRadius: 0,
                endRadius: 420
            )
            .blur(radius: 110)

            // Soft animated texture only on result view
            if viewModel.transcriptionResult != nil && !viewModel.isTranscribing {
                CinemaWaveView(phase: wavePhase, amplitude: 0.5)
                    .opacity(0.05)
                    .blur(radius: 40)
            }
        }
    }
}

// MARK: - Transcript Header (Floating Cinema Style)
struct TranscriptHeaderView: View {
    @Binding var title: String
    @FocusState var isTitleFocused: Bool
    @Binding var searchText: String
    @Binding var isSearching: Bool
    @AppStorage("showTimestamps") private var showTimestamps = true
    @EnvironmentObject var viewModel: TranscriptionViewModel
    @Environment(\.responsiveMetrics) private var metrics
    
    private var appLanguage: AppLanguage {
        UserDefaults.standard.string(forKey: "app_ui_language") == "es" ? .es : .en
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Top bar with title and actions - floating style
            HStack(alignment: .top, spacing: 16) {
                // Back button
                Button(action: { goBackToHome() }) {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left")
                            .font(.titleDefault)
                        Text("Inicio")
                            .font(.labelDefault)
                    }
                    .foregroundColor(.textSecondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        Capsule()
                            .fill(Color.bgSecondary)
                    )
                }
                .buttonStyle(.plain)
                .padding(.trailing, 8)
                
                // Title & Metadata
                VStack(alignment: .leading, spacing: 8) {
                    // Large editable title
                    TextField("Título", text: $title)
                        .font(.transcriptTitle)
                        .foregroundColor(.textPrimary)
                        .textFieldStyle(.plain)
                        .focused($isTitleFocused)
                        .onSubmit { persistTitleIfPossible() }
                        .onChange(of: isTitleFocused) { focused in
                            if !focused {
                                persistTitleIfPossible()
                            }
                        }
                    
                    // Metadata Row - subtle gray
                    HStack(spacing: 12) {
                        // Date
                        HStack(spacing: 5) {
                            Image(systemName: "calendar")
                                .font(.caption)
                            Text(headerDate, style: .date)
                                .font(.bodyMedium)
                        }
                        .foregroundColor(.textSecondary)

                        // Duration
                        if let file = viewModel.selectedFile {
                            Text("•")
                                .foregroundColor(.textTertiary)

                            HStack(spacing: 5) {
                                Image(systemName: "clock")
                                    .font(.caption)
                                Text(file.formattedDuration)
                                    .font(.bodyMedium)
                            }
                            .foregroundColor(.textSecondary)
                        }

                        // Tags
                        if viewModel.transcriptionResult != nil {
                            Text("•")
                                .foregroundColor(.textTertiary)
                            
                            HStack(spacing: 6) {
                                CinemaTag(languageName(viewModel.settings.language))
                                CinemaTag(modelShortName(viewModel.settings.selectedModelId))
                                
                                if viewModel.settings.useCoreML {
                                    CinemaTag("Neural", icon: "bolt.fill")
                                }
                            }
                        }
                    }
                }
                
                Spacer()
                
                // Action Buttons - Floating glass style
                let hasText = viewModel.transcriptionResult != nil
                
                HStack(spacing: 4) {
                    // Timestamps toggle
                    CinemaToolbarButton(
                        icon: showTimestamps ? "clock.fill" : "clock",
                        label: "Marcas de tiempo",
                        isActive: showTimestamps,
                        isDisabled: !hasText
                    ) {
                        withAnimation(.smooth) { showTimestamps.toggle() }
                    }
                    
                    CinemaToolbarButton(
                        icon: "magnifyingglass",
                        label: "Buscar",
                        isActive: isSearching,
                        isDisabled: !hasText
                    ) {
                        withAnimation(.smooth) { isSearching.toggle() }
                    }
                    
                    CinemaToolbarButton(
                        icon: viewModel.showFavoritesOnly ? "star.fill" : "star",
                        label: appLanguage == .es ? "Solo favoritos" : "Favorites only",
                        isActive: viewModel.showFavoritesOnly,
                        isDisabled: !hasText
                    ) {
                        withAnimation(.smooth) { viewModel.showFavoritesOnly.toggle() }
                    }
                    
                    CinemaToolbarButton(
                        icon: viewModel.isEditMode ? "pencil.circle.fill" : "pencil.circle",
                        label: appLanguage == .es ? (viewModel.isEditMode ? "Modo edición" : "Modo lectura") : (viewModel.isEditMode ? "Edit mode" : "Read mode"),
                        isActive: viewModel.isEditMode,
                        isDisabled: !hasText
                    ) {
                        withAnimation(.smooth) { viewModel.isEditMode.toggle() }
                    }
                    
                    CinemaToolbarButton(
                        icon: "doc.on.doc",
                        label: "Copiar transcripción",
                        isDisabled: !hasText
                    ) {
                        viewModel.copyTranscription()
                    }
                    
                    // Export Menu
                    Menu {
                        let hasSegments = viewModel.transcriptionResult?.segments.isEmpty == false
                        
                        Section(appLanguage == .es ? "Documentos" : "Documents") {
                            Button { viewModel.exportTranscription(format: .txt) } label: {
                                Label(ExportFormat.txt.localizedDescription(appLanguage), systemImage: ExportFormat.txt.icon)
                            }
                            Button { viewModel.exportTranscription(format: .md) } label: {
                                Label(ExportFormat.md.localizedDescription(appLanguage), systemImage: ExportFormat.md.icon)
                            }
                            Button { viewModel.exportTranscription(format: .html) } label: {
                                Label(ExportFormat.html.localizedDescription(appLanguage), systemImage: ExportFormat.html.icon)
                            }
                            Button { viewModel.exportTranscription(format: .pdf) } label: {
                                Label(ExportFormat.pdf.localizedDescription(appLanguage), systemImage: ExportFormat.pdf.icon)
                            }
                            Button { viewModel.exportTranscription(format: .docx) } label: {
                                Label(ExportFormat.docx.localizedDescription(appLanguage), systemImage: ExportFormat.docx.icon)
                            }
                        }
                        
                        Section(appLanguage == .es ? "Datos" : "Data") {
                            Button { viewModel.exportTranscription(format: .csv) } label: {
                                Label(
                                    appLanguage == .es ? "Hoja de cálculo (.csv)" : "Spreadsheet (.csv)",
                                    systemImage: "tablecells"
                                )
                            }
                            Button { viewModel.exportCSVSimple() } label: {
                                Label(
                                    appLanguage == .es ? "CSV simple (.csv)" : "Plain CSV (.csv)",
                                    systemImage: "tablecells.badge.ellipsis"
                                )
                            }
                        }
                        
                        Section(appLanguage == .es ? "Subtítulos" : "Subtitles") {
                            Button { viewModel.exportTranscription(format: .srt) } label: {
                                Label(ExportFormat.srt.localizedDescription(appLanguage), systemImage: ExportFormat.srt.icon)
                            }
                            .disabled(!hasSegments)
                            
                            Button { viewModel.exportTranscription(format: .vtt) } label: {
                                Label(ExportFormat.vtt.localizedDescription(appLanguage), systemImage: ExportFormat.vtt.icon)
                            }
                            .disabled(!hasSegments)
                        }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                            .font(.bodyDefault)
                            .foregroundColor(hasText ? .textSecondary : .textMuted)
                            .frame(width: 36, height: 36)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color.bgElevated)
                            )
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 36)
                    .disabled(!hasText)
                    .opacity(hasText ? 1 : 0.5)
                    .accessibilityLabel(appLanguage == .es ? "Exportar" : "Export")
                    .accessibilityHint(appLanguage == .es ? "Abre el menú de formatos de exportación" : "Opens the export format menu")
                }
            }
            
            // Search Bar (conditional)
            if isSearching {
                CinemaSearchBar(text: $searchText)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, metrics.viewerHPadding)
        .padding(.top, 20)
        .padding(.bottom, 16)
        // No background - floats on the app dark background
    }
    
    // Go back to home - clear transcription
    private func goBackToHome() {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            viewModel.clearTranscription()
        }
    }
    
    private func languageName(_ code: String) -> String {
        LocalizationHelpers.languageTag(code)
    }
    
    private func modelShortName(_ id: String) -> String {
        LocalizationHelpers.modelShortName(id)
    }

    private var headerDate: Date {
        viewModel.selectedTranscription?.createdAt ?? viewModel.transcriptionStartTime ?? Date()
    }

    private func persistTitleIfPossible() {
        guard var transcription = viewModel.selectedTranscription else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != transcription.title else { return }
        transcription.title = trimmed
        viewModel.selectedTranscription = transcription
        viewModel.saveTranscription(transcription)
    }
}
// MARK: - Cinema Tag (Subtle glass pill)
struct CinemaTag: View {
    let text: String
    let icon: String?

    init(_ text: String, icon: String? = nil) {
        self.text = text
        self.icon = icon
    }

    var body: some View {
        HStack(spacing: 4) {
            if let icon = icon {
                Image(systemName: icon)
                    .font(.system(size: 9))
            }
            Text(text)
                .font(.labelMedium)
        }
        .foregroundColor(.textSecondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(Color.bgSecondary)
        )
    }
}

// MARK: - Cinema Toolbar Button (Floating glass style)
struct CinemaToolbarButton: View {
    let icon: String
    var label: String = ""
    var isActive: Bool = false
    var isDisabled: Bool = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.labelDefault)
                .foregroundColor(
                    isDisabled ? .textMuted :
                    (isActive ? .accentPrimary : (isHovered ? .textPrimary : .textSecondary))
                )
                .frame(width: 36, height: 36)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(isActive ? Color.accentPrimary.opacity(0.18) :
                              (isHovered && !isDisabled ? Color.bgHover : Color.bgElevated))
                )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .onHover { hovering in
            guard !isDisabled else { return }
            withAnimation(.quick) { isHovered = hovering }
        }
        .accessibilityLabel(label.isEmpty ? icon : label)
    }
}

// MARK: - Cinema Search Bar (Glass style)
struct CinemaSearchBar: View {
    @Binding var text: String
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.bodyDefault)
                .foregroundColor(.textSecondary)

            TextField("Buscar en transcripción...", text: $text)
                .font(.bodyLarge)
                .foregroundColor(.textPrimary)
                .textFieldStyle(.plain)
                .focused($isFocused)
            
            if !text.isEmpty {
                Button(action: { text = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.bodyDefault)
                        .foregroundColor(.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.bgSecondary)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(isFocused ? Color.accentPrimary.opacity(0.5) : Color.borderSubtle, lineWidth: 1)
                )
        )
        .onAppear { isFocused = true }
    }
}
// MARK: - Cinema Audio Player (Refined 2026)
struct CinemaAudioPlayer: View {
    @EnvironmentObject var viewModel: TranscriptionViewModel

    @State private var isDragging = false
    @State private var isTrackHovered = false
    @State private var isPlayHovered = false
    @State private var dragProgress: Double = 0

    private let speeds: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

    private var progress: Double {
        isDragging ? dragProgress :
        (viewModel.duration > 0 ? viewModel.currentTime / viewModel.duration : 0)
    }

    private var isSpeedActive: Bool { viewModel.playbackSpeed != 1.0 }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let s = max(0, seconds)
        let m = Int(s) / 60
        return String(format: "%d:%02d", m, Int(s) % 60)
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── Top separator ──────────────────────────────────────────
            Rectangle()
                .fill(Color.borderSubtle)
                .frame(height: 1)

            // ── Player row ─────────────────────────────────────────────
            HStack(spacing: 0) {

                // ── Left cluster: transport controls ──────────────────
                HStack(spacing: 4) {
                    // Skip back
                    CinemaPlayerButton(icon: "gobackward.10", size: 38) {
                        viewModel.skipBackward()
                    }

                    // Play / Pause — hero button
                    Button { viewModel.togglePlayback() } label: {
                        ZStack {
                            // Glow — always present, animates opacity so layout never shifts
                            Circle()
                                .fill(Color.accentPrimary.opacity(0.22))
                                .frame(width: 62, height: 62)
                                .blur(radius: 14)
                                .opacity(viewModel.isPlaying ? 1 : 0)

                            Circle()
                                .fill(Color.gradientBrand)
                                .frame(width: 48, height: 48)
                                .shadow(
                                    color: Color.accentPrimary.opacity(viewModel.isPlaying ? 0.50 : 0.25),
                                    radius: viewModel.isPlaying ? 14 : 6,
                                    y: 3
                                )

                            Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 17, weight: .bold))
                                .foregroundColor(.white)
                                .offset(x: viewModel.isPlaying ? 0 : 1.5)
                        }
                        .frame(width: 62, height: 62) // fixed frame — never changes size
                        .scaleEffect(isPlayHovered ? 1.07 : 1.0)
                        .animation(.spring(response: 0.25, dampingFraction: 0.65), value: isPlayHovered)
                        .animation(.easeOut(duration: 0.3), value: viewModel.isPlaying)
                    }
                    .buttonStyle(.plain)
                    .onHover { isPlayHovered = $0 }

                    // Skip forward
                    CinemaPlayerButton(icon: "goforward.10", size: 38) {
                        viewModel.skipForward()
                    }
                }
                .padding(.leading, 28)
                .padding(.trailing, 20)

                // ── Elapsed time ──────────────────────────────────────
                Text(formatTime(viewModel.currentTime))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(.textSecondary)
                    .frame(width: 36, alignment: .trailing)
                    .padding(.trailing, 12)

                // ── Scrub track ────────────────────────────────────────
                GeometryReader { geo in
                    let trackH: CGFloat = (isTrackHovered || isDragging) ? 6 : 4
                    let headSize: CGFloat = (isTrackHovered || isDragging) ? 14 : 0
                    let fillW = max(trackH, geo.size.width * CGFloat(progress))

                    ZStack(alignment: .leading) {
                        // Background rail
                        Capsule()
                            .fill(Color.primary.opacity(0.10))
                            .frame(height: trackH)

                        // Filled portion — brand gradient
                        Capsule()
                            .fill(Color.gradientBrand)
                            .frame(width: fillW, height: trackH)
                            .shadow(
                                color: Color.accentPrimary.opacity(isDragging ? 0.45 : 0.25),
                                radius: 6, y: 1
                            )

                        // Playhead dot
                        Circle()
                            .fill(Color.white)
                            .frame(width: headSize, height: headSize)
                            .shadow(color: Color.accentPrimary.opacity(0.6), radius: 5)
                            .offset(x: max(0, fillW - headSize / 2))
                            .animation(.easeOut(duration: 0.12), value: headSize)
                    }
                    .frame(height: 20, alignment: .center)
                    .contentShape(Rectangle())
                    .onHover { isTrackHovered = $0 }
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { v in
                                isDragging = true
                                dragProgress = max(0, min(1, v.location.x / geo.size.width))
                                viewModel.seek(to: viewModel.duration * dragProgress)
                            }
                            .onEnded { _ in isDragging = false }
                    )
                    .animation(.easeOut(duration: 0.15), value: isTrackHovered)
                }
                .frame(height: 20)

                // ── Remaining time ────────────────────────────────────
                Text("-\(formatTime(viewModel.duration - viewModel.currentTime))")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(.textMuted)
                    .frame(width: 40, alignment: .leading)
                    .padding(.leading, 12)

                // ── Right cluster: volume + speed ─────────────────────
                HStack(spacing: 8) {
                    // Volume toggle
                    CinemaPlayerButton(icon: volumeIcon, size: 34) {
                        viewModel.toggleMute()
                    }

                    // Speed pill — accent tint when not 1×
                    Button { cycleSpeed() } label: {
                        Text("\(viewModel.playbackSpeed, specifier: viewModel.playbackSpeed == 1.0 ? "%.0f" : "%.1f")×")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundColor(isSpeedActive ? .accentPrimary : .textMuted)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(
                                Capsule()
                                    .fill(isSpeedActive
                                          ? Color.accentPrimary.opacity(0.14)
                                          : Color.primary.opacity(0.07))
                            )
                            .overlay(
                                Capsule()
                                    .stroke(isSpeedActive
                                            ? Color.accentPrimary.opacity(0.30)
                                            : Color.clear,
                                            lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .animation(.easeOut(duration: 0.2), value: isSpeedActive)
                }
                .padding(.leading, 16)
                .padding(.trailing, 28)
            }
            .padding(.vertical, 14)
            .background(
                ZStack {
                    // Frosted glass base
                    Rectangle()
                        .fill(.ultraThinMaterial)

                    // Subtle top-to-bottom gradient wash
                    LinearGradient(
                        colors: [Color.accentPrimary.opacity(0.04), Color.clear],
                        startPoint: .top, endPoint: .bottom
                    )
                }
            )
        }
    }

    private var volumeIcon: String {
        if viewModel.isMuted || viewModel.volume == 0 { return "speaker.slash.fill" }
        if viewModel.volume < 0.33 { return "speaker.wave.1.fill" }
        if viewModel.volume < 0.66 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    private func cycleSpeed() {
        if let i = speeds.firstIndex(of: viewModel.playbackSpeed) {
            viewModel.setPlaybackSpeed(speeds[(i + 1) % speeds.count])
        } else {
            viewModel.setPlaybackSpeed(1.0)
        }
    }
}

// MARK: - Cinema Player Button (Minimal glass style)
struct CinemaPlayerButton: View {
    let icon: String
    let size: CGFloat
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size * 0.4, weight: .medium))
                .foregroundColor(isHovered ? .textPrimary : .textSecondary)
                .frame(width: size, height: size)
                .background(
                    RoundedRectangle(cornerRadius: size * 0.25)
                        .fill(isHovered ? Color.bgHover : Color.bgElevated)
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
// MARK: - Enhanced Waveform Bars (with animation)
struct EnhancedWaveformBars: View {
    let count: Int
    let baseOpacity: Double
    let isPlaying: Bool
    let phase: Double
    
    private let barWidth: CGFloat = 3
    private let minSpacing: CGFloat = 2
    
    var body: some View {
        GeometryReader { geo in
            let actualCount = calculateBarCount(for: geo.size.width)
            let spacing = calculateSpacing(for: geo.size.width, barCount: actualCount)
            
            HStack(spacing: spacing) {
                ForEach(0..<actualCount, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1.5)
                        .frame(width: barWidth, height: barHeight(for: index))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .center)
        }
    }
    
    private func calculateBarCount(for totalWidth: CGFloat) -> Int {
        // Calculate how many bars fit with minimum spacing
        let barsWithSpacing = (totalWidth + minSpacing) / (barWidth + minSpacing)
        return max(count, Int(barsWithSpacing))
    }
    
    private func calculateSpacing(for totalWidth: CGFloat, barCount: Int) -> CGFloat {
        // Distribute remaining space evenly
        let totalBarWidth = CGFloat(barCount) * barWidth
        let remainingSpace = totalWidth - totalBarWidth
        return max(1, remainingSpace / CGFloat(barCount - 1))
    }
    
    private func barHeight(for index: Int) -> CGFloat {
        let x = Double(index)
        // Base wave pattern
        let h1 = sin(x * 0.3) * 8
        let h2 = cos(x * 0.5) * 5
        let h3 = sin(x * 0.7) * 4
        
        // Animation wave when playing
        let animationOffset: Double = isPlaying ? sin(x * 0.4 + phase) * 3 : 0
        
        return CGFloat(max(6, 16 + h1 + h2 + h3 + animationOffset))
    }
}

// MARK: - Transcript Content
struct TranscriptContentView: View {
    @EnvironmentObject var viewModel: TranscriptionViewModel
    @Environment(\.responsiveMetrics) private var metrics
    let searchText: String
    let showTimestamps: Bool
    var cascadeProgress: Double = 1.0

    // Drive the morph transition
    @State private var displayTimestamps: Bool = true
    @State private var morphOpacity: Double = 1.0
    @State private var morphBlur: CGFloat = 0
    @State private var morphScale: CGFloat = 1.0
    
    // Track active segment based on audio playback position
    private var activeSegmentId: UUID? {
        guard let result = viewModel.transcriptionResult,
              viewModel.isPlaying || viewModel.currentTime > 0 else { return nil }
        
        // Find segment that contains current playback time
        return result.segments.first(where: { segment in
            viewModel.currentTime >= segment.startTime && viewModel.currentTime < segment.endTime
        })?.id
    }
    
    // Search match indices for highlighting
    private var searchMatches: Set<UUID> {
        guard !searchText.isEmpty, let result = viewModel.transcriptionResult else { return [] }
        let query = searchText.lowercased()
        return Set(result.segments.filter { $0.text.lowercased().contains(query) }.map { $0.id })
    }
    
    // First search match for scroll
    private var firstMatchId: UUID? {
        guard !searchText.isEmpty, let result = viewModel.transcriptionResult else { return nil }
        let query = searchText.lowercased()
        return result.segments.first(where: { $0.text.lowercased().contains(query) })?.id
    }
    
    // Calculate visibility for staggered cascade animation
    private func cascadeOpacity(for index: Int, totalCount: Int) -> Double {
        guard cascadeProgress < 1.0 else { return 1.0 }
        
        // Each segment has a delay based on its index
        // First 10 segments appear within the cascade duration
        let maxVisibleIndex = min(10, totalCount)
        let normalizedIndex = Double(min(index, maxVisibleIndex)) / Double(maxVisibleIndex)
        
        // Calculate when this segment should start appearing
        let segmentStartProgress = normalizedIndex * 0.6  // Stagger over 60% of the animation
        
        // Calculate opacity based on current progress
        if cascadeProgress < segmentStartProgress {
            return 0
        } else {
            let segmentProgress = (cascadeProgress - segmentStartProgress) / 0.4
            return min(1, segmentProgress)
        }
    }
    
    private func cascadeOffset(for index: Int, totalCount: Int) -> CGFloat {
        let opacity = cascadeOpacity(for: index, totalCount: totalCount)
        return (1 - opacity) * 20  // Slide up as it fades in
    }
    
    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    // Glass panel container
                    VStack(alignment: .leading, spacing: 0) {
                        if let result = viewModel.transcriptionResult, !result.segments.isEmpty {
                            let visible = viewModel.visibleSegments
                            let segmentCount = visible.count

                            ZStack(alignment: .topLeading) {
                                // Timestamp mode always uses segment rows.
                                // In no-timestamp mode, edit mode also uses segment rows to keep inline editing behavior.
                                if displayTimestamps || viewModel.isEditMode {
                                    VStack(alignment: .leading, spacing: 0) {
                                        ForEach(Array(visible.enumerated()), id: \.element.id) { index, segment in
                                            CinemaSegmentRow(
                                                segment: segment,
                                                isFirst: index == 0,
                                                searchText: searchText,
                                                showTimestamps: displayTimestamps,
                                                isActive: segment.id == activeSegmentId,
                                                isSearchMatch: searchMatches.contains(segment.id),
                                                isEditMode: viewModel.isEditMode,
                                                onActivate: {
                                                    viewModel.setActiveSegmentForActions(segment.id)
                                                },
                                                onTap: {
                                                    viewModel.seek(to: segment.startTime)
                                                    if !viewModel.isPlaying { viewModel.togglePlayback() }
                                                },
                                                onTextEdit: { newText in
                                                    viewModel.updateSegmentText(segmentId: segment.id, newText: newText)
                                                },
                                                onCopy: { mode in
                                                    viewModel.copySegment(id: segment.id, mode: mode)
                                                },
                                                onToggleFavorite: {
                                                    viewModel.toggleSegmentFavorite(id: segment.id)
                                                },
                                                onRestoreOriginal: {
                                                    viewModel.restoreOriginalSegmentText(id: segment.id)
                                                },
                                                onUndoLastEdit: {
                                                    viewModel.undoLastSegmentEdit(id: segment.id)
                                                },
                                                onDelete: {
                                                    viewModel.deleteSegment(id: segment.id)
                                                }
                                            )
                                            .id(segment.id)
                                            .opacity(cascadeOpacity(for: index, totalCount: segmentCount))
                                            .offset(y: cascadeOffset(for: index, totalCount: segmentCount))
                                        }
                                    }
                                    .transition(.identity) // ZStack handles it
                                } else {
                                    // Read mode without timestamps keeps the document-style layout.
                                    CinemaDocumentModeView(
                                        segments: visible,
                                        searchText: searchText,
                                        activeSegmentId: activeSegmentId,
                                        availableWidth: max(100, min(700, geometry.size.width - 80))
                                    ) { time in
                                        viewModel.seek(to: time)
                                        if !viewModel.isPlaying { viewModel.togglePlayback() }
                                    }
                                    .opacity(cascadeProgress)
                                    .transition(.identity)
                                }
                            }
                            .opacity(morphOpacity)
                            .blur(radius: morphBlur)
                            .scaleEffect(morphScale, anchor: .top)

                        } else {
                            // Plain text fallback
                            Text(viewModel.transcriptionText)
                                .font(.transcriptBody)
                                .foregroundColor(.textPrimary)
                                .lineSpacing(8)
                                .textSelection(.enabled)
                                .padding(28)
                                .opacity(cascadeProgress)
                        }
                    }
                    .frame(width: max(100, min(720, geometry.size.width - 48)), alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 16)
                    .padding(.horizontal, metrics.viewerHPadding)
                    .padding(.bottom, 24)
                }
                .clipped()
                .onChange(of: activeSegmentId) { newId in
                    if let id = newId {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                }
                .onChange(of: searchText) { _ in
                    if let id = firstMatchId {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                }
            }
        }
        .onAppear {
            displayTimestamps = showTimestamps
        }
        .onChange(of: showTimestamps) { newValue in
            // Phase 1: fade + blur + scale down
            withAnimation(.easeIn(duration: 0.1)) {
                morphOpacity = 0
                morphBlur    = 6
                morphScale   = 0.97
            }
            // Phase 2: swap content + fade + unblur + scale up
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                displayTimestamps = newValue
                withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                    morphOpacity = 1
                    morphBlur    = 0
                    morphScale   = 1.0
                }
            }
        }
    }
}

// MARK: - Paragraph Model
struct Paragraph: Identifiable {
    let id = UUID()
    let segments: [TranscriptionSegment]
    let speaker: Int?
    
    var text: String {
        segments.map { $0.text.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
    }
}

// MARK: - Paragraph Builder (Smart Merging Algorithm)
enum ParagraphBuilder {
    /// Build paragraphs from segments using punctuation and speaker changes
    static func build(from segments: [TranscriptionSegment]) -> [Paragraph] {
        guard !segments.isEmpty else { return [] }
        
        var paragraphs: [Paragraph] = []
        var currentSegments: [TranscriptionSegment] = []
        var currentSpeaker: Int? = segments.first?.speaker
        
        for segment in segments {
            let text = segment.text.trimmingCharacters(in: .whitespaces)
            
            // Check if speaker changed - force new paragraph
            if segment.speaker != currentSpeaker && !currentSegments.isEmpty {
                paragraphs.append(Paragraph(segments: currentSegments, speaker: currentSpeaker))
                currentSegments = []
                currentSpeaker = segment.speaker
            }
            
            currentSegments.append(segment)
            
            // Check if this segment ends a sentence
            if endsWithSentenceTerminator(text) {
                paragraphs.append(Paragraph(segments: currentSegments, speaker: currentSpeaker))
                currentSegments = []
            }
        }
        
        // Add remaining segments as final paragraph
        if !currentSegments.isEmpty {
            paragraphs.append(Paragraph(segments: currentSegments, speaker: currentSpeaker))
        }
        
        return paragraphs
    }
    
    /// Check if text ends with sentence-ending punctuation
    private static func endsWithSentenceTerminator(_ text: String) -> Bool {
        let terminators: [Character] = [".", "!", "?", "。", "！", "？"]
        guard let lastChar = text.last else { return false }
        return terminators.contains(lastChar)
    }
}

// MARK: - Paragraph View (Editorial - No Background Boxes)
struct ParagraphView: View {
    @EnvironmentObject var localizationManager: LocalizationManager
    let paragraph: Paragraph
    let searchText: String
    let activeSegmentId: UUID?
    let availableWidth: CGFloat
    let onSeek: (TimeInterval) -> Void
    
    @State private var isHovered = false
    
    // Check if any segment in paragraph matches search
    private var hasSearchMatch: Bool {
        guard !searchText.isEmpty else { return false }
        let query = searchText.lowercased()
        return paragraph.segments.contains { $0.text.lowercased().contains(query) }
    }
    
    // Check if any segment in paragraph is active
    private var isActive: Bool {
        paragraph.segments.contains { $0.id == activeSegmentId }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Speaker label (if diarization) - subtle, not distracting
            if let speaker = paragraph.speaker {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.speakerColor(speaker))
                        .frame(width: 6, height: 6)
                    
                    Text(String(
                        format: localizationManager.text("transcript.speakerLabel", fallback: "Speaker %d"),
                        speaker + 1
                    ))
                        .font(.labelMedium)
                        .foregroundColor(Color.speakerColor(speaker).opacity(0.8))
                }
                .padding(.bottom, 2)
            }
            
            // Paragraph text - clickable to seek to start of paragraph
            Text(buildAttributedString())
                .font(.documentBody)
                .foregroundColor(textColor)
                .lineSpacing(10)
                .textSelection(.enabled)
                .frame(maxWidth: availableWidth, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .onHover { hovering in
                    withAnimation(.easeOut(duration: 0.15)) {
                        isHovered = hovering
                    }
                }
                .cursor(isHovered ? .pointingHand : .arrow)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            // Seek to first segment of paragraph
            if let firstSegment = paragraph.segments.first {
                onSeek(firstSegment.startTime)
            }
        }
        .padding(.vertical, 4)
    }
    
    // Text color based on state
    private var textColor: Color {
        if isActive {
            return .textEditorialActive
        } else if isHovered {
            return .white
        }
        return .textEditorial
    }
    
    // Build attributed string for the entire paragraph
    private func buildAttributedString() -> AttributedString {
        var result = AttributedString()
        
        for (index, segment) in paragraph.segments.enumerated() {
            var text = AttributedString(segment.text.trimmingCharacters(in: .whitespaces))
            
            // Add space between segments
            if index < paragraph.segments.count - 1 {
                text.append(AttributedString(" "))
            }
            
            // Apply highlighting for search matches
            if !searchText.isEmpty && segment.text.lowercased().contains(searchText.lowercased()) {
                text.backgroundColor = .yellow.opacity(0.3)
            }
            
            result.append(text)
        }
        
        return result
    }
}

// MARK: - Cinema Document Mode View (Glassmorphism Reading Mode)
struct CinemaDocumentModeView: View {
    let segments: [TranscriptionSegment]
    let searchText: String
    let activeSegmentId: UUID?
    let availableWidth: CGFloat
    let onSeek: (TimeInterval) -> Void
    
    private var paragraphs: [Paragraph] {
        ParagraphBuilder.build(from: segments)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            ForEach(paragraphs) { paragraph in
                CinemaParagraphView(
                    paragraph: paragraph,
                    searchText: searchText,
                    activeSegmentId: activeSegmentId,
                    availableWidth: availableWidth - 48,
                    onSeek: onSeek
                )
                .id(paragraph.segments.first?.id)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }
}

// MARK: - Cinema Paragraph View (White text on dark)
struct CinemaParagraphView: View {
    @EnvironmentObject var localizationManager: LocalizationManager
    let paragraph: Paragraph
    let searchText: String
    let activeSegmentId: UUID?
    let availableWidth: CGFloat
    let onSeek: (TimeInterval) -> Void
    
    @State private var isHovered = false
    
    private var isActive: Bool {
        paragraph.segments.contains { $0.id == activeSegmentId }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Speaker label with subtle glass pill
            if let speaker = paragraph.speaker {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.speakerColor(speaker))
                        .frame(width: 6, height: 6)
                    
                    Text(String(
                        format: localizationManager.text("transcript.speakerLabel", fallback: "Speaker %d"),
                        speaker + 1
                    ))
                        .font(.labelMedium)
                        .foregroundColor(Color.speakerColor(speaker).opacity(0.9))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(Color.speakerColor(speaker).opacity(0.15))
                )
            }
            
            // Paragraph text - white on dark
            Text(buildAttributedString())
                .font(.system(size: 17, weight: .regular))
                .foregroundColor(textColor)
                .lineSpacing(12)
                .textSelection(.enabled)
                .frame(maxWidth: availableWidth, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .onHover { hovering in
                    withAnimation(.easeOut(duration: 0.15)) {
                        isHovered = hovering
                    }
                }
                .cursor(isHovered ? .pointingHand : .arrow)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if let firstSegment = paragraph.segments.first {
                onSeek(firstSegment.startTime)
            }
        }
        .padding(.vertical, 4)
    }
    
    private var textColor: Color {
        if isActive {
            return .accentPrimary
        }
        return .textPrimary
    }

    private func buildAttributedString() -> AttributedString {
        var result = AttributedString()

        for (index, segment) in paragraph.segments.enumerated() {
            var text = AttributedString(segment.text.trimmingCharacters(in: .whitespaces))

            if index < paragraph.segments.count - 1 {
                text.append(AttributedString(" "))
            }

            if !searchText.isEmpty && segment.text.lowercased().contains(searchText.lowercased()) {
                text.backgroundColor = Color.accentPrimary.opacity(0.3)
            }

            result.append(text)
        }

        return result
    }
}

// MARK: - Cinema Segment Row (For timestamp mode)
struct CinemaSegmentRow: View {
    @EnvironmentObject var localizationManager: LocalizationManager
    let segment: TranscriptionSegment
    let isFirst: Bool
    let searchText: String
    let showTimestamps: Bool
    let isActive: Bool
    let isSearchMatch: Bool
    let isEditMode: Bool
    let onActivate: () -> Void
    let onTap: () -> Void
    let onTextEdit: (String) -> Void
    let onCopy: (TranscriptionViewModel.SegmentCopyMode) -> Void
    let onToggleFavorite: () -> Void
    let onRestoreOriginal: () -> Void
    let onUndoLastEdit: () -> Void
    let onDelete: () -> Void
    
    @State private var isHovered = false
    @State private var isEditing = false
    @State private var editText = ""
    @FocusState private var isTextFocused: Bool
    
    private var formattedTime: String {
        segment.formattedStartTime
    }

    private var isSpanishUI: Bool {
        localizationManager.appLanguage == .es
    }

    private func localized(_ spanish: String, _ english: String) -> String {
        isSpanishUI ? spanish : english
    }

    private func commitEditing() {
        if editText != segment.text {
            onTextEdit(editText)
        }
        isEditing = false
    }

    private func cancelEditing() {
        editText = segment.text
        isEditing = false
    }
    
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            // Favorite indicator
            if segment.isFavorite {
                Image(systemName: "star.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.yellow)
            }

            // Edited indicator
            if segment.originalText != nil {
                Image(systemName: "pencil")
                    .font(.system(size: 10))
                    .foregroundColor(.textMuted)
            }
            
            // Timestamp pill
            if showTimestamps {
                Button {
                    onActivate()
                    onTap()
                } label: {
                    Text(formattedTime)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(isActive ? .accentPrimary : .textMuted)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(isActive ? Color.accentPrimary.opacity(0.15) : Color.bgElevated)
                        )
                }
                .buttonStyle(.plain)
            }
            
            // Segment text
            if isEditing && isEditMode {
                TextField("", text: $editText, axis: .vertical)
                    .font(.bodyXLarge)
                    .foregroundColor(.white)
                    .textFieldStyle(.plain)
                    .focused($isTextFocused)
                    .onSubmit {
                        commitEditing()
                    }
                    .onExitCommand {
                        cancelEditing()
                    }
                    .onChange(of: isTextFocused) { focused in
                        guard isEditing else { return }
                        if !focused {
                            commitEditing()
                        }
                    }
            } else if isEditMode {
                // Edit mode: single click starts inline editing (no playback on text tap)
                Text(segment.text)
                    .font(.bodyXLarge)
                    .foregroundColor(textColor)
                    .lineSpacing(8)
                    .onTapGesture {
                        onActivate()
                        editText = segment.text
                        isEditing = true
                        isTextFocused = true
                    }
            } else {
                // Read mode: row click should play this segment
                Text(segment.text)
                    .font(.bodyXLarge)
                    .foregroundColor(textColor)
                    .lineSpacing(8)
                    .textSelection(.enabled)
            }
            
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(
                    isActive ? Color.accentPrimary.opacity(0.1) :
                    (isHovered ? Color.bgHover : Color.clear)
                )
        )
        .onTapGesture {
            if !isEditMode && !isEditing {
                onActivate()
                onTap()
            }
        }
        .overlay(
            // Favorite accent border
            segment.isFavorite ?
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.yellow.opacity(0.3), lineWidth: 1)
            : nil
        )
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.1)) {
                isHovered = hovering
            }
        }
        .onChange(of: isEditMode) { newValue in
            // Enforce hard boundary: read mode must never remain editable.
            if !newValue && isEditing {
                cancelEditing()
                isTextFocused = false
            }
        }
        .onDisappear {
            if isEditing {
                if isEditMode {
                    commitEditing()
                } else {
                    cancelEditing()
                }
            }
        }
        .contextMenu {
            Section {
                Button {
                    onActivate()
                    onCopy(.textOnly)
                } label: {
                    Label(localized("Copiar texto", "Copy Text"), systemImage: "doc.on.doc")
                }
                Button {
                    onActivate()
                    onCopy(.withTimestamp)
                } label: {
                    Label(localized("Copiar con timestamp", "Copy with Timestamp"), systemImage: "clock")
                }
                Button {
                    onActivate()
                    onCopy(.withTimestampAndSpeaker)
                } label: {
                    Label(localized("Copiar con speaker", "Copy with Speaker"), systemImage: "person")
                }
            }

            if isEditMode {
                Section {
                    if !segment.editHistory.isEmpty {
                        Button {
                            onActivate()
                            onUndoLastEdit()
                        } label: {
                            Label(localized("Deshacer última edición", "Undo Last Edit"), systemImage: "arrow.uturn.backward")
                        }
                    }
                    if segment.originalText != nil {
                        Button {
                            onActivate()
                            onRestoreOriginal()
                        } label: {
                            Label(localized("Restaurar texto original", "Restore Original Text"), systemImage: "clock.arrow.circlepath")
                        }
                    }
                }

                Section {
                    Button {
                        onActivate()
                        onToggleFavorite()
                    } label: {
                        Label(
                            segment.isFavorite
                                ? localized("Quitar favorito", "Unfavorite")
                                : localized("Favorito", "Favorite"),
                            systemImage: segment.isFavorite ? "star.slash" : "star"
                        )
                    }
                }

                Section {
                    Button(role: .destructive) {
                        onActivate()
                        onDelete()
                    } label: {
                        Label(localized("Eliminar segmento", "Delete Segment"), systemImage: "trash")
                    }
                }
            }
        }
    }
    
    private var textColor: Color {
        if isActive {
            return .white
        } else if isSearchMatch {
            return .accentPrimary
        }
        return .white
    }
}

// MARK: - Conditional View Modifier
extension View {
    @ViewBuilder
    func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}

// MARK: - Cursor Modifier for macOS
extension View {
    func cursor(_ cursor: NSCursor) -> some View {
        self.onHover { hovering in
            if hovering {
                cursor.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}

// MARK: - Highlighted Text View (Yellow search highlights)
struct HighlightedTextView: View {
    let text: String
    let highlight: String
    
    var body: some View {
        highlightedText
    }
    
    private var highlightedText: Text {
        guard !highlight.isEmpty else {
            return Text(text)
        }
        
        let lowercasedText = text.lowercased()
        let lowercasedHighlight = highlight.lowercased()
        
        var result = Text("")
        var currentIndex = text.startIndex
        
        while let range = lowercasedText[currentIndex...].range(of: lowercasedHighlight) {
            // Add text before match
            let beforeRange = currentIndex..<range.lowerBound
            if !beforeRange.isEmpty {
                result = result + Text(String(text[beforeRange]))
            }
            
            // Add highlighted match with yellow background using AttributedString
            let matchedText = String(text[range])
            var attributedMatch = AttributedString(matchedText)
            attributedMatch.backgroundColor = .yellow.opacity(0.6)
            attributedMatch.foregroundColor = .black
            result = result + Text(attributedMatch)
            
            currentIndex = range.upperBound
        }
        
        // Add remaining text
        if currentIndex < text.endIndex {
            result = result + Text(String(text[currentIndex...]))
        }
        
        return result
    }
}

// MARK: - Empty State View
// MARK: - Transcription Progress Indicator (Split View Glassmorphism Design)
struct TranscriptionProgressIndicator: View {
    @EnvironmentObject var viewModel: TranscriptionViewModel
    @EnvironmentObject var localizationManager: LocalizationManager
    @Environment(\.responsiveMetrics) private var metrics
    
    // Animation states
    @State private var breatheScale: CGFloat = 1.0
    @State private var glowOpacity: Double = 0.3
    @State private var backgroundRotation: Double = 0
    @State private var isCompleting = false
    @State private var showTechLogs = false
    @State private var wavePhase: Double = 0
    @State private var waveAmplitude: Double = 0.5
    
    // Cinema entrance animation states (Metamorphosis)
    @State private var cardScale: CGFloat = 0.85
    @State private var cardOpacity: Double = 0
    @State private var leftPanelOffset: CGFloat = -40
    @State private var leftPanelOpacity: Double = 0
    @State private var rightPanelOpacity: Double = 0
    @State private var hasAnimatedIn = false
    
    // Streaming text from ViewModel
    @State private var displayedText: String = ""
    @State private var textHighlightEnd: Int = 0
    @State private var previousTextLength: Int = 0
    
    // Smart auto-scroll
    @State private var autoScrollEnabled: Bool = true
    @State private var contentHeight: CGFloat = 0
    @State private var containerHeight: CGFloat = 0
    
    // Hover states
    @State private var cancelHovered = false
    @State private var logsHovered = false
    
    private var progressFraction: CGFloat {
        CGFloat(viewModel.progress) / 100.0
    }
    
    // Format time as MM:SS
    private func formatTime(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%02d:%02d", mins, secs)
    }
    
    // Format file size
    private func formatFileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
    
    // Estimated time remaining
    private var estimatedTimeRemaining: String {
        guard viewModel.processingSpeed > 0, viewModel.progress > 5 else { return "--:--" }
        let remainingAudio = viewModel.totalAudioDuration - viewModel.processedAudioDuration
        let remainingTime = remainingAudio / viewModel.processingSpeed
        return formatTime(remainingTime)
    }
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // === LAYER 0: Shared app background ===
                Color.bgPrimary
                    .ignoresSafeArea()
                
                // === LAYER 1: Giant Audio Wave (The Pulse) ===
                CinemaWaveView(phase: wavePhase, amplitude: waveAmplitude)
                    .opacity(0.08 * cardOpacity) // Fade in with card
                    .blur(radius: 30)
                
                // === LAYER 2: Radial Glow (The Light) ===
                cinemaLighting(in: geometry.size)
                    .scaleEffect(0.8 + (0.3 * cardOpacity)) // Expand with card
                
                // === LAYER 3: Glass Panel (The Crystal) - METAMORPHOSIS ===
                splitViewGlassPanel
                    .frame(
                        width: geometry.size.width * metrics.viewerWidthRatio,
                        height: geometry.size.height * metrics.viewerHeightRatio
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // Cinema entrance: scale + fade
                    .scaleEffect(cardScale)
                    .opacity(cardOpacity)
                
                // === LAYER 4: Overlays ===
                if showTechLogs {
                    techLogsOverlay
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            triggerCinemaEntrance()
            startAnimations()
            // Restore any already-accumulated streaming text when returning from background
            if displayedText.isEmpty && !viewModel.streamingText.isEmpty {
                displayedText = viewModel.streamingText
                previousTextLength = displayedText.count
                textHighlightEnd = displayedText.count
            }
        }
        .onChange(of: viewModel.progress) { newValue in
            // Animate wave amplitude based on progress
            withAnimation(.easeOut(duration: 0.5)) {
                waveAmplitude = newValue > 5 ? 0.7 : 0.3
            }
            if newValue >= 100 {
                withAnimation(.easeOut(duration: 0.5)) {
                    isCompleting = true
                }
            }
        }
        .onChange(of: viewModel.streamingText) { newText in
            updateStreamingText(newText: newText)
            // Pulse wave when new text arrives
            withAnimation(.easeOut(duration: 0.3)) {
                waveAmplitude = 1.0
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                withAnimation(.easeOut(duration: 1.0)) {
                    waveAmplitude = 0.6
                }
            }
        }
    }
    
    // MARK: - Cinema Lighting (Layer 2)
    private func cinemaLighting(in size: CGSize) -> some View {
        ZStack {
            // Primary ambient glow — same palette as Home
            RadialGradient(
                colors: [
                    Color.accentPrimary.opacity(glowOpacity * 0.45),
                    Color.accentPrimary.opacity(glowOpacity * 0.20),
                    Color.clear
                ],
                center: .center,
                startRadius: 50,
                endRadius: min(size.width, size.height) * 0.75
            )
            .blur(radius: 130)

            // Secondary offset glow
            RadialGradient(
                colors: [
                    Color.accentSecondary.opacity(glowOpacity * 0.22),
                    Color.clear
                ],
                center: UnitPoint(x: 0.28, y: 0.62),
                startRadius: 0,
                endRadius: 420
            )
            .blur(radius: 110)
        }
        .scaleEffect(breatheScale * 1.1)
    }
    
    // MARK: - Split View Glass Panel
    private var splitViewGlassPanel: some View {
        VStack(spacing: 0) {
            // ── Top header bar ─────────────────────────────────────────────
            processingHeaderBar

            // Thin horizontal rule
            Rectangle()
                .fill(Color.borderSubtle)
                .frame(height: 1)

            // ── Split columns ──────────────────────────────────────────────
            HStack(spacing: 0) {
                // Left Column (30%) - Control Panel
                leftControlPanel
                    .frame(maxWidth: .infinity)
                    .layoutPriority(0.3)
                    .offset(x: leftPanelOffset)
                    .opacity(leftPanelOpacity)

                // Vertical Divider
                Rectangle()
                    .fill(Color.borderSubtle)
                    .frame(width: 1)
                    .opacity(leftPanelOpacity)

                // Right Column (70%) - Text Canvas
                rightTextCanvas
                    .frame(maxWidth: .infinity)
                    .layoutPriority(0.7)
                    .opacity(rightPanelOpacity)
            }
        }
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 28)
                    .fill(Color.bgSecondary.opacity(0.62))

                RoundedRectangle(cornerRadius: 28)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.primary.opacity(0.04),
                                Color.clear,
                                Color.accentPrimary.opacity(0.02)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 28)
                .stroke(Color.borderSubtle, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.18), radius: 40, x: 0, y: 16)
        .shadow(color: Color.accentPrimary.opacity(0.07), radius: 60, x: 0, y: 10)
    }

    // MARK: - Processing Header Bar
    private var processingHeaderBar: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                // File name
                VStack(alignment: .leading, spacing: 3) {
                    Text(viewModel.selectedFile?.name ?? localizationManager.text("transcript.processing.fileFallback", fallback: "Processing..."))
                        .font(.titleMedium)
                        .foregroundColor(.textPrimary)
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        Image(systemName: currentStep.icon)
                            .font(.system(size: 11))
                            .foregroundColor(.accentPrimary)
                        Text(currentStep.narrative(localizationManager: localizationManager))
                            .font(.bodySmall)
                            .foregroundColor(.textMuted)
                    }
                }

                Spacer()

                // Progress percentage badge
                Text("\(viewModel.progress)%")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(.accentPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(Color.accentPrimary.opacity(0.12))
                    )
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 18)

            // Thin progress bar spanning full width
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    // Track
                    Rectangle()
                        .fill(Color.borderSubtle)
                        .frame(height: 2)

                    // Fill
                    Rectangle()
                        .fill(Color.gradientBrand)
                        .frame(width: geo.size.width * CGFloat(viewModel.progress) / 100, height: 2)
                        .animation(.easeOut(duration: 0.4), value: viewModel.progress)
                }
            }
            .frame(height: 2)
        }
    }
    
    // MARK: - Current Processing Step
    private var currentStep: ProcessingStep {
        ProcessingStep.from(progress: viewModel.progress, status: viewModel.statusMessage)
    }
    
    // MARK: - Left Control Panel (30%)
    private var leftControlPanel: some View {
        VStack(spacing: 0) {
            // Large Progress Circle - Hero element
            progressCircle
                .padding(.top, 32)
                .padding(.bottom, 20)
            
            // Status Message - Prominent
            statusSection
                .padding(.horizontal, 28)
                .padding(.bottom, 28)
            
            // Divider
            Rectangle()
                .fill(Color.borderSubtle)
                .frame(height: 1)
                .padding(.horizontal, 20)
            
            // Metrics Section
            metricsSection
                .padding(.horizontal, 28)
                .padding(.top, 20)
                .padding(.bottom, 20)
            
            // Divider
            Rectangle()
                .fill(Color.borderSubtle)
                .frame(height: 1)
                .padding(.horizontal, 20)
            
            // File Info Section
            fileInfoSection
                .padding(.horizontal, 28)
                .padding(.top, 20)
            
            Spacer()
            
            // Bottom: Logs & Cancel
            bottomControlsLeft
                .padding(.horizontal, 28)
                .padding(.bottom, 32)
        }
        .frame(maxHeight: .infinity)
    }
    
    // MARK: - Status Section (What's happening now)
    private var statusSection: some View {
        let isComplete = viewModel.progress >= 100
        
        return VStack(spacing: 12) {
            // Current phase with icon
            HStack(spacing: 10) {
                // Animated icon - changes to checkmark on complete
                ZStack {
                    Circle()
                        .fill((isComplete ? Color(hex: "#00D4FF") : Color.accentPrimary).opacity(0.15))
                        .frame(width: 36, height: 36)
                        .scaleEffect(isComplete ? 1.1 : breatheScale)
                    
                    Image(systemName: isComplete ? "checkmark" : currentStep.icon)
                        .font(.system(size: 16, weight: isComplete ? .bold : .regular))
                        .foregroundColor(isComplete ? Color(hex: "#00D4FF") : .accentPrimary)
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(
                        isComplete
                            ? localizationManager.text("transcript.processing.completed", fallback: "Transcription completed!")
                            : currentStep.narrative(localizationManager: localizationManager)
                    )
                        .font(.labelDefault)
                        .foregroundColor(isComplete ? Color(hex: "#00D4FF") : .textPrimary)
                        .lineLimit(1)

                    // Time elapsed
                    Text(
                        isComplete
                            ? localizationManager.text("transcript.processing.preparingResult", fallback: "Preparing result...")
                            : String(
                                format: localizationManager.text("transcript.processing.elapsed", fallback: "%@ processed"),
                                formatTime(viewModel.processedAudioDuration)
                            )
                    )
                        .font(.bodySmall)
                        .foregroundColor(.textMuted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .animation(.easeOut(duration: 0.3), value: isComplete)
    }
    
    // MARK: - Progress Circle (Large)
    private var progressCircle: some View {
        let isComplete = viewModel.progress >= 100
        
        return ZStack {
            // Glow aura - changes to green/cyan on completion
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            (isComplete ? Color(hex: "#00D4FF") : Color.accentPrimary).opacity(glowOpacity * (isComplete ? 0.6 : 0.35)),
                            Color.clear
                        ],
                        center: .center,
                        startRadius: 50,
                        endRadius: 120
                    )
                )
                .frame(width: 220, height: 220)
                .scaleEffect(isComplete ? 1.2 : breatheScale)
                .animation(.easeOut(duration: 0.5), value: isComplete)
            
            // Background track
            Circle()
                .stroke(Color.borderSubtle, lineWidth: 8)
                .frame(width: 140, height: 140)
            
            // Progress arc with gradient - switches to green on complete
            Circle()
                .trim(from: 0, to: progressFraction)
                .stroke(
                    LinearGradient(
                        colors: isComplete 
                            ? [Color(hex: "#00D4FF"), Color(hex: "#00FF88"), Color(hex: "#00D4FF")]
                            : [.accentPrimary, .accentSecondary, .cyan],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    style: StrokeStyle(lineWidth: 8, lineCap: .round)
                )
                .frame(width: 140, height: 140)
                .rotationEffect(.degrees(-90))
                .shadow(color: isComplete ? Color(hex: "#00D4FF").opacity(0.6) : Color.clear, radius: 12)
                .animation(.easeOut(duration: 0.3), value: progressFraction)
            
            // Percentage in center
            VStack(spacing: 4) {
                Text("\(viewModel.progress)")
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                    .foregroundColor(.textPrimary)
                Text("%")
                    .font(.bodyXLarge)
                    .foregroundColor(.textMuted)
            }
        }
    }
    
    // MARK: - Metrics Section
    private var metricsSection: some View {
        VStack(spacing: 16) {
            // Speed
            metricRow(
                icon: "bolt.fill",
                iconColor: .accentPrimary,
                label: "Velocidad",
                value: viewModel.processingSpeed > 0 ? String(format: "%.1fx", viewModel.processingSpeed) : "--"
            )
            
            // Time Remaining
            metricRow(
                icon: "clock.fill",
                iconColor: .accentSecondary,
                label: "Tiempo restante",
                value: estimatedTimeRemaining
            )
            
            // Duration
            metricRow(
                icon: "waveform",
                iconColor: .cyan,
                label: "Duración",
                value: formatTime(viewModel.totalAudioDuration)
            )
        }
    }
    
    private func metricRow(icon: String, iconColor: Color, label: String, value: String) -> some View {
        HStack {
            // Icon
            Image(systemName: icon)
                .font(.bodySmall)
                .foregroundColor(iconColor)
                .frame(width: 20)
            
            // Label
            Text(label)
                .font(.bodyMedium)
                .foregroundColor(.textMuted)

            Spacer()

            // Value
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundColor(.textPrimary)
        }
    }
    
    // MARK: - File Info Section
    private var fileInfoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // File name
            if let file = viewModel.selectedFile {
                Text(file.name)
                    .font(.titleMedium)
                    .foregroundColor(.textPrimary)
                    .lineLimit(2)
            }
            
            // Technical metadata
            HStack(spacing: 12) {
                // Format
                if let file = viewModel.selectedFile {
                    Text(file.url.pathExtension.uppercased())
                        .font(.labelMedium)
                        .foregroundColor(.textTertiary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.bgElevated)
                        )

                    // File size
                    if let attrs = try? FileManager.default.attributesOfItem(atPath: file.url.path),
                       let size = attrs[.size] as? Int64 {
                        Text(formatFileSize(size))
                            .font(.caption)
                            .foregroundColor(.textTertiary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    
    // MARK: - Bottom Controls Left
    private var bottomControlsLeft: some View {
        VStack(spacing: 16) {
            // Back to Home button - Glass style
            Button {
                viewModel.minimizeToBackground()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Volver a inicio")
                        .font(.labelLarge)
                }
                .foregroundColor(.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.bgSecondary)
                )
            }
            .buttonStyle(.plain)
            
            // Logs button - Ghost text
            Button {
                withAnimation(.spring(response: 0.3)) {
                    showTechLogs.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "terminal")
                        .font(.caption)
                    Text("Ver logs")
                        .font(.labelLarge)
                }
                .foregroundColor(logsHovered ? .textPrimary : .textTertiary)
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                logsHovered = hovering
            }
            
            // Cancel — subtle text link (weight matches surrounding actions)
            Button {
                withAnimation(.spring(response: 0.55, dampingFraction: 0.88)) {
                    viewModel.cancelTranscription()
                }
            } label: {
                Text("Cancelar")
                    .font(.labelDefault)
                    .foregroundColor(cancelHovered ? Color(hex: "#FF6961") : .textMuted)
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.15)) {
                    cancelHovered = hovering
                }
            }
        }
    }
    
    // MARK: - Right Text Canvas (70%)
    private var rightTextCanvas: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        if displayedText.isEmpty {
                            // Waiting state - informative
                            VStack(spacing: 24) {
                                // Animated typing indicator
                                HStack(spacing: 8) {
                                    ForEach(0..<3) { i in
                                        Circle()
                                            .fill(Color.accentPrimary.opacity(0.6))
                                            .frame(width: 10, height: 10)
                                            .scaleEffect(breatheScale)
                                            .animation(
                                                .easeInOut(duration: 0.6)
                                                .repeatForever()
                                                .delay(Double(i) * 0.15),
                                                value: breatheScale
                                            )
                                    }
                                }
                                
                                VStack(spacing: 8) {
                                    Text(localizationManager.text("transcript.processing.audio", fallback: "Processing audio..."))
                                        .font(.system(size: 18, weight: .medium))
                                        .foregroundColor(.textSecondary)

                                    Text(localizationManager.text("transcript.processing.livePreviewHint", fallback: "Text will appear here as it is transcribed"))
                                        .font(.bodyDefault)
                                        .foregroundColor(.textMuted)
                                        .multilineTextAlignment(.center)
                                }
                                
                                // Phase indicator
                                HStack(spacing: 6) {
                                    Image(systemName: currentStep.icon)
                                        .font(.bodySmall)
                                        .foregroundColor(.accentSecondary)
                                    Text(currentStep.narrative(localizationManager: localizationManager))
                                        .font(.bodyMedium)
                                        .foregroundColor(.accentSecondary)
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(
                                    Capsule()
                                        .fill(Color.accentSecondary.opacity(0.1))
                                )
                            }
                            .frame(maxWidth: .infinity, minHeight: geo.size.height * 0.8)
                        } else {
                            // Streaming text - flows freely like a document
                            SplitViewStreamingText(
                                text: displayedText,
                                highlightEnd: textHighlightEnd
                            )
                            .id("streamingText")
                            .padding(.top, 48)
                            .padding(.bottom, 100)
                            .padding(.horizontal, 48)
                        }
                        
                        // Invisible scroll anchor
                        Color.clear
                            .frame(height: 1)
                            .id("bottom")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        GeometryReader { contentGeo in
                            Color.clear
                                .preference(key: ScrollOffsetPreferenceKey.self,
                                            value: contentGeo.frame(in: .named("textScrollArea")).minY)
                                .onChange(of: contentGeo.size.height) { newHeight in
                                    contentHeight = newHeight
                                }
                        }
                    )
                }
                .coordinateSpace(name: "textScrollArea")
                .onPreferenceChange(ScrollOffsetPreferenceKey.self) { offset in
                    let isAtBottom = offset < -(contentHeight - geo.size.height - 100)
                    if !isAtBottom && contentHeight > geo.size.height {
                        autoScrollEnabled = false
                    } else if isAtBottom {
                        autoScrollEnabled = true
                    }
                }
                .onChange(of: displayedText) { _ in
                    if autoScrollEnabled {
                        withAnimation(.easeOut(duration: 0.25)) {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    }
                }
            }
        }
    }
    
    // MARK: - Tech Logs Overlay
    private var techLogsOverlay: some View {
        ZStack {
            // Dim background
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation { showTechLogs = false }
                }
            
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "terminal.fill")
                        .foregroundColor(.green)
                    Text("Logs técnicos")
                        .font(.titleDefault)
                        .foregroundColor(.white)
                    
                    Spacer()
                    
                    Button {
                        withAnimation { showTechLogs = false }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.textMuted)
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(Color.bgSecondary))
                    }
                    .buttonStyle(.plain)
                }
                
                Divider().background(Color.borderSubtle)
                
                // Log entries
                VStack(alignment: .leading, spacing: 10) {
                    logRow("Modelo", value: viewModel.settings.selectedModelId)
                    logRow("Idioma", value: viewModel.settings.language)
                    logRow("Temperatura", value: String(format: "%.2f", viewModel.settings.temperature))
                    logRow(
                        "VAD",
                        value: viewModel.settings.useVAD
                            ? (localizationManager.appLanguage == .es
                                ? "Activo (\(String(format: "%.1f", viewModel.settings.vadThreshold)))"
                                : "Active (\(String(format: "%.1f", viewModel.settings.vadThreshold)))")
                            : (localizationManager.appLanguage == .es ? "Desactivado" : "Disabled")
                    )
                    logRow(
                        "CoreML",
                        value: viewModel.settings.useCoreML
                            ? (localizationManager.appLanguage == .es ? "Activo" : "Active")
                            : (localizationManager.appLanguage == .es ? "Desactivado" : "Disabled")
                    )
                    logRow("Progreso", value: "\(viewModel.progress)%")
                    logRow("Velocidad", value: String(format: "%.2fx", viewModel.processingSpeed))
                    logRow("Audio procesado", value: formatTime(viewModel.processedAudioDuration))
                }
            }
            .padding(24)
            .frame(width: metrics.techLogWidth)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(red: 0.08, green: 0.08, blue: 0.1).opacity(0.98))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Color.green.opacity(0.3), lineWidth: 1)
                    )
            )
            .shadow(color: .black.opacity(0.5), radius: 40)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.95)))
    }
    
    private func logRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.mono)
                .foregroundColor(.green.opacity(0.7))
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(.textPrimary)
        }
    }
    
    // MARK: - Helpers
    
    // Cinema Entrance Animation (Metamorphosis)
    private func triggerCinemaEntrance() {
        guard !hasAnimatedIn else { return }
        hasAnimatedIn = true
        
        // Entrada en bloque: una sola fase para priorizar legibilidad
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            withAnimation(.easeOut(duration: 0.32)) {
                cardScale = 1.0
                cardOpacity = 1.0
                leftPanelOffset = 0
                leftPanelOpacity = 1.0
                rightPanelOpacity = 1.0
            }
        }
    }
    
    private func startAnimations() {
        // Feedback útil: respiración suave + onda principal
        withAnimation(.easeInOut(duration: 3.2).repeatForever(autoreverses: true)) {
            breatheScale = 1.04
        }
        glowOpacity = 0.56
        withAnimation(.linear(duration: 10).repeatForever(autoreverses: false)) {
            wavePhase = .pi * 2
        }
        backgroundRotation = 0
    }
    
    private func updateStreamingText(newText: String) {
        previousTextLength = displayedText.count
        displayedText = newText
        
        let newCharsCount = newText.count - previousTextLength
        if newCharsCount > 0 {
            textHighlightEnd = previousTextLength
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                withAnimation(.easeOut(duration: 0.6)) {
                    textHighlightEnd = newText.count
                }
            }
        }
    }
}

// MARK: - Split View Streaming Text (Larger font, document-like)
struct SplitViewStreamingText: View {
    let text: String
    let highlightEnd: Int
    
    var body: some View {
        if text.isEmpty {
            EmptyView()
        } else {
            let chars = Array(text)
            let highlightIndex = min(highlightEnd, chars.count)
            
            // Text that's already typed (white)
            let normalPart = String(chars.prefix(highlightIndex))
            // Text currently being typed (cyan highlight)
            let highlightedPart = highlightIndex < chars.count ? String(chars.suffix(chars.count - highlightIndex)) : ""
            
            (
                Text(normalPart)
                    .font(.system(size: 20, weight: .regular))
                    .foregroundColor(.textPrimary)
                +
                Text(highlightedPart)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(.cyan)
            )
            .lineSpacing(10)
            .textSelection(.enabled)
        }
    }
}

// Preference key for scroll offset tracking
struct ScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Processing Step
enum ProcessingStep {
    case loading
    case separating
    case denoising
    case transcribing
    case formatting
    case finishing
    
    var icon: String {
        switch self {
        case .loading: return "arrow.down.circle"
        case .separating: return "person.2.wave.2"
        case .denoising: return "waveform.path.ecg"
        case .transcribing: return "text.bubble"
        case .formatting: return "doc.text"
        case .finishing: return "checkmark.circle"
        }
    }
    
    var emoji: String {
        switch self {
        case .loading: return "📥"
        case .separating: return "🎭"
        case .denoising: return "🌊"
        case .transcribing: return "🧠"
        case .formatting: return "✨"
        case .finishing: return "✅"
        }
    }
    
    @MainActor
    func narrative(localizationManager: LocalizationManager) -> String {
        switch self {
        case .loading:
            return localizationManager.text("transcript.step.loading", fallback: "Preparing file...")
        case .separating:
            return localizationManager.text("transcript.step.separating", fallback: "Separating voices with Demucs...")
        case .denoising:
            return localizationManager.text("transcript.step.denoising", fallback: "Cleaning background noise...")
        case .transcribing:
            return localizationManager.text("transcript.step.transcribing", fallback: "Transcribing with Whisper...")
        case .formatting:
            return localizationManager.text("transcript.step.formatting", fallback: "Polishing result...")
        case .finishing:
            return localizationManager.text("transcript.step.finishing", fallback: "Almost done!")
        }
    }
    
    static func from(progress: Int, status: String) -> ProcessingStep {
        let lowercased = status.lowercased()
        if lowercased.contains("demucs") || lowercased.contains("separando") || lowercased.contains("vocal") || lowercased.contains("aislando") {
            return .separating
        }
        if lowercased.contains("ruido") || lowercased.contains("deepfilter") || lowercased.contains("noise") || lowercased.contains("limpiando") {
            return .denoising
        }
        if lowercased.contains("transcrib") || lowercased.contains("whisper") {
            return .transcribing
        }
        if lowercased.contains("format") || lowercased.contains("puliendo") {
            return .formatting
        }
        
        switch progress {
        case 0..<5: return .loading
        case 5..<15: return .separating
        case 15..<30: return .denoising
        case 30..<85: return .transcribing
        case 85..<98: return .formatting
        default: return .finishing
        }
    }
}

// MARK: - Cinema Wave View (Giant Sinusoidal Wave)
struct CinemaWaveView: View {
    let phase: Double
    let amplitude: Double
    
    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                // Draw multiple layered waves for depth
                for layer in 0..<3 {
                    let layerOffset = Double(layer) * 0.4
                    let layerOpacity = 1.0 - (Double(layer) * 0.3)
                    let layerAmplitude = CGFloat(amplitude * (1.0 - Double(layer) * 0.2))
                    
                    var path = Path()
                    let waveHeight = size.height * 0.15 * layerAmplitude
                    let midY = size.height / 2
                    
                    path.move(to: CGPoint(x: 0, y: midY))
                    
                    // Create smooth sinusoidal wave
                    for x in stride(from: CGFloat(0), through: size.width, by: 2) {
                        let relativeX = Double(x / size.width)
                        let sine = sin((relativeX * .pi * 3) + phase + layerOffset)
                        let secondarySine = sin((relativeX * .pi * 1.5) + phase * 0.7 + layerOffset) * 0.3
                        let y = midY + CGFloat(sine + secondarySine) * waveHeight
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                    
                    // Stroke with gradient
                    context.stroke(
                        path,
                        with: .linearGradient(
                            Gradient(colors: [
                                Color(hex: "#5E5CE6").opacity(0.6 * layerOpacity),
                                Color.cyan.opacity(0.4 * layerOpacity),
                                Color(hex: "#5E5CE6").opacity(0.6 * layerOpacity)
                            ]),
                            startPoint: CGPoint(x: 0, y: midY),
                            endPoint: CGPoint(x: size.width, y: midY)
                        ),
                        style: StrokeStyle(
                            lineWidth: CGFloat(40 - layer * 10),
                            lineCap: .round,
                            lineJoin: .round
                        )
                    )
                }
            }
        }
    }
}
