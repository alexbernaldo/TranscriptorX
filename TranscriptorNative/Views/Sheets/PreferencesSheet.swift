import SwiftUI

// MARK: - Preferences Sheet (Modern Design)
struct PreferencesSheet: View {
    @EnvironmentObject var viewModel: TranscriptionViewModel
    @EnvironmentObject var localizationManager: LocalizationManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.responsiveMetrics) private var metrics
    
    @State private var selectedTab: PreferencesTab = .general
    
    var body: some View {
        HStack(spacing: 0) {
            // Sidebar
            PreferencesSidebar(selectedTab: $selectedTab)
            
            // Content
            VStack(spacing: 0) {
                // Header
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(localizationManager.text(selectedTab.titleLocalizationKey, fallback: selectedTab.title))
                            .font(.titleLarge)
                            .foregroundColor(.textPrimary)
                        
                        Text(localizationManager.text(selectedTab.subtitleLocalizationKey, fallback: selectedTab.subtitle))
                            .font(.bodySmall)
                            .foregroundColor(.textTertiary)
                        
                        Label(localizationManager.text("preferences.autosave", fallback: "Los cambios se guardan automáticamente"), systemImage: "checkmark.circle")
                            .font(.caption)
                            .foregroundColor(.textMuted)
                    }
                    
                    Spacer()
                    
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 22))
                            .foregroundColor(.textMuted)
                            .symbolRenderingMode(.hierarchical)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(localizationManager.text("preferences.close", fallback: "Cerrar preferencias"))
                    .keyboardShortcut(.escape)
                }
                .padding(.horizontal, 28)
                .padding(.top, 24)
                .padding(.bottom, 20)
                
                Divider()
                    .padding(.horizontal, 28)
                
                // Tab Content
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        switch selectedTab {
                        case .general:
                            GeneralPreferencesView()
                        case .models:
                            ModelsPreferencesView()
                        case .audio:
                            AudioPreferencesView()
                        case .advanced:
                            AdvancedPreferencesView()
                        }
                    }
                    .padding(28)
                }
            }
            .frame(maxWidth: .infinity)
            .background(Color.bgPrimary)
        }
        .frame(width: metrics.prefsWidth, height: metrics.prefsHeight)
        .onChange(of: viewModel.settings) { _ in
            viewModel.saveSettings()
        }
    }
}

// MARK: - Preferences Tab
enum PreferencesTab: String, CaseIterable, Identifiable {
    case general = "general"
    case models = "models"
    case audio = "audio"
    case advanced = "advanced"
    
    var id: String { rawValue }
    
    var title: String {
        switch self {
        case .general: return "General"
        case .models: return "Modelos"
        case .audio: return "Audio"
        case .advanced: return "Avanzado"
        }
    }
    
    var subtitle: String {
        switch self {
        case .general: return "Idioma de interfaz y transcripción"
        case .models: return "Modelos de IA y aceleración"
        case .audio: return "Preprocesamiento y VAD"
        case .advanced: return "Opciones avanzadas"
        }
    }
    
    var titleLocalizationKey: String {
        switch self {
        case .general: return "preferences.tab.general"
        case .models: return "preferences.tab.models"
        case .audio: return "preferences.tab.audio"
        case .advanced: return "preferences.tab.advanced"
        }
    }
    
    var subtitleLocalizationKey: String {
        switch self {
        case .general: return "preferences.subtitle.general"
        case .models: return "preferences.subtitle.models"
        case .audio: return "preferences.subtitle.audio"
        case .advanced: return "preferences.subtitle.advanced"
        }
    }
    
    var icon: String {
        switch self {
        case .general: return "gearshape.fill"
        case .models: return "brain.fill"
        case .audio: return "waveform"
        case .advanced: return "slider.horizontal.3"
        }
    }
    
    var iconColor: Color {
        switch self {
        case .general: return .gray
        case .models: return .blue
        case .audio: return .orange
        case .advanced: return .green
        }
    }
}

// MARK: - Preferences Sidebar (Native Style)
private struct PreferencesSidebar: View {
    @Binding var selectedTab: PreferencesTab
    @Environment(\.responsiveMetrics) private var metrics
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(PreferencesTab.allCases) { tab in
                NativeTabButton(
                    tab: tab,
                    isSelected: selectedTab == tab
                ) {
                    withAnimation(.easeOut(duration: 0.15)) {
                        selectedTab = tab
                    }
                }
            }
            
