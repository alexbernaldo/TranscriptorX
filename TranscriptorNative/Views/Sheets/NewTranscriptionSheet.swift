import SwiftUI
import UniformTypeIdentifiers
import AVFoundation

// MARK: - New Transcription Sheet (Modern Design)
struct NewTranscriptionSheet: View {
    @EnvironmentObject var viewModel: TranscriptionViewModel
    @EnvironmentObject var localizationManager: LocalizationManager
    @Environment(\.responsiveMetrics) private var metrics
    @Environment(\.dismiss) private var dismiss
    
    @State private var selectedFile: URL?
    @State private var fileName: String = ""
    @State private var isDropTargeted = false
    
    // Multi-file state
    @State private var pendingFiles: [URL] = []
    @State private var currentFileIndex: Int = 0
    
    private var totalFiles: Int { pendingFiles.count }
    private var isMultiFileMode: Bool { pendingFiles.count > 1 }
    private var isLastFile: Bool { currentFileIndex >= pendingFiles.count - 1 }
    
    // Settings - initialized from saved settings in onAppear
    @State private var selectedLanguage = "es"
    @State private var selectedQuality: TranscriptionQuality = .balanced
    @State private var useNeuralEngine = false
    @State private var useCustomModel = false
    @State private var selectedModelId = "small"
    
    // Advanced settings
    @State private var showAdvancedSettings = false
    @State private var useVAD = false
    @State private var vadThreshold: Double = 0.6
    @State private var enableDiarization = false
    @State private var deepfilter = false
    @State private var isolateVoice = false
    @State private var normalize = false
    @State private var suppressNonSpeech = true
    @State private var translate = false
    @State private var keepAudioFileInHistory = true
    @State private var initialPrompt = ""

    // Model download (needed for multi-file queue flow)
    @State private var modelDownloadTarget: ModelDownloadTarget?
    @State private var resumePrimaryActionAfterModelDownload = false
    
