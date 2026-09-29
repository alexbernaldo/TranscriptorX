import SwiftUI

// MARK: - Transcription Method
enum YouTubeTranscriptionMethod {
    case fast      // Use youtube-transcript-api (subtitles)
    case whisper   // Download audio and use Whisper
}

// MARK: - URL Input Sheet
/// A sheet for pasting and processing video/audio URLs
/// Provides feedback on the transcription process with appropriate UX for fast vs slow paths
struct URLInputSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var urlService = URLTranscriptionService.shared
    @EnvironmentObject var viewModel: TranscriptionViewModel
    @EnvironmentObject var localizationManager: LocalizationManager
    @Environment(\.responsiveMetrics) private var metrics
    
    @State private var urlText: String = ""
    @State private var isValidURL: Bool = false
    @State private var showingResult: Bool = false
    @State private var selectedMethod: YouTubeTranscriptionMethod = .fast
    @FocusState private var isTextFieldFocused: Bool
    
    // Check if URL is YouTube
    private var isYouTubeURL: Bool {
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let host = URL(string: trimmed)?.host?.lowercased() else { return false }
        return host == "youtube.com" ||
               host == "www.youtube.com" ||
               host == "m.youtube.com" ||
               host == "youtu.be"
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            header
            
            Divider()
                .background(Color.borderSubtle)
            
            // Content
            if urlService.currentPhase == .failed, let error = urlService.error {
                errorView(error: error)
            } else if urlService.isProcessing {
                processingView
            } else if showingResult, let result = urlService.transcriptionResult {
                resultView(text: result)
            } else {
                inputView
            }
        }
        .frame(width: metrics.urlSheetWidth, height: showingResult || urlService.currentPhase == .failed ? 550 : 420)
        .background(Color.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color.borderSubtle, lineWidth: 1)
        )
        .onAppear {
            // Check clipboard for URL
            if let clipboardString = NSPasteboard.general.string(forType: .string),
               isValidURLString(clipboardString) {
                urlText = clipboardString
                isValidURL = true
            }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                isTextFieldFocused = true
            }
        }
        .onChange(of: urlService.currentPhase) { phase in
            AppLogger.shared.log("🔗 [URLSheet] Phase changed to: \(phase)", level: .info, category: .transcription)
            if phase == .complete {
                // Whisper/download flow is handled separately (open NewTranscription with file URL).
                // Do not auto-open text here, or stale subtitle text can leak into Whisper flow.
                let isSubtitleFlow = isYouTubeURL && selectedMethod == .fast
                guard isSubtitleFlow else { return }

                // Auto-open editor when transcription completes
                if let text = urlService.transcriptionResult, !text.isEmpty {
                    AppLogger.shared.log("🔗 [URLSheet] Got result with \(text.count) chars, calling saveAndOpen", level: .info, category: .transcription)
                    saveAndOpen(text: text)
                } else {
                    AppLogger.shared.log("🔗 [URLSheet] No text in result, showing result view", level: .warning, category: .transcription)
                    showingResult = true
                }
            }
        }
    }
    
    // MARK: - Header
    
    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Pegar enlace")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.textPrimary)
                
                Text("YouTube, TikTok, Instagram, Vimeo y más")
                    .font(.bodySmall)
                    .foregroundColor(.textSecondary)
            }
            
            Spacer()
            
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundColor(.textMuted)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cerrar")
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
    }
    
    // MARK: - Input View
    
    private var inputView: some View {
        VStack(spacing: 20) {
            // URL Input Field
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Image(systemName: "link")
                        .font(.bodyXLarge)
                        .foregroundColor(.textMuted)
                    
                    TextField("Pega el enlace aquí...", text: $urlText)
                        .textFieldStyle(.plain)
                        .font(.bodyLarge)
                        .foregroundColor(.textPrimary)
                        .focused($isTextFieldFocused)
                        .accessibilityLabel("URL del vídeo o audio")
                        .accessibilityHint("Introduce la URL de YouTube, TikTok u otro servicio")
                        .onSubmit {
                            if isValidURL {
                                startTranscription()
                            }
                        }
                        .onChange(of: urlText) { newValue in
                            isValidURL = isValidURLString(newValue)
                        }
                    
                    // Paste button
                    Button {
                        if let clipboard = NSPasteboard.general.string(forType: .string) {
                            urlText = clipboard
                            isValidURL = isValidURLString(clipboard)
                        }
                    } label: {
                        Image(systemName: "doc.on.clipboard")
                            .font(.bodyDefault)
                            .foregroundColor(.accentPrimary)
                    }
                    .buttonStyle(.plain)
                    .help("Pegar desde portapapeles")
                    
                    // Clear button
                    if !urlText.isEmpty {
                        Button {
                            urlText = ""
                            isValidURL = false
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.bodyDefault)
                                .foregroundColor(.textMuted)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.bgPrimary)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(
                                    isValidURL ? Color.accentPrimary.opacity(0.5) : Color.borderSubtle,
                                    lineWidth: 1
                                )
                        )
                )
                
                // URL type indicator
                if isValidURL {
                    HStack(spacing: 6) {
                        Image(systemName: urlTypeIcon)
                            .font(.caption)
                        Text(urlTypeLabel)
                            .font(.caption)
                    }
                    .foregroundColor(.accentPrimary)
                    .padding(.leading, 4)
                }
            }
            .padding(.horizontal, 24)
            
            // YouTube method selection (only show for YouTube URLs)
            if isValidURL && isYouTubeURL {
                youTubeMethodSelector
                    .padding(.horizontal, 24)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else {
                // Supported platforms for non-YouTube
                supportedPlatformsView
            }
            
            Spacer()
            
            // Transcribe button
            Button {
                startTranscription()
            } label: {
                    HStack(spacing: 8) {
                        Image(systemName: selectedMethod == .fast && isYouTubeURL ? "text.bubble" : "waveform")
                            .font(.labelDefault)
                        Text(
                            isYouTubeURL && selectedMethod == .fast
                                ? localizationManager.text("urlInput.action.fetchSubtitles", fallback: "Fetch subtitles")
                                : localizationManager.text("urlInput.action.transcribeWhisper", fallback: "Transcribe with Whisper")
                        )
                            .font(.titleMedium)
                    }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(isValidURL ? Color.accentPrimary : Color.accentPrimary.opacity(0.3))
                )
            }
            .buttonStyle(.plain)
            .disabled(!isValidURL)
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .padding(.top, 20)
        .animation(.snappy(duration: 0.2), value: isYouTubeURL)
    }
    
    // MARK: - YouTube Method Selector
    
    private var youTubeMethodSelector: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Método de transcripción")
                .font(.labelBody)
                .foregroundColor(.textSecondary)
            
            HStack(spacing: 12) {
                // Fast method - Subtitles
                methodCard(
                    icon: "text.bubble.fill",
                    title: localizationManager.text("urlInput.method.fast.title", fallback: "Subtitles"),
                    subtitle: localizationManager.text("urlInput.method.fast.subtitle", fallback: "Fast · ~2 sec"),
                    description: localizationManager.text("urlInput.method.fast.description", fallback: "Uses existing video subtitles"),
                    isSelected: selectedMethod == .fast,
                    accentColor: .green
                ) {
                    withAnimation(.snappy) {
                        selectedMethod = .fast
                    }
                }
                
                // Whisper method - Download audio
                methodCard(
                    icon: "waveform",
                    title: localizationManager.text("urlInput.method.whisper.title", fallback: "Whisper AI"),
                    subtitle: localizationManager.text("urlInput.method.whisper.subtitle", fallback: "Accurate · ~2-5 min"),
                    description: localizationManager.text("urlInput.method.whisper.description", fallback: "Downloads audio and transcribes with AI"),
                    isSelected: selectedMethod == .whisper,
                    accentColor: .accentPrimary
                ) {
                    withAnimation(.snappy) {
                        selectedMethod = .whisper
                    }
                }
            }
        }
    }
    
    private func methodCard(
        icon: String,
        title: String,
        subtitle: String,
        description: String,
        isSelected: Bool,
        accentColor: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .font(.bodyXLarge)
                        .foregroundColor(isSelected ? accentColor : .textMuted)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.titleDefault)
                            .foregroundColor(isSelected ? .textPrimary : .textSecondary)
                        
                        Text(subtitle)
                            .font(.labelSmall)
                            .foregroundColor(isSelected ? accentColor : .textMuted)
                    }
                    
                    Spacer()
                    
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.bodyXLarge)
                            .foregroundColor(accentColor)
                    }
                }
                
                Text(description)
                    .font(.caption)
                    .foregroundColor(.textMuted)
                    .lineLimit(2)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? accentColor.opacity(0.1) : Color.bgPrimary)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(
                                isSelected ? accentColor.opacity(0.5) : Color.borderSubtle,
                                lineWidth: 1
                            )
                    )
            )
        }
        .buttonStyle(.plain)
    }
    
    // MARK: - Processing View
    
    private var processingView: some View {
        VStack(spacing: 24) {
            Spacer()
            
            // Animated icon based on phase
            ZStack {
                Circle()
                    .fill(Color.accentPrimary.opacity(0.1))
                    .frame(width: 80, height: 80)
                
                Group {
                    switch urlService.currentPhase {
                    case .fetchingYouTubeTranscript:
                        Image(systemName: "play.rectangle.fill")
                            .font(.system(size: 32))
                            .foregroundColor(.red)
                    case .downloadingAudio:
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 32))
                            .foregroundColor(.accentPrimary)
                    case .processingWithWhisper:
                        if #available(macOS 14.0, *) {
                            Image(systemName: "waveform")
                                .font(.system(size: 32))
                                .foregroundColor(.accentPrimary)
                                .symbolEffect(.pulse)
                        } else {
                            Image(systemName: "waveform")
                                .font(.system(size: 32))
                                .foregroundColor(.accentPrimary)
                        }
                    default:
                        Image(systemName: "hourglass")
                            .font(.system(size: 32))
                            .foregroundColor(.accentPrimary)
                    }
                }
            }
            
            VStack(spacing: 8) {
                Text(phaseTitle)
                    .font(.bodyXLarge)
                    .foregroundColor(.textPrimary)
                
                Text(phaseDescription)
                    .font(.bodyMedium)
                    .foregroundColor(.textSecondary)
                    .multilineTextAlignment(.center)
            }
            
            // Progress bar
            VStack(spacing: 8) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.borderSubtle)
                        
                        RoundedRectangle(cornerRadius: 4)
                            .fill(
                                LinearGradient(
                                    colors: [.accentPrimary, .accentSecondary],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: geo.size.width * urlService.progress)
                            .animation(.easeInOut(duration: 0.3), value: urlService.progress)
                    }
                }
                .frame(height: 8)
                
                Text("\(Int(urlService.progress * 100))%")
                    .font(.labelBody)
                    .foregroundColor(.textMuted)
            }
            .padding(.horizontal, metrics.horizontalPadding)
            
            Spacer()
            
            // Cancel button
            Button {
                urlService.cancel()
                dismiss()
            } label: {
                Text("Cancelar")
                    .font(.labelDefault)
                    .foregroundColor(.textSecondary)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 24)
        }
    }
    
    // MARK: - Result View
    
    private func resultView(text: String) -> some View {
        VStack(spacing: 16) {
            // Success indicator
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Text("Transcripción completada")
                    .font(.labelDefault)
                    .foregroundColor(.textSecondary)
                
                Spacer()
                
                // Word count
                let wordCount = text.split(separator: " ").count
                Text(
                    String(
                        format: localizationManager.text("urlInput.result.wordCount", fallback: "%d words"),
                        wordCount
                    )
                )
                    .font(.bodySmall)
                    .foregroundColor(.textMuted)
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)
            
            // Text preview
            ScrollView {
                Text(text)
                    .font(.bodyMedium)
                    .foregroundColor(.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            .background(Color.bgPrimary)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 24)
            
            // Action buttons
            HStack(spacing: 12) {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    // Visual feedback via button state or external toast
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.on.doc")
                            .font(.bodyMedium)
                        Text("Copiar")
                            .font(.labelDefault)
                    }
                    .foregroundColor(.textPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.bgPrimary)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .strokeBorder(Color.borderSubtle, lineWidth: 1)
                            )
                    )
                }
                .buttonStyle(.plain)
                
                Button {
                    // Save to transcriptions and open viewer
                    saveAndOpen(text: text)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.right.circle.fill")
                            .font(.bodyMedium)
                        Text("Abrir en editor")
                            .font(.labelDefault)
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.accentPrimary)
                    )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }
    
    // MARK: - Supported Platforms View
    
    private var supportedPlatformsView: some View {
        VStack(spacing: 12) {
            Text("Plataformas soportadas")
                .font(.labelMedium)
                .foregroundColor(.textMuted)
            
            HStack(spacing: 20) {
                platformIcon("play.rectangle.fill", "YouTube", .red)
                platformIcon("music.note", "TikTok", .pink)
                platformIcon("camera.fill", "Instagram", .purple)
                platformIcon("play.circle.fill", "Vimeo", .blue)
                platformIcon("globe", "Otros", .gray)
            }
        }
        .padding(.horizontal, 24)
    }
    
    private func platformIcon(_ icon: String, _ name: String, _ color: Color) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundColor(color.opacity(0.8))
            Text(name)
                .font(.system(size: 10))
                .foregroundColor(.textMuted)
        }
    }
    
    // MARK: - Error View
    
    private func errorView(error: URLTranscriptionService.TranscriptionError) -> some View {
        VStack(spacing: 24) {
            Spacer()
            
            // Error icon
            ZStack {
                Circle()
                    .fill(Color.red.opacity(0.1))
                    .frame(width: 80, height: 80)
                
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 36))
                    .foregroundColor(.red.opacity(0.8))
            }
            
            VStack(spacing: 12) {
                Text("No se pudo obtener la transcripción")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.textPrimary)
                
                Text(errorMessage(for: error))
                    .font(.bodyDefault)
                    .foregroundColor(.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
            
            Spacer()
            
            // Action buttons
            HStack(spacing: 12) {
                Button {
                    // Reset and try again
                    urlService.error = nil
                    urlService.currentPhase = .idle
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.bodyMedium)
                        Text("Intentar de nuevo")
                            .font(.labelDefault)
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.accentPrimary)
                    )
                }
                .buttonStyle(.plain)
                
                Button {
                    dismiss()
                } label: {
                    Text("Cerrar")
                        .font(.labelDefault)
                        .foregroundColor(.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color.bgPrimary)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .strokeBorder(Color.borderSubtle, lineWidth: 1)
                                )
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }
    
    private func errorMessage(for error: URLTranscriptionService.TranscriptionError) -> String {
        switch error {
        case .invalidURL:
            return localizationManager.text("urlInput.error.invalidURL", fallback: "The URL entered is not valid. Verify that it is a correct link.")
        case .networkError(let msg):
            return String(format: localizationManager.text("urlInput.error.network", fallback: "Connection error: %@"), msg)
        case .noTranscriptAvailable:
            return localizationManager.text("urlInput.error.noTranscript", fallback: "This video has no subtitles or transcript available. Only videos with subtitles can be transcribed directly.")
        case .downloadFailed(let msg):
            return String(format: localizationManager.text("urlInput.error.downloadFailed", fallback: "Could not download audio: %@"), msg)
        case .whisperFailed(let msg):
            return String(format: localizationManager.text("urlInput.error.whisperFailed", fallback: "Error while processing audio: %@"), msg)
        case .pythonNotFound:
            return localizationManager.text("urlInput.error.pythonNotFound", fallback: "Python is not installed on this system.")
        case .dependencyMissing(let dep):
            return String(format: localizationManager.text("urlInput.error.dependencyMissing", fallback: "Missing dependency: %@"), dep)
        case .cancelled:
            return localizationManager.text("urlInput.error.cancelled", fallback: "The operation was cancelled.")
        }
    }
    
    // MARK: - Helpers
    
    private var urlTypeIcon: String {
        if urlText.contains("youtube.com") || urlText.contains("youtu.be") {
            return "play.rectangle.fill"
        } else if urlText.contains("tiktok.com") {
            return "music.note"
        } else if urlText.contains("instagram.com") {
            return "camera.fill"
        } else if urlText.contains("vimeo.com") {
            return "play.circle.fill"
        }
        return "globe"
    }
    
    private var urlTypeLabel: String {
        let isSpanish = localizationManager.appLanguage == .es
        if urlText.contains("youtube.com") || urlText.contains("youtu.be") {
            return isSpanish ? "YouTube - Transcripción rápida disponible" : "YouTube - Fast transcription available"
        } else if urlText.contains("tiktok.com") {
            return isSpanish ? "TikTok - Se descargará el audio" : "TikTok - Audio will be downloaded"
        } else if urlText.contains("instagram.com") {
            return isSpanish ? "Instagram - Se descargará el audio" : "Instagram - Audio will be downloaded"
        } else if urlText.contains("vimeo.com") {
            return isSpanish ? "Vimeo - Se descargará el audio" : "Vimeo - Audio will be downloaded"
        }
        return isSpanish ? "Se descargará y procesará el audio" : "Audio will be downloaded and processed"
    }

    private var phaseTitle: String {
        let isSpanish = localizationManager.appLanguage == .es
        switch urlService.currentPhase {
        case .idle:
            return ""
        case .analyzing:
            return isSpanish ? "Analizando enlace..." : "Analyzing link..."
        case .fetchingYouTubeTranscript:
            return isSpanish ? "Obteniendo subtítulos..." : "Fetching subtitles..."
        case .downloadingAudio:
            return isSpanish ? "Descargando audio..." : "Downloading audio..."
        case .processingWithWhisper:
            return isSpanish ? "Procesando con Whisper..." : "Processing with Whisper..."
        case .complete:
            return isSpanish ? "¡Transcripción obtenida!" : "Transcription ready!"
        case .failed:
            return isSpanish ? "No se pudo obtener la transcripción" : "Could not retrieve transcription"
        }
    }

    private var phaseDescription: String {
        let isSpanish = localizationManager.appLanguage == .es
        switch urlService.currentPhase {
        case .fetchingYouTubeTranscript:
            return isSpanish ? "Esto solo toma unos segundos" : "This only takes a few seconds"
        case .downloadingAudio:
            return isSpanish ? "Extrayendo audio del vídeo..." : "Extracting audio from video..."
        case .processingWithWhisper:
            return isSpanish ? "La IA está transcribiendo el audio" : "AI is transcribing the audio"
        default:
            return ""
        }
    }
    
    private func isValidURLString(_ string: String) -> Bool {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else { return false }
        return url.scheme == "http" || url.scheme == "https"
    }
    
    private func startTranscription() {
        // Reset local/shared state to avoid carrying stale subtitle text between runs.
        showingResult = false
        urlService.transcriptionResult = nil
        urlService.error = nil

        Task {
            // Non-YouTube links always go through yt-dlp + Whisper.
            // For YouTube, this path is used only when Whisper is explicitly selected.
            let shouldDownloadAudio = !isYouTubeURL || selectedMethod == .whisper
            if shouldDownloadAudio {
                if let audioURL = await urlService.downloadAudioFromURL(urlString: urlText) {
                    // Dismiss this sheet
                    dismiss()
                    
                    // Post notification to open NewTranscriptionSheet with the downloaded file
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        NotificationCenter.default.post(
                            name: .openNewTranscriptionWithFile,
                            object: nil,
                            userInfo: ["fileURL": audioURL]
                        )
                    }
                }
                // If download failed, the service already set the error state
                return
            }
            
            // YouTube + fast mode: try subtitle extraction first
            await urlService.transcribe(urlString: urlText, shouldDownloadAudioFirst: false)
        }
    }
    
    private func saveAndOpen(text: String) {
        AppLogger.shared.log("🔗 [URLSheet] saveAndOpen called with \(text.count) chars", level: .info, category: .transcription)
        
        // Create a new transcription and show it in the viewer
        let transcription = Transcription(
            id: UUID(),
            title: localizationManager.appLanguage == .es ? "Transcripción de enlace" : "Link transcription",
            text: text,
            language: localizationManager.appLanguage == .es ? "es" : "en",
            duration: 0,
            createdAt: Date(),
            isFavorite: false,
            sourceURL: URL(string: urlText)
        )
        
        AppLogger.shared.log("🔗 [URLSheet] Created transcription with ID: \(transcription.id)", level: .info, category: .transcription)
        
        // Save to storage (and update in-memory history)
        viewModel.saveTranscription(transcription)
        AppLogger.shared.log("🔗 [URLSheet] Saved to storage", level: .info, category: .transcription)
        
        // Set as current in ViewModel using plainText initializer
        viewModel.transcriptionResult = TranscriptionResult(plainText: text)
        viewModel.transcriptionText = text  // Also update the text property for display
        AppLogger.shared.log("🔗 [URLSheet] Set transcriptionResult and transcriptionText", level: .info, category: .transcription)
        
        // Select the transcription to show it in the viewer
        viewModel.selectedTranscription = transcription
        AppLogger.shared.log("🔗 [URLSheet] Set selectedTranscription to: \(transcription.title)", level: .info, category: .transcription)
        
        dismiss()
        AppLogger.shared.log("🔗 [URLSheet] Dismissed sheet", level: .info, category: .transcription)
    }
}

// MARK: - Preview
#if DEBUG
struct URLInputSheet_Previews: PreviewProvider {
    static var previews: some View {
        URLInputSheet()
            .environmentObject(TranscriptionViewModel())
            .frame(width: 560, height: 340)
    }
}
#endif