            Spacer()
            
            // Version info
            HStack(spacing: 6) {
                Image(systemName: "app.fill")
                    .font(.bodySmall)
                    .foregroundColor(.textMuted)
                Text("TranscriptorX v2.0")
                    .font(.caption)
                    .foregroundColor(.textMuted)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .padding(.top, 12)
        .frame(width: metrics.sidebarWidth)
        .background(VisualEffectView(material: .sidebar))
    }
}

// MARK: - Native Tab Button (Colored Icons)
private struct NativeTabButton: View {
    @EnvironmentObject var localizationManager: LocalizationManager
    let tab: PreferencesTab
    let isSelected: Bool
    let action: () -> Void
    
    @State private var isHovered = false
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                // Colored icon in rounded square
                Image(systemName: tab.icon)
                    .font(.labelBody)
                    .foregroundColor(.white)
                    .frame(width: 24, height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(tab.iconColor)
                    )
                
                Text(localizationManager.text(tab.titleLocalizationKey, fallback: tab.title))
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? .accentPrimary : .textPrimary)
                
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.accentPrimary.opacity(0.12) : (isHovered ? Color.primary.opacity(0.06) : Color.clear))
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - General Preferences
private struct GeneralPreferencesView: View {
    @EnvironmentObject var viewModel: TranscriptionViewModel
    @EnvironmentObject var localizationManager: LocalizationManager
    @Environment(\.responsiveMetrics) private var metrics
    
    private var appLanguageBinding: Binding<AppLanguage> {
        Binding(
            get: { localizationManager.appLanguage },
            set: { localizationManager.setLanguage($0) }
        )
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Language Section
            NativeSettingsSection(title: localizationManager.text("preferences.section.language", fallback: "IDIOMA")) {
                HStack {
                    Image(systemName: "globe")
                        .font(.labelBody)
                        .foregroundColor(.white)
                        .frame(width: 24, height: 24)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.blue)
                        )
                    
                    Text(localizationManager.text("preferences.general.interfaceLanguage", fallback: "Idioma de la interfaz"))
                        .font(.labelLarge)
                        .foregroundColor(.textPrimary)
                    
                    Spacer()
                    
                    Picker("", selection: appLanguageBinding) {
                        ForEach(AppLanguage.supportedInterfaceLanguages) { language in
                            Text(language.displayName).tag(language)
                        }
                    }
                    .labelsHidden()
                    .frame(width: metrics.pickerWidth)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                
                Divider()
                    .padding(.leading, 48)
                
                HStack {
                    Image(systemName: "waveform")
                        .font(.labelBody)
                        .foregroundColor(.white)
                        .frame(width: 24, height: 24)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.indigo)
                        )
                    
                    Text(localizationManager.text("preferences.general.transcriptionLanguage", fallback: "Idioma de transcripción por defecto"))
                        .font(.labelLarge)
                        .foregroundColor(.textPrimary)
                    
                    Spacer()
                    
                    Picker("", selection: $viewModel.settings.language) {
                        Text("Español").tag("es")
                        Text("Inglés").tag("en")
                        Text("Français").tag("fr")
                        Text("Deutsch").tag("de")
                        Text("Italiano").tag("it")
                        Text("Português").tag("pt")
                        Text("日本語").tag("ja")
                        Text("中文").tag("zh")
                        Text(localizationManager.text("preferences.transcriptionLanguage.auto", fallback: "Detección automática")).tag("auto")
                    }
                    .labelsHidden()
                    .frame(width: metrics.pickerWidth)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            
            // Output Section
            NativeSettingsSection(title: localizationManager.text("preferences.section.output", fallback: "FORMATO DE SALIDA")) {
                NativeToggleRow(
                    title: localizationManager.text("preferences.output.timestamps.title", fallback: "Timestamps"),
                    subtitle: localizationManager.text("preferences.output.timestamps.subtitle", fallback: "Marcas de tiempo"),
                    icon: "clock",
                    iconColor: .orange,
                    isOn: $viewModel.settings.timestamps
                )
                
                NativeToggleRow(
                    title: localizationManager.text("preferences.output.speakers.title", fallback: "Detectar hablantes"),
                    subtitle: localizationManager.text("preferences.output.speakers.subtitle", fallback: "Tinydiarize"),
                    icon: "person.2",
                    iconColor: .purple,
                    isOn: $viewModel.settings.enableDiarization
                )
                
                NativeToggleRow(
                    title: localizationManager.text("preferences.output.translate.title", fallback: "Traducir a inglés"),
                    subtitle: localizationManager.text("preferences.output.translate.subtitle", fallback: "Salida en inglés"),
                    icon: "character.book.closed",
                    iconColor: .blue,
                    isOn: $viewModel.settings.translate
                )
            }
            