    // Audio Engine availability - checked dynamically
    private var audioEngineAvailable: AudioEngineManager.AvailableProcessors {
        AudioEngineManager.shared.availableProcessors
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header - show file counter if multi-file
            SheetHeader(
                title: isMultiFileMode
                    ? String(
                        format: localizationManager.appLanguage == .es ? "Archivo %d de %d" : "File %d of %d",
                        currentFileIndex + 1,
                        totalFiles
                    )
                    : localizationManager.text("newTranscription.title", fallback: "Nueva Transcripción"),
                subtitle: selectedFile != nil
                    ? fileName
                    : localizationManager.text("newTranscription.subtitle", fallback: "Importa un archivo de audio o vídeo")
            ) {
                dismiss()
            }
            
            // Content - always in ScrollView for smooth transition
            ScrollView(showsIndicators: false) {
                contentView
            }
            .scrollDisabled(selectedFile == nil) // Disable scroll when no file
            
            // Footer - dynamic button based on multi-file position
            SheetFooter(
                isEnabled: selectedFile != nil,
                primaryLabel: isMultiFileMode && !isLastFile
                    ? localizationManager.text("newTranscription.next", fallback: "Siguiente →")
                    : localizationManager.text("newTranscription.transcribe", fallback: "Transcribir"),
                primaryAction: handlePrimaryAction,
                secondaryAction: { dismiss() }
            ) {
                // Config summary
                if selectedFile != nil {
                    HStack(spacing: 6) {
                        CapsuleTag(languageName(selectedLanguage), color: .tagBlue, size: .small)
                        if useCustomModel {
                            CapsuleTag(modelShortName(selectedModelId), color: .tagPurple, size: .small)
                        } else {
                            CapsuleTag(selectedQuality.shortName(localizationManager), color: .tagPurple, size: .small)
                        }
                        if useNeuralEngine {
                            CapsuleTag("⚡", color: .tagGreen, size: .small)
                        }
                        if useVAD {
                            CapsuleTag("VAD", color: .tagOrange, size: .small)
                        }
                        if enableDiarization {
                            CapsuleTag("👥", color: .tagBlue, size: .small)
                        }
                    }
                    .transition(.opacity)
                }
            }
        }
        .frame(width: metrics.transcriptionSheetWidth, height: sheetHeight)
        .background(VisualEffectView(material: .popover))
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: selectedFile != nil)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: showAdvancedSettings)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: currentFileIndex)
        .onAppear {
            loadSavedSettings()
            
            // Check for multi-file drop first
            if !viewModel.selectedFileURLs.isEmpty {
                pendingFiles = viewModel.selectedFileURLs
                currentFileIndex = 0
                loadFileAtIndex(0)
                viewModel.selectedFileURLs = []
                viewModel.selectedFileURL = nil
            }
            // Otherwise check for single file
            else if let url = viewModel.selectedFileURL {
                pendingFiles = [url]
                currentFileIndex = 0
                selectedFile = url
                fileName = url.deletingPathExtension().lastPathComponent
                viewModel.selectedFileURL = nil
            }
        }
        .sheet(item: $modelDownloadTarget) { target in
            ModelDownloadSheet(
                modelId: target.modelId,
                modelName: target.modelName,
                onComplete: {
                    modelDownloadTarget = nil
                    if resumePrimaryActionAfterModelDownload {
                        resumePrimaryActionAfterModelDownload = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            handlePrimaryAction()
                        }
                    }
                },
                onCancel: {
                    modelDownloadTarget = nil
                    resumePrimaryActionAfterModelDownload = false
                }
            )
        }
    }
    
    // MARK: - Load Settings
    
    private func loadSavedSettings() {
        let settings = viewModel.settings
        
        // Basic settings
        selectedLanguage = settings.language
        useNeuralEngine = settings.useCoreML
        
        // Determine quality from model ID
        selectedModelId = settings.selectedModelId
        if let quality = TranscriptionQuality.fromModelId(settings.selectedModelId) {
            selectedQuality = quality
            useCustomModel = false
        } else {
            // Custom model selected
            useCustomModel = true
        }
        
        // Advanced settings
        useVAD = settings.useVAD
        vadThreshold = settings.vadThreshold
        enableDiarization = settings.enableDiarization
        deepfilter = settings.deepfilter
        isolateVoice = settings.isolateVoice
        normalize = settings.normalize
        suppressNonSpeech = settings.suppressNonSpeech
        translate = settings.translate
        keepAudioFileInHistory = settings.keepAudioFileInHistory
        // Don't load initialPrompt from settings - it's session-only in this sheet
        initialPrompt = ""
    }
    
    private func modelShortName(_ modelId: String) -> String {
        switch modelId {
        case "tiny":
            return localizationManager.appLanguage == .es ? "Ultra Rápido" : "Ultra Fast"
        case "base":
            return localizationManager.appLanguage == .es ? "Rápido" : "Fast"
        case "small":
            return localizationManager.appLanguage == .es ? "Equilibrado" : "Balanced"
        case "medium":
            return localizationManager.appLanguage == .es ? "Preciso" : "Precise"
        case "large-v3-turbo":
            return localizationManager.appLanguage == .es ? "Profesional" : "Professional"
        case "large-v2":
            return "Large V2"
        case "large-v3":
            return localizationManager.appLanguage == .es ? "Máxima Calidad" : "Maximum Quality"
        default:
            return modelId.capitalized
        }
    }
    
    private var sheetHeight: CGFloat {
        if selectedFile == nil {
            return 340
        } else if showAdvancedSettings {
            return 680
        } else {
            return 380
        }
    }
    
    // MARK: - Content View
    
    @ViewBuilder
    private var contentView: some View {
        VStack(spacing: 0) {
            // File Drop Zone (clean, no excessive padding)
            ModernFileDropArea(
                selectedFile: $selectedFile,
                fileName: $fileName,
                isDropTargeted: $isDropTargeted
            )
            .padding(.horizontal, 24)
            .padding(.top, 8)
            
            // Settings (appear after file is selected)
            if selectedFile != nil {
                VStack(spacing: 0) {
                    // === BASIC SETTINGS ===
                    NativeSectionHeader(title: localizationManager.text("newTranscription.configuration", fallback: "Configuración"))
                    
                    SettingsGroup {
                        // Language
                        SettingRow(title: localizationManager.text("newTranscription.language", fallback: "Idioma"), icon: "globe", iconColor: .blue) {
                            Picker("", selection: $selectedLanguage) {
                                Text("Español").tag("es")
                                Text("Inglés").tag("en")
                                Text("Français").tag("fr")
                                Text("Deutsch").tag("de")
                                Text("Italiano").tag("it")
                                Text("Português").tag("pt")
                                Text("日本語").tag("ja")
                                Text("中文").tag("zh")
                                Divider()
                                Text("Detección automática").tag("auto")
                            }
                            .labelsHidden()
                            .frame(width: metrics.pickerWidth)
                        }
                        
                        InsetDivider()
                        
                        // Quality
                        SettingRow(title: localizationManager.text("newTranscription.quality", fallback: "Calidad"), icon: "sparkles", iconColor: .purple) {
                            HStack(spacing: 6) {
                                if !useCustomModel {
                                    Picker("", selection: $selectedQuality) {
                                        ForEach(TranscriptionQuality.allCases) { quality in
                                            Text(quality.displayName(localizationManager)).tag(quality)
                                        }
                                    }
                                    .pickerStyle(.segmented)
                                    .frame(width: 200)
                                    .onChange(of: selectedQuality) { newValue in
                                        selectedModelId = newValue.modelId
                                    }
                                } else {
                                    Picker("", selection: $selectedModelId) {
                                        ForEach(TranscriptionService.availableModels) { model in
                                            Text(modelShortName(model.id)).tag(model.id)
                                        }
                                    }
                                    .labelsHidden()
                                    .frame(width: metrics.pickerWidth)
                                }
                                
                                Button {
                                    withAnimation(.easeOut(duration: 0.15)) {
                                        useCustomModel.toggle()
                                        if !useCustomModel {
                                            selectedModelId = selectedQuality.modelId
                                        }
                                    }
                                } label: {
                                    Image(systemName: useCustomModel ? "slider.horizontal.3" : "ellipsis")
                                        .font(.bodySmall)
                                        .foregroundColor(useCustomModel ? .accentPrimary : .textTertiary)
                                        .frame(width: 26, height: 26)
                                        .background(
                                            RoundedRectangle(cornerRadius: 6)
                                                .fill(useCustomModel ? Color.accentPrimary.opacity(0.12) : Color.primary.opacity(0.06))
                                        )
                                }
                                .buttonStyle(.plain)
                                .help(
                                    useCustomModel
                                        ? localizationManager.text("newTranscription.help.presets", fallback: "Usar presets")
                                        : localizationManager.text("newTranscription.help.moreModels", fallback: "Más modelos")
                                )
                            }
                        }

                        InsetDivider()

                        // Keep audio in app history
                        SettingRow(
                            title: localizationManager.text("newTranscription.keepAudio.title", fallback: "Conservar audio"),
                            icon: "externaldrive.badge.checkmark",
                            iconColor: .teal
                        ) {
                            Toggle("", isOn: $keepAudioFileInHistory)
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .labelsHidden()
                        }
                    }
                    .padding(.horizontal, 24)
                    
                    // Quality hint (outside the group, subtle)
                    if !useCustomModel {
                        Text(selectedQuality.description(localizationManager))
                            .font(.caption)
                            .foregroundColor(.textTertiary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .padding(.horizontal, 28)
                            .padding(.top, 6)
                    }
                    
                    // === ADVANCED SETTINGS ===
                    NativeAdvancedSection(
                        isExpanded: $showAdvancedSettings,
                        useVAD: $useVAD,
                        vadThreshold: $vadThreshold,
                        enableDiarization: $enableDiarization,
                        deepfilter: $deepfilter,
                        isolateVoice: $isolateVoice,
                        normalize: $normalize,
                        suppressNonSpeech: $suppressNonSpeech,
                        translate: $translate,
                        initialPrompt: $initialPrompt
                    )
                    .padding(.horizontal, 24)
                }
                .transition(.opacity.combined(with: .offset(y: 8)))
            }
        }
        .padding(.bottom, 16)
    }
    // MARK: - Multi-file Sequential Flow
    
    private func loadFileAtIndex(_ index: Int) {
        guard index < pendingFiles.count else { return }
        let url = pendingFiles[index]
        selectedFile = url
        fileName = url.deletingPathExtension().lastPathComponent
        // Reset advanced settings toggle for each file
        showAdvancedSettings = false
    }
    
    private func handlePrimaryAction() {
        guard ensureModelDownloadedForCurrentSelection() else { return }
        
        if isMultiFileMode {
            // Multi-file: enqueue and keep sequential flow
            enqueueCurrentFile()
            
            if !isLastFile {
                currentFileIndex += 1
                loadFileAtIndex(currentFileIndex)
            } else {
                dismiss()
                let queueMessage = localizationManager.appLanguage == .es
                    ? "\(totalFiles) archivos añadidos a la cola"
                    : "\(totalFiles) files added to queue"
                viewModel.showToast(queueMessage, type: .success)
            }
        } else {
            // Single file: start immediately so loading/progress screen opens
            startCurrentFileTranscription()
            dismiss()
        }
    }
    
    private func startCurrentFileTranscription() {
        guard let url = selectedFile else { return }
        viewModel.startTranscription(fileURL: url, settings: currentFileSettings())
    }
    
    private func enqueueCurrentFile() {
        guard let url = selectedFile else { return }
        let fileSettings = currentFileSettings()
        
        // Get duration
        // Enqueue asynchronously to handle async duration loading
        Task {
            // Get duration
            let asset = AVURLAsset(url: url)
            var duration: TimeInterval?
            if let loadedDuration = try? await asset.load(.duration) {
                duration = loadedDuration.seconds.isNaN ? nil : loadedDuration.seconds
            }
            
            await MainActor.run {
                // Enqueue to JobManager
                let jobId = JobManager.shared.enqueue(
                    fileURL: url,
                    fileName: url.lastPathComponent,
                    fileDuration: duration,
                    settings: fileSettings
                )
                
                AppLogger.shared.log("Enqueued job \(jobId.uuidString.prefix(8))", level: .info, category: .transcription)
            }
        }
    }
    
    private func currentFileSettings() -> TranscriptionSettings {
        // Start from global settings so inherited fields (timestamps, beamSize,
        // bestOf, thresholds, VAD timing, etc.) carry over automatically.
        var fileSettings = viewModel.settings
        fileSettings.language = selectedLanguage
        fileSettings.selectedModelId = useCustomModel ? selectedModelId : selectedQuality.modelId
        fileSettings.useCoreML = useNeuralEngine
        fileSettings.useVAD = useVAD
        fileSettings.vadThreshold = vadThreshold
        fileSettings.enableDiarization = enableDiarization
        fileSettings.deepfilter = deepfilter
        fileSettings.isolateVoice = isolateVoice
        fileSettings.normalize = normalize
        fileSettings.suppressNonSpeech = suppressNonSpeech
        fileSettings.translate = translate
        fileSettings.keepAudioFileInHistory = keepAudioFileInHistory
        fileSettings.initialPrompt = initialPrompt
        return fileSettings
    }
    
    private func languageName(_ code: String) -> String {
        LocalizationHelpers.languageTag(code)
    }
}