            // Behavior Section
            NativeSettingsSection(title: localizationManager.text("preferences.section.behavior", fallback: "COMPORTAMIENTO")) {
                NativeToggleRow(
                    title: localizationManager.text("preferences.behavior.fillers.title", fallback: "Suprimir muletillas"),
                    subtitle: localizationManager.text("preferences.behavior.fillers.subtitle", fallback: "Reduce 'uh', 'um'"),
                    icon: "text.badge.minus",
                    iconColor: .red,
                    isOn: $viewModel.settings.suppressNonSpeech
                )
                
                PreferencesSliderRow(
                    title: localizationManager.text("preferences.behavior.temperature", fallback: "Temperatura"),
                    value: $viewModel.settings.temperature,
                    range: 0...0.5,
                    step: 0.05
                )
            }
        }
    }
}

// MARK: - Models Preferences
private struct ModelsPreferencesView: View {
    @EnvironmentObject var viewModel: TranscriptionViewModel
    @EnvironmentObject var localizationManager: LocalizationManager
    @State private var downloadingModel: String?
    
    private let service = TranscriptionService.shared
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Quick Mode Section
            NativeSettingsSection(title: localizationManager.text("preferences.section.quickMode", fallback: "MODO RÁPIDO")) {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("", selection: Binding(
                        get: { quickModeFromModel(viewModel.settings.selectedModelId) },
                        set: {
                            viewModel.settings.selectedModelId = modelFromQuickMode($0)
                            checkCoreMLSupport()
                        }
                    )) {
                        Text(localizationManager.text("preferences.quickMode.fast", fallback: "Rápido")).tag("fast")
                        Text(localizationManager.text("preferences.quickMode.balanced", fallback: "Equilibrado")).tag("balanced")
                        Text(localizationManager.text("preferences.quickMode.precise", fallback: "Preciso")).tag("precise")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    
                    if let model = ModelInfo.allModels.first(where: { $0.id == viewModel.settings.selectedModelId }) {
                        Text(model.localizedDescription(localizationManager.appLanguage))
                            .font(.caption)
                            .foregroundColor(.textTertiary)
                    }
                }
                .padding(12)
            }
            
            // Models List Section
            NativeSettingsSection(title: localizationManager.text("preferences.section.availableModels", fallback: "MODELOS DISPONIBLES")) {
                VStack(spacing: 0) {
                    ForEach(Array(ModelInfo.allModels.enumerated()), id: \.element.id) { index, model in
                        ModelCard(
                            model: model,
                            appLanguage: localizationManager.appLanguage,
                            isDownloaded: service.isModelDownloaded(model.id),
                            isDownloading: downloadingModel == model.id,
                            isSelected: viewModel.settings.selectedModelId == model.id,
                            onSelect: {
                                viewModel.settings.selectedModelId = model.id
                                checkCoreMLSupport()
                            },
                            onDownload: {
                                downloadModel(model.id)
                            }
                        )
                        
                        if index < ModelInfo.allModels.count - 1 {
                            Divider()
                                .padding(.leading, 48)
                        }
                    }
                }
            }
            
            // CoreML Section
            if service.isCoreMLSupported(for: viewModel.settings.selectedModelId) {
                CoreMLSection()
            }
        }
    }
    
    private func downloadModel(_ modelId: String) {
        downloadingModel = modelId
        let friendlyName = ModelInfo.allModels.first { $0.id == modelId }?.localizedName(localizationManager.appLanguage) ?? modelId
        NotificationCenter.default.post(
            name: .needsModelDownload,
            object: nil,
            userInfo: ["modelId": modelId, "modelName": friendlyName]
        )
    }
    
    private func checkCoreMLSupport() {
        if viewModel.settings.useCoreML && !service.isCoreMLSupported(for: viewModel.settings.selectedModelId) {
            viewModel.settings.useCoreML = false
        }
    }
    
    private func quickModeFromModel(_ modelId: String) -> String {
        switch modelId {
        case "tiny", "base": return "fast"
        case "small", "medium": return "balanced"
        default: return "precise"
        }
    }
    
    private func modelFromQuickMode(_ mode: String) -> String {
        switch mode {
        case "fast": return "base"
        case "balanced": return "small"
        case "precise": return "large-v3-turbo"
        default: return "base"
        }
    }
}

// MARK: - Model Row (Compact Native Style)
private struct ModelCard: View {
    @EnvironmentObject var localizationManager: LocalizationManager
    let model: ModelInfo
    let appLanguage: AppLanguage
    let isDownloaded: Bool
    let isDownloading: Bool
    let isSelected: Bool
    let onSelect: () -> Void
    let onDownload: () -> Void
    
    @State private var isHovered = false
    @State private var showInfo = false
    
    var body: some View {
        HStack(spacing: 12) {
            // Selection radio
            Button(action: onSelect) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.bodyXLarge)
                    .foregroundColor(isSelected ? .accentPrimary : .textMuted)
            }
            .buttonStyle(.plain)
            .disabled(!isDownloaded)
            .opacity(isDownloaded ? 1 : 0.5)
            
            // Model info
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.localizedName(appLanguage))
                        .font(.labelLarge)
                        .foregroundColor(.textPrimary)
                    
                    if model.recommended {
                        Text(localizationManager.text("preferences.model.recommended", fallback: "Recomendado"))
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.green)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(
                                Capsule().fill(Color.green.opacity(0.12))
                            )
                    }
                }
                
                Text("\(model.localizedSpeed(appLanguage)) · \(model.size)")
                    .font(.caption)
                    .foregroundColor(.textTertiary)
            }
            
            Spacer()
            
            // Quality stars (compact)
            Text(model.qualityStars)
                .font(.system(size: 9))
                .foregroundColor(.orange)
            
            // Info button
            Button { showInfo.toggle() } label: {
                Image(systemName: "info.circle")
                    .font(.bodyMedium)
                    .foregroundColor(.textMuted)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showInfo, arrowEdge: .trailing) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.technicalName)
                        .font(.titleSmall)
                    Text(model.localizedDescription(appLanguage))
                        .font(.bodySmall)
                        .foregroundColor(.secondary)
                }
                .padding(12)
                .frame(width: 200)
            }
            
            // Status/Download
            Group {
                if isDownloaded {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                } else if isDownloading {
                    ProgressView()
                        .scaleEffect(0.6)
                } else {
                    Button(action: onDownload) {
                        Image(systemName: "arrow.down.circle")
                            .foregroundColor(.accentPrimary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .font(.bodyXLarge)
            .frame(width: 24)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentPrimary.opacity(0.08) : (isHovered ? Color.primary.opacity(0.04) : Color.clear))
        )
        .onHover { isHovered = $0 }
    }
}

// MARK: - CoreML Section
private struct CoreMLSection: View {
    @EnvironmentObject var viewModel: TranscriptionViewModel
    @EnvironmentObject var localizationManager: LocalizationManager
    private let service = TranscriptionService.shared
    
    var coreMLStatus: TranscriptionService.CoreMLStatus {
        service.getCoreMLStatus(for: viewModel.settings.selectedModelId)
    }
    
    var coreMLSize: String {
        service.getCoreMLSize(for: viewModel.settings.selectedModelId) ?? "?"
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(localizationManager.text("preferences.section.acceleration", fallback: "ACELERACIÓN"))
                .font(.labelMedium)
                .foregroundColor(.textTertiary)
                .tracking(0.3)
            
            // Simple row, no box
            HStack(spacing: 12) {
                // Yellow bolt icon in rounded square
                Image(systemName: "bolt.fill")
                    .font(.labelBody)
                    .foregroundColor(.white)
                    .frame(width: 24, height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.yellow)
                    )
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(localizationManager.text("preferences.acceleration.neuralEngine", fallback: "Neural Engine"))
                        .font(.labelLarge)
                        .foregroundColor(.textPrimary)
                    
                    Text(localizationManager.text("preferences.acceleration.coreml.subtitle", fallback: "CoreML · base, small, medium"))
                        .font(.caption)
                        .foregroundColor(.textTertiary)
                }
                