private struct ModelDownloadTarget: Identifiable {
    let modelId: String
    let modelName: String
    var id: String { modelId }
}

private extension NewTranscriptionSheet {
    var effectiveModelId: String {
        useCustomModel ? selectedModelId : selectedQuality.modelId
    }

    var effectiveModelName: String {
        modelShortName(effectiveModelId)
    }

    func ensureModelDownloadedForCurrentSelection() -> Bool {
        if TranscriptionService.shared.isModelDownloaded(effectiveModelId) {
            return true
        }

        modelDownloadTarget = ModelDownloadTarget(modelId: effectiveModelId, modelName: effectiveModelName)
        resumePrimaryActionAfterModelDownload = true
        return false
    }
}

// MARK: - Transcription Quality
enum TranscriptionQuality: String, CaseIterable, Identifiable {
    case fast = "Rápido"
    case balanced = "Equilibrado"
    case pro = "Pro"
    
    var id: String { rawValue }
    
    var modelId: String {
        switch self {
        case .fast: return "base"
        case .balanced: return "small"
        case .pro: return "large-v3-turbo"
        }
    }
    
    @MainActor
    func shortName(_ localizationManager: LocalizationManager) -> String {
        switch self {
        case .fast: return "Base"
        case .balanced: return "Small"
        case .pro: return "Turbo"
        }
    }

    @MainActor
    func displayName(_ localizationManager: LocalizationManager) -> String {
        switch self {
        case .fast:
            return localizationManager.appLanguage == .es ? "Rápido" : "Fast"
        case .balanced:
            return localizationManager.appLanguage == .es ? "Equilibrado" : "Balanced"
        case .pro:
            return localizationManager.appLanguage == .es ? "Pro" : "Pro"
        }
    }

    @MainActor
    func description(_ localizationManager: LocalizationManager) -> String {
        switch self {
        case .fast:
            return localizationManager.appLanguage == .es ? "~1 min por 10 min de audio" : "~1 min per 10 min of audio"
        case .balanced:
            return localizationManager.appLanguage == .es ? "~3 min por 10 min de audio" : "~3 min per 10 min of audio"
        case .pro:
            return localizationManager.appLanguage == .es ? "~5 min por 10 min. Máxima precisión" : "~5 min per 10 min. Maximum accuracy"
        }
    }
    
    var qualityStars: String {
        switch self {
        case .fast: return "★★☆☆☆"
        case .balanced: return "★★★★☆"
        case .pro: return "★★★★★"
        }
    }
    
    /// Returns the TranscriptionQuality for a given model ID, or nil if not a preset model
    static func fromModelId(_ modelId: String) -> TranscriptionQuality? {
        switch modelId {
        case "base": return .fast
        case "small": return .balanced
        case "large-v3-turbo": return .pro
        default: return nil
        }
    }
}