                Spacer()
                
                // Status text
                statusText
                
                Toggle("", isOn: $viewModel.settings.useCoreML)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
        }
    }
    
    @ViewBuilder
    private var statusText: some View {
        switch coreMLStatus {
        case .notSupported:
            EmptyView()
        case .ready:
            Text(localizationManager.text("preferences.acceleration.active", fallback: "Activo"))
                .font(.labelMedium)
                .foregroundColor(.green)
        case .disabled:
            EmptyView()
        case .notDownloaded:
            Text(String(format: localizationManager.text("preferences.acceleration.willDownload", fallback: "Descargará %@"), coreMLSize))
                .font(.system(size: 10))
                .foregroundColor(.orange)
        }
    }
}

// MARK: - Audio Preferences
private struct AudioPreferencesView: View {
    @EnvironmentObject var viewModel: TranscriptionViewModel
    @EnvironmentObject var localizationManager: LocalizationManager
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Preprocessing Section
            NativeSettingsSection(title: localizationManager.text("preferences.section.preprocessing", fallback: "PREPROCESAMIENTO")) {
                NativeToggleRow(
                    title: localizationManager.text("preferences.audio.noiseReduction.title", fallback: "Reducción de ruido"),
                    subtitle: localizationManager.text("preferences.audio.noiseReduction.subtitle", fallback: "DeepFilterNet"),
                    icon: "waveform.badge.minus",
                    iconColor: .blue,
                    isOn: $viewModel.settings.deepfilter
                )
                
                NativeToggleRow(
                    title: localizationManager.text("preferences.audio.voiceIsolation.title", fallback: "Aislar voz"),
                    subtitle: localizationManager.text("preferences.audio.voiceIsolation.subtitle", fallback: "Demucs"),
                    icon: "person.wave.2",
                    iconColor: .purple,
                    isOn: $viewModel.settings.isolateVoice
                )
                
                NativeToggleRow(
                    title: localizationManager.text("preferences.audio.normalize.title", fallback: "Normalizar volumen"),
                    subtitle: localizationManager.text("preferences.audio.normalize.subtitle", fallback: "EBU R128"),
                    icon: "speaker.wave.2",
                    iconColor: .green,
                    isOn: $viewModel.settings.normalize
                )
            }
            
            // VAD Section
            NativeSettingsSection(title: localizationManager.text("preferences.section.vad", fallback: "DETECCIÓN DE VOZ")) {
                NativeToggleRow(
                    title: localizationManager.text("preferences.audio.vad.title", fallback: "Detección de actividad de voz (VAD)"),
                    subtitle: localizationManager.text("preferences.audio.vad.subtitle", fallback: "Detecta segmentos con voz"),
                    icon: "mic.badge.plus",
                    iconColor: .orange,
                    isOn: $viewModel.settings.useVAD
                )
                
                if viewModel.settings.useVAD {
                    PreferencesSliderRow(
                        title: localizationManager.text("preferences.audio.vad.sensitivity", fallback: "Sensibilidad"),
                        value: $viewModel.settings.vadThreshold,
                        range: 0.3...0.9,
                        step: 0.1
                    )
                    
                    PreferencesSliderRow(
                        title: localizationManager.text("preferences.audio.vad.minSilence", fallback: "Silencio mínimo"),
                        value: Binding(
                            get: { Double(viewModel.settings.vadMinSilenceDuration) },
                            set: { viewModel.settings.vadMinSilenceDuration = Int($0) }
                        ),
                        range: 300...1500,
                        step: 100,
                        suffix: "ms"
                    )
                }
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: viewModel.settings.useVAD)
    }
}