// MARK: - Sheet Header
struct SheetHeader: View {
    let title: String
    var subtitle: String? = nil
    let onClose: () -> Void
    
    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.titleLarge)
                    .foregroundColor(.textPrimary)
                
                if let subtitle = subtitle {
                    Text(subtitle)
                        .font(.bodySmall)
                        .foregroundColor(.textTertiary)
                }
            }
            
            Spacer()
            
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundColor(.textMuted)
                    .symbolRenderingMode(.hierarchical)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape)
            .accessibilityLabel("Cerrar")
            .accessibilityHint("Cierra esta ventana sin guardar cambios")
            .help("Cerrar (Esc)")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Sheet Footer
struct SheetFooter<LeftContent: View>: View {
    @EnvironmentObject var localizationManager: LocalizationManager
    let isEnabled: Bool
    var primaryLabel: String = "Transcribir"
    let primaryAction: () -> Void
    let secondaryAction: () -> Void
    @ViewBuilder let leftContent: LeftContent
    
    var body: some View {
        VStack(spacing: 0) {
            Divider()
            
            HStack {
                leftContent
                
                Spacer()
                
                HStack(spacing: 12) {
                    Button("Cancelar", action: secondaryAction)
                        .buttonStyle(GhostButtonStyle())
                        .keyboardShortcut(.escape)
                        .accessibilityLabel("Cancelar")
                        .accessibilityHint("Cierra sin iniciar la transcripción")
                    
                    Button(primaryLabel, action: primaryAction)
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(!isEnabled)
                        .keyboardShortcut(.return)
                        .accessibilityLabel(primaryLabel)
                        .accessibilityHint(
                            localizationManager.appLanguage == .es
                                ? (isEnabled
                                    ? "Inicia la transcripción del archivo seleccionado"
                                    : "Primero debes seleccionar un archivo")
                                : (isEnabled
                                    ? "Start transcription for the selected file"
                                    : "Select a file first")
                        )
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
    }
}

// MARK: - Modern File Drop Area
struct ModernFileDropArea: View {
    @Binding var selectedFile: URL?
    @Binding var fileName: String
    @Binding var isDropTargeted: Bool
    
    @State private var isHovered = false
    
    var body: some View {
        ZStack {
            if let url = selectedFile {
                // File Selected State
                FileSelectedCard(url: url) {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        selectedFile = nil
                        fileName = ""
                    }
                }
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.95).combined(with: .opacity),
                    removal: .opacity
                ))
            } else {
                // Drop Zone
                DropZone(
                    isDropTargeted: isDropTargeted,
                    isHovered: isHovered,
                    onTap: openFilePicker
                )
                .onHover { hovering in
                    isHovered = hovering
                }
                .onDrop(of: [.audio, .fileURL], isTargeted: $isDropTargeted) { providers in
                    handleDrop(providers: providers)
                }
                .transition(.opacity)
            }
        }
    }
    
    private func openFilePicker() {
        guard let url = FileInputService.pickSingleFile() else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            selectedFile = url
            fileName = url.lastPathComponent
        }
    }
    
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, error in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                
                DispatchQueue.main.async {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        selectedFile = url
                        fileName = url.lastPathComponent
                    }
                }
            }
        }
        return true
    }
}

// MARK: - File Selected Card (Clean, No Box)
private struct FileSelectedCard: View {
    let url: URL
    let onRemove: () -> Void
    
    var body: some View {
        HStack(spacing: 14) {
            // Large file icon (40px)
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.accentPrimary.opacity(0.12))
                    .frame(width: 44, height: 44)
                
                Image(systemName: "waveform")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(.accentPrimary)
            }
            
            // File info - clean, no boxes
            VStack(alignment: .leading, spacing: 3) {
                Text(url.deletingPathExtension().lastPathComponent)
                    .font(.labelDefault)
                    .foregroundColor(.textPrimary)
                    .lineLimit(1)
                
                Text("\(formatFileSize(url)) · \(url.pathExtension.uppercased())")
                    .font(.bodySmall)
                    .foregroundColor(.textTertiary)
            }
            
            Spacer()
            
            // Subtle remove button (x)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.labelMedium)
                    .foregroundColor(.textTertiary)
                    .frame(width: 24, height: 24)
                    .background(
                        Circle()
                            .fill(Color.primary.opacity(0.06))
                    )
            }
            .buttonStyle(.plain)
            .help("Quitar archivo")
        }
        .padding(.vertical, 4)
    }
    
    private func formatFileSize(_ url: URL) -> String {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64 else { return "" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }
}

// MARK: - Drop Zone
private struct DropZone: View {
    @EnvironmentObject var localizationManager: LocalizationManager
    let isDropTargeted: Bool
    let isHovered: Bool
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 16) {
                // Animated icon
                ZStack {
                    Circle()
                        .fill(Color.accentPrimary.opacity(isDropTargeted ? 0.2 : 0.1))
                        .frame(width: 72, height: 72)
                        .scaleEffect(isDropTargeted ? 1.1 : 1)
                    
                    Image(systemName: "arrow.up.doc.fill")
                        .font(.system(size: 28))
                        .foregroundColor(.accentPrimary)
                        .offset(y: isDropTargeted ? -4 : 0)
                }
                .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isDropTargeted)
                
                VStack(spacing: 6) {
                    Text(
                        isDropTargeted
                            ? (localizationManager.appLanguage == .es ? "Suelta el archivo" : "Drop file")
                            : (localizationManager.appLanguage == .es ? "Arrastra aquí o haz clic" : "Drop here or click")
                    )
                        .font(.titleSmall)
                        .foregroundColor(.textPrimary)
                    
                    Text("MP3, WAV, M4A, MP4, MOV y más")
                        .font(.bodySmall)
                        .foregroundColor(.textTertiary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 48)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(
                        isDropTargeted ? Color.accentPrimary : (isHovered ? Color.textMuted : Color.borderColor),
                        style: StrokeStyle(lineWidth: 2, dash: [10, 6])
                    )
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(isDropTargeted ? Color.accentPrimary.opacity(0.05) : (isHovered ? Color.bgHover : Color.clear))
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Setting Row (Native Form Style - No Box)
struct SettingRow<Content: View>: View {
    let title: String
    let icon: String
    let iconColor: Color
    var subtitle: String? = nil
    @ViewBuilder let content: Content
    
    init(title: String, icon: String, iconColor: Color = .accentPrimary, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.iconColor = iconColor
        self.subtitle = subtitle
        self.content = content()
    }
    
    var body: some View {
        HStack(spacing: 12) {
            // Colored icon
            Image(systemName: icon)
                .font(.bodyDefault)
                .foregroundColor(iconColor)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(iconColor.opacity(0.12))
                )
            
            // Title and subtitle
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.bodyMedium)
                    .foregroundColor(.textPrimary)
                
                if let subtitle = subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.textTertiary)
                }
            }
            
            Spacer()
            
            content
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

// MARK: - Section Header (Uppercase, Small)
struct NativeSectionHeader: View {
    let title: String
    
    var body: some View {
        Text(title.uppercased())
            .font(.labelMedium)
            .foregroundColor(.textTertiary)
            .tracking(0.3)
            .padding(.horizontal, 12)
            .padding(.top, 20)
            .padding(.bottom, 6)
    }
}

// MARK: - Grouped Settings Container
struct SettingsGroup<Content: View>: View {
    @ViewBuilder let content: Content
    
    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }
}

// MARK: - Inset Divider
struct InsetDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(height: 0.5)
            .padding(.leading, 52)
    }
}

// MARK: - Native Advanced Section (System Settings Style)
struct NativeAdvancedSection: View {
    @Binding var isExpanded: Bool
    @Binding var useVAD: Bool
    @Binding var vadThreshold: Double
    @Binding var enableDiarization: Bool
    @Binding var deepfilter: Bool
    @Binding var isolateVoice: Bool
    @Binding var normalize: Bool
    @Binding var suppressNonSpeech: Bool
    @Binding var translate: Bool
    @Binding var initialPrompt: String
    