// MARK: - Native Settings Components
private struct NativeSettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.labelMedium)
                .foregroundColor(.textTertiary)
                .tracking(0.3)
            
            VStack(spacing: 0) {
                content
            }
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
        }
    }
}

// MARK: - Native Slider Row (Preferences-specific)
private struct PreferencesSliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    var suffix: String = ""
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.bodySmall)
                    .foregroundColor(.textSecondary)
                
                Spacer()
                
                Text(suffix.isEmpty ? String(format: "%.1f", value) : "\(Int(value))\(suffix)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.textTertiary)
            }
            
            Slider(value: $value, in: range, step: step)
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

// MARK: - Advanced Preferences
private struct AdvancedPreferencesView: View {
    @EnvironmentObject var viewModel: TranscriptionViewModel
    @EnvironmentObject var localizationManager: LocalizationManager
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Context Section
            NativeSettingsSection(title: localizationManager.text("preferences.section.context", fallback: "CONTEXTO")) {
                VStack(alignment: .leading, spacing: 8) {
                    TextEditor(text: $viewModel.settings.initialPrompt)
                        .font(.mono)
                        .frame(height: 80)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .background(Color(nsColor: .textBackgroundColor))
                        .cornerRadius(6)
                    
                    Text(localizationManager.text("preferences.advanced.contextHint", fallback: "Vocabulario técnico para mejorar precisión"))
                        .font(.caption)
                        .foregroundColor(.textTertiary)
                }
                .padding(12)
            }
            
            // Actions Section
            NativeSettingsSection(title: localizationManager.text("preferences.section.actions", fallback: "ACCIONES")) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(localizationManager.text("preferences.advanced.reset.title", fallback: "Restablecer configuración"))
                            .font(.labelLarge)
                            .foregroundColor(.textPrimary)
                        
                        Text(localizationManager.text("preferences.advanced.reset.subtitle", fallback: "Vuelve a los valores predeterminados"))
                            .font(.caption)
                            .foregroundColor(.textTertiary)
                    }
                    
                    Spacer()
                    
                    Button(action: resetToDefaults) {
                        Text(localizationManager.text("preferences.advanced.reset.button", fallback: "Restablecer"))
                            .font(.labelBody)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .confirmationDialog(
                        localizationManager.text("preferences.advanced.reset.dialog.title", fallback: "¿Restablecer configuración?"),
                        isPresented: $showResetConfirmation,
                        titleVisibility: .visible
                    ) {
                        Button(localizationManager.text("preferences.advanced.reset.button", fallback: "Restablecer"), role: .destructive) {
                            confirmReset()
                        }
                        Button(localizationManager.text("preferences.cancel", fallback: "Cancelar"), role: .cancel) { }
                    } message: {
                        Text(localizationManager.text("preferences.advanced.reset.dialog.message", fallback: "Se restablecerán todos los ajustes a sus valores predeterminados."))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
        }
    }
    
    @State private var showResetConfirmation = false
    
    private func resetToDefaults() {
        showResetConfirmation = true
    }
    
    private func confirmReset() {
        viewModel.settings = TranscriptionSettings()
        viewModel.saveSettings()
    }
}



// MARK: - Flow Layout
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = FlowResult(in: proposal.width ?? 0, subviews: subviews, spacing: spacing)
        return result.size
    }
    
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = FlowResult(in: bounds.width, subviews: subviews, spacing: spacing)
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX + result.positions[index].x,
                                      y: bounds.minY + result.positions[index].y),
                         proposal: .unspecified)
        }
    }
    
    struct FlowResult {
        var size: CGSize = .zero
        var positions: [CGPoint] = []
        
        init(in maxWidth: CGFloat, subviews: Subviews, spacing: CGFloat) {
            var x: CGFloat = 0
            var y: CGFloat = 0
            var rowHeight: CGFloat = 0
            
            for subview in subviews {
                let size = subview.sizeThatFits(.unspecified)
                
                if x + size.width > maxWidth && x > 0 {
                    x = 0
                    y += rowHeight + spacing
                    rowHeight = 0
                }
                
                positions.append(CGPoint(x: x, y: y))
                rowHeight = max(rowHeight, size.height)
                x += size.width + spacing
                
                self.size.width = max(self.size.width, x)
            }
            
            self.size.height = y + rowHeight
        }
    }
}