    private var audioEngineAvailable: AudioEngineManager.AvailableProcessors {
        AudioEngineManager.shared.availableProcessors
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header toggle
            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack {
                    Text("Opciones avanzadas")
                        .font(.labelLarge)
                        .foregroundColor(.textSecondary)
                    
                    Spacer()
                    
                    Image(systemName: "chevron.right")
                        .font(.sidebarSection)
                        .foregroundColor(.textTertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isExpanded)
                }
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
            
            // Expanded content
            if isExpanded {
                VStack(spacing: 0) {
                    // === PREPROCESAMIENTO ===
                    NativeSectionHeader(title: "Preprocesamiento")
                    
                    SettingsGroup {
                        // Noise reduction
                        NativeToggleRow(
                            title: "Reducción de ruido",
                            subtitle: "DeepFilterNet v3",
                            icon: "waveform.badge.minus",
                            iconColor: .purple,
                            isOn: $deepfilter,
                            disabled: !audioEngineAvailable.deepFilter
                        )
                        
                        InsetDivider()
                        
                        // Voice isolation
                        NativeToggleRow(
                            title: "Aislar voz",
                            subtitle: "HTDemucs Neural",
                            icon: "person.wave.2.fill",
                            iconColor: .blue,
                            isOn: $isolateVoice,
                            disabled: !audioEngineAvailable.demucs
                        )
                        
                        InsetDivider()
                        
                        // Normalize
                        NativeToggleRow(
                            title: "Normalizar volumen",
                            subtitle: "EBU R128",
                            icon: "speaker.wave.2.fill",
                            iconColor: .green,
                            isOn: $normalize
                        )
                    }
                    
                    // === DETECCIÓN ===
                    NativeSectionHeader(title: "Detección")
                    
                    SettingsGroup {
                        // VAD with integrated slider and visual feedback
                        VStack(spacing: 0) {
                            NativeToggleRow(
                                title: "Detección de voz (VAD)",
                                subtitle: "Segmenta automáticamente",
                                icon: "waveform.path.ecg",
                                iconColor: .orange,
                                isOn: $useVAD
                            )
                            
                            // Slider and visual feedback when VAD is on
                            if useVAD {
                                VStack(spacing: 10) {
                                    HStack(spacing: 12) {
                                        Text("Sensibilidad")
                                            .font(.bodySmall)
                                            .foregroundColor(.textTertiary)
                                        
                                        Slider(value: $vadThreshold, in: 0.3...0.9, step: 0.1)
                                            .controlSize(.small)
                                        
                                        Text(String(format: "%.1f", vadThreshold))
                                            .font(.mono)
                                            .foregroundColor(.textSecondary)
                                            .frame(width: 28)
                                    }
                                    
                                    // VAD Visual Indicator
                                    VADThresholdIndicator(threshold: vadThreshold)
                                }
                                .padding(.horizontal, 12)
                                .padding(.bottom, 12)
                                .padding(.leading, 40)
                                .transition(.opacity.combined(with: .offset(y: -4)))
                            }
                        }
                        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: useVAD)
                        
                        InsetDivider()
                        
                        // Diarization with Beta tag
                        HStack(spacing: 12) {
                            Image(systemName: "person.2.fill")
                                .font(.bodyMedium)
                                .foregroundColor(.cyan)
                                .frame(width: 28, height: 28)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(Color.cyan.opacity(0.12))
                                )
                            
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 6) {
                                    Text("Detectar hablantes")
                                        .font(.bodyMedium)
                                        .foregroundColor(.textPrimary)
                                    
                                    Text("Beta")
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundColor(.orange)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 2)
                                        .background(
                                            Capsule().fill(Color.orange.opacity(0.15))
                                        )
                                }
                                
                                Text("Identifica diferentes personas")
                                    .font(.caption)
                                    .foregroundColor(.textTertiary)
                            }
                            
                            Spacer()
                            
                            Toggle("", isOn: $enableDiarization)
                                .toggleStyle(.switch)
                                .controlSize(.small)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                    }
                    
                    // === OPCIONES ===
                    NativeSectionHeader(title: "Opciones")
                    
                    SettingsGroup {
                        // Suppress non-speech
                        NativeToggleRow(
                            title: "Suprimir no-voz",
                            subtitle: "Elimina toses, risas, etc.",
                            icon: "speaker.slash.fill",
                            iconColor: .gray,
                            isOn: $suppressNonSpeech
                        )
                        
                        InsetDivider()
                        
                        // Translate
                        NativeToggleRow(
                            title: "Traducir a inglés",
                            subtitle: "Traduce automáticamente",
                            icon: "globe",
                            iconColor: .indigo,
                            isOn: $translate
                        )
                    }
                    
                    // === CONTEXTO ===
                    NativeSectionHeader(title: "Contexto")
                    
                    // Native text field
                    TextField("Ej: Reunión sobre el proyecto X con María y Juan...", text: $initialPrompt, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.bodySmall)
                        .lineLimit(2...4)
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.primary.opacity(0.06))
                        )
                        .padding(.bottom, 8)
                }
                .transition(
                    .asymmetric(
                        insertion: .opacity
                            .combined(with: .scale(scale: 0.98, anchor: .top))
                            .combined(with: .offset(y: -8)),
                        removal: .opacity.combined(with: .scale(scale: 0.98, anchor: .top))
                    )
                )
            }
        }
    }
}

// MARK: - Native Toggle Row
struct NativeToggleRow: View {
    let title: String
    let subtitle: String
    let icon: String
    let iconColor: Color
    @Binding var isOn: Bool
    var disabled: Bool = false
    
    var body: some View {
        HStack(spacing: 12) {
            // Colored icon box
            Image(systemName: icon)
                .font(.bodyMedium)
                .foregroundColor(disabled ? .textMuted : iconColor)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(disabled ? Color.primary.opacity(0.04) : iconColor.opacity(0.12))
                )
            
            // Text
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.bodyMedium)
                        .foregroundColor(disabled ? .textMuted : .textPrimary)
                    
                    if disabled {
                        Text("Próximamente")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.textMuted)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(
                                Capsule().fill(Color.primary.opacity(0.06))
                            )
                    }
                }
                
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.textTertiary)
            }
            
            Spacer()
            
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(disabled)
                .opacity(disabled ? 0.4 : 1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

// MARK: - VAD Threshold Visual Indicator
struct VADThresholdIndicator: View {
    @EnvironmentObject var localizationManager: LocalizationManager
    let threshold: Double
    
    // Simulated audio levels (represents what typical audio looks like)
    private let sampleLevels: [Double] = [
        0.15, 0.22, 0.18, 0.65, 0.78, 0.82, 0.75, 0.68, 0.25, 0.12,
        0.08, 0.55, 0.72, 0.88, 0.92, 0.85, 0.45, 0.22, 0.18, 0.95,
        0.88, 0.72, 0.35, 0.15, 0.10, 0.58, 0.75, 0.62, 0.28, 0.12
    ]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Info text
            HStack(spacing: 4) {
                Image(systemName: "info.circle")
                    .font(.system(size: 10))
                Text(thresholdDescription)
                    .font(.system(size: 10))
            }
            .foregroundColor(.textTertiary)
            
            // Visual bar
            GeometryReader { geometry in
                HStack(spacing: 2) {
                    ForEach(0..<sampleLevels.count, id: \.self) { index in
                        let level = sampleLevels[index]
                        let passesFilter = level >= threshold
                        
                        RoundedRectangle(cornerRadius: 2)
                            .fill(passesFilter ? Color.green : Color.red.opacity(0.4))
                            .frame(height: CGFloat(level) * 20 + 4)
                    }
                }
                .frame(height: 24, alignment: .bottom)
            }
            .frame(height: 24)
            
            // Legend
            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    Circle().fill(Color.green).frame(width: 6, height: 6)
                    Text("Voz detectada")
                        .font(.system(size: 9))
                        .foregroundColor(.textTertiary)
                }
                HStack(spacing: 4) {
                    Circle().fill(Color.red.opacity(0.4)).frame(width: 6, height: 6)
                    Text("Silencio/ruido (cortado)")
                        .font(.system(size: 9))
                        .foregroundColor(.textTertiary)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.03))
        )
    }
    
    private var thresholdDescription: String {
        if threshold < 0.5 {
            return localizationManager.appLanguage == .es
                ? "Sensibilidad alta: detecta más sonidos (puede incluir ruido)"
                : "High sensitivity: detects more sounds (may include noise)"
        } else if threshold < 0.7 {
            return localizationManager.appLanguage == .es
                ? "Sensibilidad media: equilibrio entre voz y silencio"
                : "Medium sensitivity: balanced between voice and silence"
        } else {
            return localizationManager.appLanguage == .es
                ? "Sensibilidad baja: solo voz clara (puede cortar susurros)"
                : "Low sensitivity: only clear voice (may cut whispers)"
        }
    }
}
