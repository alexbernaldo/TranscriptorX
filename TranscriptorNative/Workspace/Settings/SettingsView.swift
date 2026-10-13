import SwiftUI
import AppKit
import Carbon
import EventKit

/// Opens Ajustes at an exact section (links «Cambiar en Ajustes» across the app).
@MainActor
final class SettingsNavigator: ObservableObject {
    static let shared = SettingsNavigator()
    @Published var section: SettingsSection = .behavior
    /// SwiftUI's `openSettings`, registered by the main window. Since macOS 14 the
    /// `showSettingsWindow:` action is ignored, so it is only the fallback.
    var openAction: (() -> Void)?

    static func open(_ section: SettingsSection) {
        shared.section = section
        NSApp.activate(ignoringOtherApps: true)
        if let action = shared.openAction {
            action()
        } else {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
    }
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case behavior, models, language, recording, export, captions, dictation, ai, automation, privacy, updates
    var id: String { rawValue }

    var title: String {
        switch self {
        case .behavior: return TXL.t("settings.behavior", "Comportamiento")
        case .models: return TXL.t("settings.models", "Modelos")
        case .language: return TXL.t("settings.language", "Idioma")
        case .recording: return TXL.t("settings.recording", "Grabación")
        case .export: return TXL.t("settings.export", "Exportación")
        case .captions: return TXL.t("settings.captions", "Subtítulos en pantalla")
        case .dictation: return TXL.t("settings.dictation", "Dictado")
        case .ai: return TXL.t("settings.ai", "IA local")
        case .automation: return TXL.t("settings.automation", "Automatización")
        case .privacy: return TXL.t("settings.privacy", "Privacidad")
        case .updates: return TXL.t("settings.updates", "Actualizaciones")
        }
    }

    var icon: String {
        switch self {
        case .behavior: return "gearshape"
        case .models: return "cpu"
        case .language: return "globe"
        case .recording: return "mic"
        case .export: return "square.and.arrow.up"
        case .captions: return "captions.bubble"
        case .dictation: return "keyboard"
        case .ai: return "sparkles"
        case .automation: return "gearshape.2"
        case .privacy: return "hand.raised"
        case .updates: return "arrow.triangle.2.circlepath"
        }
    }
}

/// Ajustes (spec 6.20): 720 × 540 pt, 200 pt sidebar, grouped native form.
struct SettingsView: View {
    @ObservedObject private var navigator = SettingsNavigator.shared

    var body: some View {
        // Fixed 200 pt section list + detail. A NavigationSplitView sized its sidebar on its
        // own (144 pt, truncating «Comportamiento») and offered a collapse toggle.
        HStack(spacing: 0) {
            List(SettingsSection.allCases, selection: Binding(get: { navigator.section }, set: { if let s = $0 { navigator.section = s } })) { section in
                Label(section.title, systemImage: section.icon).tag(section)
            }
            .listStyle(.sidebar)
            .frame(width: 200)
            Divider()
            ScrollView {
                Group {
                    switch navigator.section {
                    case .behavior: BehaviorSettings()
                    case .models: ModelsSettings()
                    case .language: LanguageSettings()
                    case .recording: RecordingSettings()
                    case .export: ExportSettings()
                    case .captions: CaptionsSettings()
                    case .dictation: DictationSettings()
                    case .ai: AISettings()
                    case .automation: AutomationSettings()
                    case .privacy: PrivacySettings()
                    case .updates: UpdatesSettings()
                    }
                }
                .padding(TX.Space.s20)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .background(TX.Colors.bgWindow)
        }
        .navigationTitle(navigator.section.title)
        // 720 × 540 pt window: the title bar is 32 pt (measured).
        .frame(width: 720, height: 540 - 32)
    }
}

// MARK: - Shared form pieces (36 pt rows, label left, control right, help 11 secondary)

struct SettingsGroup<Content: View>: View {
    var title: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title { TXGroupHeader(title: title) }
            VStack(alignment: .leading, spacing: 0) { content() }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: TX.Radius.row, style: .continuous).fill(TX.Colors.bgSurface))
                .overlay(RoundedRectangle(cornerRadius: TX.Radius.row, style: .continuous).strokeBorder(TX.Colors.separator, lineWidth: 1))
        }
        .padding(.bottom, TX.Space.s16)
    }
}

struct SettingsRow<Control: View>: View {
    let label: String
    var help: String? = nil
    @ViewBuilder var control: () -> Control

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 12) {
                Text(label).font(.system(size: 13)).foregroundStyle(TX.Colors.textPrimary)
                Spacer(minLength: 12)
                control()
            }
            .frame(minHeight: TX.Size.settingsRow)
            // VoiceOver reads «label, switch, on» as one element (the controls hide their labels).
            .accessibilityElement(children: .combine)
            if let help {
                Text(help).font(.system(size: 11)).foregroundStyle(TX.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 6)
            }
        }
    }
}

/// Edits the default transcription settings (the app's existing `transcription_settings`).
@MainActor
final class DefaultsModel: ObservableObject {
    static let shared = DefaultsModel()
    @Published var settings: TranscriptionSettings = QuickSettingsModel.defaultSettings() {
        didSet { save() }
    }
    func save() {
        if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: "transcription_settings") }
        NotificationCenter.default.post(name: .defaultSettingsChanged, object: nil)
    }
    func reload() { settings = QuickSettingsModel.defaultSettings() }
}

extension Notification.Name {
    static let defaultSettingsChanged = Notification.Name("defaultSettingsChanged")
}

// MARK: - Comportamiento

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, dark, light
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return TXL.t("appearance.system", "Sistema")
        case .dark: return TXL.t("appearance.dark", "Oscura")
        case .light: return TXL.t("appearance.light", "Clara")
        }
    }

    /// Dark is the default identity (spec 3.5).
    static var current: AppearanceMode { AppearanceMode(rawValue: UserDefaults.standard.string(forKey: "appearanceMode") ?? "dark") ?? .dark }

    @MainActor static func apply(_ mode: AppearanceMode) {
        switch mode {
        case .system: NSApp.appearance = nil
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        }
    }
}

private struct BehaviorSettings: View {
    @EnvironmentObject var localizationManager: LocalizationManager
    @AppStorage("appearanceMode") private var appearance = AppearanceMode.dark.rawValue
    @AppStorage("transcriptSize") private var transcriptSize = TX.TranscriptSize.normal.rawValue
    @AppStorage("trashRetentionDays") private var retention = 30
    @AppStorage("showMenuBarExtra") private var showMenuBarExtra = true
    @AppStorage("keepRunningInBackground") private var keepRunning = true
    @AppStorage("announceLiveSegments") private var announceSegments = true
    @AppStorage("hideDockIcon") private var hideDockIcon = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroup {
                SettingsRow(label: TXL.t("settings.appearance", "Apariencia")) {
                    Picker("", selection: $appearance) {
                        ForEach(AppearanceMode.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    .txOnChange(of: appearance) { AppearanceMode.apply(AppearanceMode(rawValue: $0) ?? .dark) }
                }
                TXSeparator()
                SettingsRow(label: TXL.t("settings.transcriptSize", "Tamaño del texto de transcripción")) {
                    Picker("", selection: $transcriptSize) {
                        Text(TXL.t("size.small", "Pequeño")).tag(TX.TranscriptSize.small.rawValue)
                        Text(TXL.t("size.normal", "Normal")).tag(TX.TranscriptSize.normal.rawValue)
                        Text(TXL.t("size.large", "Grande")).tag(TX.TranscriptSize.large.rawValue)
                        Text(TXL.t("size.extraLarge", "Muy grande")).tag(TX.TranscriptSize.extraLarge.rawValue)
                    }
                    .labelsHidden().fixedSize()
                }
                TXSeparator()
                SettingsRow(label: TXL.t("settings.retention", "Conservar eliminados")) {
                    Picker("", selection: $retention) {
                        ForEach([7, 14, 30, 90], id: \.self) { Text(TXL.n("settings.days", "%d día", "%d días", $0)).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                TXSeparator()
                SettingsRow(label: TXL.t("settings.uiLanguage", "Idioma de la interfaz")) {
                    Picker("", selection: Binding(get: { localizationManager.appLanguage }, set: { localizationManager.setLanguage($0) })) {
                        ForEach(AppLanguage.supportedInterfaceLanguages) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
            }
            SettingsGroup {
                SettingsRow(label: TXL.t("settings.hideDock", "Ocultar del Dock"),
                            help: TXL.t("settings.hideDock.help", "Transcriptor X solo aparece en la barra de menús. Ábrelo desde su icono.")) {
                    Toggle("", isOn: $hideDockIcon).toggleStyle(.switch).labelsHidden()
                        .txOnChange(of: hideDockIcon) { _ in DockVisibility.apply() }
                }
                TXSeparator()
                SettingsRow(label: TXL.t("settings.menubar", "Mostrar en la barra de menús"),
                            help: hideDockIcon ? TXL.t("settings.menubar.required", "Sin icono en el Dock, es la forma de volver a la app.") : nil) {
                    Toggle("", isOn: $showMenuBarExtra).toggleStyle(.switch).labelsHidden().disabled(hideDockIcon)
                }
                TXSeparator()
                SettingsRow(label: TXL.t("settings.keepRunning", "Seguir funcionando al cerrar la ventana"),
                            help: TXL.t("settings.keepRunning.help", "La grabación, la cola, el dictado y los subtítulos siguen activos.")) {
                    Toggle("", isOn: hideDockIcon ? .constant(true) : $keepRunning).toggleStyle(.switch).labelsHidden()
                        .disabled(!showMenuBarExtra || hideDockIcon)
                }
                TXSeparator()
                SettingsRow(label: TXL.t("settings.announceSegments", "Leer los segmentos que llegan con VoiceOver"),
                            help: TXL.t("settings.announceSegments.help", "Como máximo un anuncio cada 4 s con lo acumulado.")) {
                    Toggle("", isOn: $announceSegments).toggleStyle(.switch).labelsHidden()
                }
            }
        }
    }
}

// MARK: - Modelos (spec 6.21)

private struct ModelsSettings: View {
    var body: some View {
        ModelsSettingsDetailView()
    }
}

/// Model table (spec 6.21): default (radio), model, languages, size, acceleration, state/action.
///
/// Built with `Grid` instead of `Table`: the inset `Table` adds ~17 pt of padding per column
/// and its six columns do not fit the 480 pt of the Settings detail without horizontal scrolling.
struct ModelTable: View {
    @Binding var defaultModel: String
    var compact = false
    @ObservedObject private var downloads = ModelDownloadCenter.shared

    var body: some View {
        let rows = ModelCapabilities.catalogue
        ScrollView {
            Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 0) {
                GridRow {
                    header(TXL.t("models.col.default", "Por defecto"))
                    header(TXL.t("models.col.model", "Modelo"))
                    header(TXL.t("models.col.languages", "Idiomas"))
                    header(TXL.t("models.col.size", "Tamaño"))
                    header(TXL.t("models.col.acceleration", "Aceleración"))
                    header(TXL.t("models.col.state", "Estado"))
                }
                .frame(height: 28)
                ForEach(rows) { entry in
                    Divider().gridCellUnsizedAxes(.horizontal)
                    GridRow {
                        Button { defaultModel = entry.id } label: {
                            Image(systemName: defaultModel == entry.id ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(defaultModel == entry.id ? TX.Colors.purpleX : TX.Colors.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(TXL.f("models.setDefault", "Usar %@ por defecto", entry.id))
                        .accessibilityAddTraits(defaultModel == entry.id ? .isSelected : [])
                        Text(entry.id).font(.system(size: 12, weight: .medium)).lineLimit(1).fixedSize()
                        Text(entry.englishOnly ? TXL.t("models.englishOnly", "Solo inglés") : TXL.t("models.multilingual", "Multilingüe"))
                            .font(.system(size: 12)).lineLimit(1).fixedSize()
                        Text(entry.size).font(.system(size: 12).monospacedDigit()).lineLimit(1).fixedSize()
                            .gridColumnAlignment(.trailing)
                        Text(entry.neuralEngine ? "Neural Engine" : "")
                            .font(.system(size: 12)).lineLimit(1).fixedSize()
                            .foregroundStyle(TX.Colors.textSecondary)
                        ModelStateCell(modelId: entry.id)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 36)
                }
            }
            .padding(.horizontal, 10)
        }
        .background(RoundedRectangle(cornerRadius: TX.Radius.row, style: .continuous).fill(TX.Colors.bgSurface))
        .overlay(RoundedRectangle(cornerRadius: TX.Radius.row, style: .continuous).strokeBorder(TX.Colors.separator, lineWidth: 1))
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(TX.Colors.textSecondary)
            .lineLimit(1)
    }
}

struct ModelStateCell: View {
    let modelId: String
    @ObservedObject private var downloads = ModelDownloadCenter.shared

    var body: some View {
        switch downloads.state(for: modelId) {
        case .downloading(let received, let total):
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(total > 0 ? TXL.f("models.downloadingPercent", "Descargando · %d %%", Int(Double(received) / Double(total) * 100)) : TXL.t("models.downloading", "Descargando…"))
                        .font(.system(size: 11).monospacedDigit())
                        .lineLimit(2)
                    // Determinate bar under the label (spec 6.21).
                    TXProgressLine(kind: total > 0 ? .determinate(Double(received) / Double(total)) : .indeterminate, height: 2)
                        .frame(height: 2)
                        .accessibilityHidden(true)
                }
                Button { downloads.cancel(modelId) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(TX.Colors.textSecondary)
                    .help(TXL.t("model.cancelDownload", "Cancelar descarga"))
                    .accessibilityLabel(TXL.t("model.cancelDownload", "Cancelar descarga"))
            }
        case .pending:
            Text(TXL.t("models.pending", "En espera")).font(.system(size: 12)).foregroundStyle(TX.Colors.textSecondary)
        case .failed:
            Button(TXL.t("common.retry", "Reintentar")) { downloads.download(modelId) }
                .buttonStyle(TXBorderlessButtonStyle())
                .help(TXL.f("model.downloadFailed.title", "No se pudo descargar %@", modelId))
        case nil:
            if downloads.revision >= 0 && downloads.isDownloaded(modelId) {
                Text(TXL.t("models.state.downloaded", "Descargado")).font(.system(size: 12)).foregroundStyle(TX.Colors.textSecondary)
            } else {
                Button(TXL.t("model.download", "Descargar")) { downloads.download(modelId) }
                    .buttonStyle(TXBorderlessButtonStyle())
            }
        }
    }
}

// MARK: - Idioma (defaults for new jobs)

private struct LanguageSettings: View {
    @ObservedObject private var defaults = DefaultsModel.shared
    @AppStorage("defaults.preset") private var defaultPreset = ""
    @State private var showReset = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroup {
                SettingsRow(label: TXL.t("settings.defaultLanguage", "Idioma de transcripción por defecto")) {
                    Picker("", selection: $defaults.settings.language) {
                        ForEach(TranscriptionLanguages.codes, id: \.self) { Text(TXFormat.languageName($0)).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                TXSeparator()
                SettingsRow(label: TXL.t("settings.defaultPreset", "Preset por defecto")) {
                    Picker("", selection: $defaultPreset) {
                        Text(TXL.t("preset.none", "Ninguno")).tag("")
                        ForEach(QuickSettingsModel.presetIds, id: \.self) { Text(QuickSettingsModel.presetTitle($0) ?? $0).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
            }
            SettingsGroup(title: TXL.t("options.group.audio", "Audio")) {
                SettingsRow(label: TXL.t("options.noise", "Reducción de ruido"), help: TXL.t("options.noise.help", "Demucs separa la voz de la música; es más lento")) {
                    Picker("", selection: Binding(
                        get: { defaults.settings.isolateVoice ? "demucs" : (defaults.settings.deepfilter ? "deepfilter" : "off") },
                        set: { defaults.settings.deepfilter = $0 == "deepfilter"; defaults.settings.isolateVoice = $0 == "demucs" })) {
                        Text(TXL.t("options.noise.off", "Desactivada")).tag("off")
                        Text(verbatim: "DeepFilter").tag("deepfilter")
                        Text(verbatim: "Demucs").tag("demucs")
                    }
                    .labelsHidden().fixedSize()
                }
                TXSeparator()
                SettingsRow(label: TXL.t("options.normalize", "Normalizar volumen")) {
                    Toggle("", isOn: $defaults.settings.normalize).toggleStyle(.switch).labelsHidden()
                }
                TXSeparator()
                SettingsRow(label: TXL.t("options.vad", "Detección de voz"), help: TXL.t("options.vad.help", "Omite los tramos sin voz")) {
                    Toggle("", isOn: $defaults.settings.useVAD).toggleStyle(.switch).labelsHidden()
                }
                if defaults.settings.useVAD {
                    SettingsRow(label: TXL.t("settings.vadSensitivity", "Sensibilidad")) {
                        Slider(value: $defaults.settings.vadThreshold, in: 0.3...0.9, step: 0.1).frame(width: 160)
                        Text(String(format: "%.1f", defaults.settings.vadThreshold)).font(.system(size: 11, design: .monospaced)).frame(width: 30)
                    }
                    SettingsRow(label: TXL.t("settings.vadSilence", "Silencio mínimo")) {
                        Slider(value: Binding(get: { Double(defaults.settings.vadMinSilenceDuration) }, set: { defaults.settings.vadMinSilenceDuration = Int($0) }),
                               in: 300...1500, step: 100).frame(width: 160)
                        Text("\(defaults.settings.vadMinSilenceDuration) ms").font(.system(size: 11, design: .monospaced)).frame(width: 60)
                    }
                }
            }
            SettingsGroup(title: TXL.t("options.group.transcription", "Transcripción")) {
                SettingsRow(label: TXL.t("options.speakers", "Identificar hablantes"),
                            help: ModelCapabilities.speakersHelp) {
                    Toggle("", isOn: $defaults.settings.enableDiarization).toggleStyle(.switch).labelsHidden()
                }
                TXSeparator()
                SettingsRow(label: TXL.t("options.translate", "Traducir al inglés al transcribir")) {
                    Toggle("", isOn: $defaults.settings.translate).toggleStyle(.switch).labelsHidden()
                }
                TXSeparator()
                SettingsRow(label: TXL.t("settings.suppressFillers", "Suprimir muletillas"), help: TXL.t("settings.suppressFillers.help", "Reduce «eh», «mm» y sonidos que no son voz")) {
                    Toggle("", isOn: $defaults.settings.suppressNonSpeech).toggleStyle(.switch).labelsHidden()
                }
                TXSeparator()
                SettingsRow(label: TXL.t("settings.keepAudio", "Guardar el audio con la transcripción"),
                            help: TXL.t("settings.keepAudio.help", "Necesario para reproducir y para guardar proyectos con audio.")) {
                    Toggle("", isOn: $defaults.settings.keepAudioFileInHistory).toggleStyle(.switch).labelsHidden()
                }
            }
            SettingsGroup(title: TXL.t("settings.advanced", "Avanzado")) {
                SettingsRow(label: TXL.t("settings.temperature", "Temperatura"), help: TXL.t("settings.temperature.help", "0 da el resultado más estable.")) {
                    Slider(value: $defaults.settings.temperature, in: 0...1, step: 0.1).frame(width: 160)
                    Text(String(format: "%.1f", defaults.settings.temperature)).font(.system(size: 11, design: .monospaced)).frame(width: 30)
                }
                TXSeparator()
                VStack(alignment: .leading, spacing: 4) {
                    Text(TXL.t("settings.context", "Contexto")).font(.system(size: 13))
                    TextEditor(text: $defaults.settings.initialPrompt)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(height: 60)
                        .scrollContentBackground(.hidden)
                        .background(RoundedRectangle(cornerRadius: TX.Radius.control).fill(TX.Colors.bgWindow))
                    Text(TXL.t("settings.context.help", "Vocabulario o nombres que ayudan a la precisión."))
                        .font(.system(size: 11)).foregroundStyle(TX.Colors.textSecondary)
                }
                .padding(.vertical, 8)
                TXSeparator()
                SettingsRow(label: TXL.t("settings.reset", "Restablecer la configuración de transcripción")) {
                    Button(TXL.t("settings.reset.button", "Restablecer…")) {
                        let alert = NSAlert()
                        alert.messageText = TXL.t("settings.reset.title", "¿Restablecer la configuración de transcripción?")
                        alert.informativeText = TXL.t("settings.reset.text", "Se recuperan los valores iniciales de idioma, modelo y opciones. El historial no cambia.")
                        alert.addButton(withTitle: TXL.t("settings.reset.confirm", "Restablecer"))
                        alert.addButton(withTitle: TXL.t("common.cancel", "Cancelar")).keyEquivalent = "\u{1b}"
                        if alert.runModal() == .alertFirstButtonReturn { defaults.settings = .default }
                    }
                    .buttonStyle(TXSecondaryButtonStyle(destructive: true))
                }
            }
        }
    }
}

// MARK: - Grabación

private struct RecordingSettings: View {
    @ObservedObject private var recorder = SystemAudioRecorder.shared
    @ObservedObject private var defaults = DefaultsModel.shared
    @State private var calendarStatus = EKEventStore.authorizationStatus(for: .event)

    var body: some View {
        SettingsGroup {
            SettingsRow(label: TXL.t("settings.defaultSource", "Fuente por defecto"),
                        help: TXL.t("settings.defaultSource.help", "Transcriptor X graba una fuente cada vez.")) {
                Picker("", selection: $recorder.selectedSource) {
                    Text(TXL.t("record.source.mic", "Micrófono")).tag(SystemAudioRecorder.AudioSource.microphone)
                    Text(TXL.t("record.source.system", "Audio del sistema")).tag(SystemAudioRecorder.AudioSource.system)
                }
                .labelsHidden().fixedSize()
            }
            TXSeparator()
            SettingsRow(label: TXL.t("settings.defaultMic", "Micrófono por defecto")) {
                Picker("", selection: Binding(get: { recorder.selectedMicrophone?.id ?? 0 },
                                              set: { id in recorder.selectedMicrophone = recorder.availableMicrophones.first { $0.id == id } })) {
                    ForEach(recorder.availableMicrophones) { Text($0.name).tag($0.id) }
                }
                .labelsHidden().fixedSize()
            }
            TXSeparator()
            SettingsRow(label: TXL.t("settings.meetings", "Detectar reuniones"),
                        help: TXL.t("settings.meetings.help", "Avisa desde 5 minutos antes hasta 5 minutos después del inicio, o cuando se abre una app de reuniones.") + " " + calendarLine) {
                Toggle("", isOn: Binding(get: { defaults.settings.autoDetectMeetings }, set: { enabled in
                    defaults.settings.autoDetectMeetings = enabled
                    MeetingWatcherService.shared.start(enabled: enabled)
                    if enabled { requestCalendar() }
                }))
                .toggleStyle(.switch).labelsHidden()
            }
        }
    }

    private var calendarLine: String {
        switch calendarStatus {
        case .fullAccess, .authorized: return TXL.t("settings.calendar.granted", "Calendario: acceso concedido.")
        case .notDetermined: return TXL.t("settings.calendar.notDetermined", "Calendario: se pedirá al activar la opción.")
        default: return TXL.t("settings.calendar.denied", "Calendario sin acceso: la detección usa solo las apps de reuniones abiertas.")
        }
    }

    /// «Para avisarte cuando empiece una reunión, la app lee la hora y el título de tus eventos.»
    private func requestCalendar() {
        guard EKEventStore.authorizationStatus(for: .event) == .notDetermined else { return }
        let alert = NSAlert()
        alert.messageText = TXL.t("permission.calendar.title", "Acceso al calendario")
        alert.informativeText = TXL.t("permission.calendar.explain", "Para avisarte cuando empiece una reunión, la app lee la hora y el título de tus eventos. No modifica tu calendario.")
        alert.addButton(withTitle: TXL.t("common.continue", "Continuar"))
        alert.addButton(withTitle: TXL.t("common.notNow", "Ahora no")).keyEquivalent = "\u{1b}"
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let store = EKEventStore()
        Task {
            if #available(macOS 14.0, *) {
                _ = try? await store.requestFullAccessToEvents()
            } else {
                _ = try? await store.requestAccess(to: .event)
            }
            calendarStatus = EKEventStore.authorizationStatus(for: .event)
        }
    }
}

// MARK: - Exportación

private struct ExportSettings: View {
    @State private var refresh = 0
    var body: some View {
        SettingsGroup {
            ForEach(ExportKind.allCases) { kind in
                SettingsRow(label: "\(kind.name) · \(kind.extensionLabel)") {
                    Text(ExportKindOptions.load(kind).summary(for: kind))
                        .font(.system(size: 11)).foregroundStyle(TX.Colors.textSecondary)
                        .id(refresh)
                    Button(TXL.t("settings.export.reset", "Restablecer")) { ExportKindOptions.reset(kind); refresh += 1 }
                        .buttonStyle(TXBorderlessButtonStyle())
                }
                if kind != ExportKind.allCases.last { TXSeparator() }
            }
        }
    }
}

// MARK: - Subtítulos en pantalla (spec 6.24)

private struct CaptionsSettings: View {
    @AppStorage("liveCaptionEnabled") private var enabled = false
    @AppStorage("liveCaptionDelay") private var delay = 2.0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroup {
                SettingsRow(label: TXL.t("settings.captions", "Subtítulos en pantalla"),
                            help: TXL.t("settings.captions.help", "Muestran la última frase de la transcripción en curso sobre cualquier app y desaparecen 4 s después.")) {
                    Toggle("", isOn: $enabled).toggleStyle(.switch).labelsHidden()
                }
                TXSeparator()
                SettingsRow(label: TXL.t("settings.captions.delay", "Retardo")) {
                    Slider(value: $delay, in: 1...4, step: 1) { EmptyView() } minimumValueLabel: { Text(verbatim: "1") } maximumValueLabel: { Text(verbatim: "4") }
                        .frame(width: 180)
                        .accessibilityValue(TXL.f("settings.captions.delay.value", "%d s", Int(delay)))
                    Text(TXL.f("settings.captions.delay.value", "%d s", Int(delay)))
                        .font(.system(size: 12, design: .monospaced).monospacedDigit()).frame(width: 34)
                }
            }
            HStack {
                Spacer()
                CaptionText(text: TXL.t("settings.captions.sample", "Así se verán los subtítulos"))
                Spacer()
            }
            .padding(.vertical, 24)
            .background(RoundedRectangle(cornerRadius: TX.Radius.row).fill(Color(nsColor: TX.Palette.window)))
            .accessibilityHidden(true)
        }
    }
}

// MARK: - Dictado (spec 6.23, options from Handy)

private struct DictationSettings: View {
    @ObservedObject private var dictation = DictationManager.shared
    @ObservedObject private var recorder = SystemAudioRecorder.shared
    @AppStorage("dictation.activation") private var activation = DictationPreferences.Activation.automatic.rawValue
    @AppStorage("dictation.sounds") private var sounds = true
    @AppStorage("dictation.soundVolume") private var volume = 0.5
    @AppStorage("dictation.muteWhileRecording") private var muteWhileRecording = false
    @AppStorage("dictation.microphone") private var microphone = ""
    @AppStorage("dictation.language") private var language = DictationPreferences.useDefault
    @AppStorage("dictation.model") private var model = DictationPreferences.useDefault
    @AppStorage("dictation.translate") private var translate = false
    @AppStorage("dictation.removeFillers") private var removeFillers = true
    @AppStorage("dictation.insertion") private var insertion = DictationPreferences.Insertion.paste.rawValue
    @AppStorage("dictation.keepInClipboard") private var keepInClipboard = false
    @AppStorage("dictation.autoSubmit") private var autoSubmit = DictationPreferences.AutoSubmit.off.rawValue
    @AppStorage("dictation.trailingSpace") private var trailingSpace = true
    @AppStorage("dictation.overlay") private var overlay = DictationPreferences.OverlayPosition.bottom.rawValue
    @AppStorage("hasSeenFastDictationNotice") private var hasSeenFastDictationNotice = false
    @State private var axTrusted = AXIsProcessTrusted()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroup {
                SettingsRow(label: TXL.t("settings.dictation.enable", "Activar el dictado"),
                            help: TXL.t("settings.dictation.enable.help", "Dicta en cualquier app con un atajo de teclado. El texto aparece donde está el cursor.")) {
                    Toggle("", isOn: $dictation.isEnabled).toggleStyle(.switch).labelsHidden()
                }
                TXSeparator()
                SettingsRow(label: TXL.t("settings.dictation.shortcut", "Atajo"),
                            help: dictation.shortcutConflict
                                ? TXL.t("settings.dictation.shortcut.conflict", "Otra app usa este atajo. Elige otro.")
                                : TXL.t("settings.dictation.shortcut.help", "Haz clic y pulsa la combinación que quieras. Necesita ⌘, ⌃ u ⌥, o una tecla de función.")) {
                    ShortcutRecorder()
                }
                .disabled(!dictation.isEnabled)
                TXSeparator()
                SettingsRow(label: TXL.t("settings.dictation.activation", "Modo del atajo"),
                            help: activationHelp) {
                    Picker("", selection: $activation) {
                        Text(TXL.t("settings.dictation.activation.automatic", "Automático")).tag(DictationPreferences.Activation.automatic.rawValue)
                        Text(TXL.t("settings.dictation.activation.hold", "Mantener")).tag(DictationPreferences.Activation.hold.rawValue)
                        Text(TXL.t("settings.dictation.activation.toggle", "Pulsar")).tag(DictationPreferences.Activation.toggle.rawValue)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                .disabled(!dictation.isEnabled)
                TXSeparator()
                SettingsRow(label: TXL.t("settings.dictation.accessibility", "Permiso de Accesibilidad"),
                            help: TXL.t("settings.dictation.accessibility.help", "Hace falta para pegar el texto en otras apps.")) {
                    if axTrusted {
                        Text(TXL.t("settings.dictation.ax.granted", "Concedido"))
                            .font(.system(size: 12)).foregroundStyle(TX.Colors.textSecondary)
                    } else {
                        Button(TXL.t("settings.dictation.ax.grant", "Conceder…")) {
                            dictation.promptAccessibilityIfNeeded()
                        }
                        .buttonStyle(TXSecondaryButtonStyle())
                    }
                }
            }

            SettingsGroup(title: TXL.t("settings.dictation.group.sound", "Micrófono y sonido")) {
                SettingsRow(label: TXL.t("settings.dictation.microphone", "Micrófono")) {
                    Picker("", selection: $microphone) {
                        Text(TXL.t("settings.dictation.microphone.default", "El del sistema")).tag("")
                        ForEach(recorder.availableMicrophones, id: \.name) { Text($0.name).tag($0.name) }
                    }
                    .labelsHidden().fixedSize()
                }
                TXSeparator()
                SettingsRow(label: TXL.t("settings.dictation.sounds", "Sonido al empezar y al terminar")) {
                    Toggle("", isOn: $sounds).toggleStyle(.switch).labelsHidden()
                }
                if sounds {
                    TXSeparator()
                    SettingsRow(label: TXL.t("settings.dictation.volume", "Volumen")) {
                        Slider(value: $volume, in: 0.05...1) { editing in
                            if !editing { DictationManager.previewSound() }
                        }
                        .frame(width: 160)
                        .accessibilityLabel(TXL.t("settings.dictation.volume", "Volumen"))
                    }
                }
                TXSeparator()
                SettingsRow(label: TXL.t("settings.dictation.mute", "Silenciar los altavoces mientras dictas"),
                            help: TXL.t("settings.dictation.mute.help", "Así la música o un vídeo no se cuelan en el texto. Vuelven al terminar.")) {
                    Toggle("", isOn: $muteWhileRecording).toggleStyle(.switch).labelsHidden()
                }
            }

            SettingsGroup(title: TXL.t("settings.dictation.group.text", "Texto")) {
                SettingsRow(label: TXL.t("settings.dictation.language", "Idioma")) {
                    Picker("", selection: $language) {
                        Text(TXL.t("settings.dictation.asDefaults", "Como en Ajustes › Idioma")).tag(DictationPreferences.useDefault)
                        Divider()
                        ForEach(TranscriptionLanguages.codes, id: \.self) { Text(TXFormat.languageName($0)).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                TXSeparator()
                SettingsRow(label: TXL.t("settings.dictation.model", "Modelo"),
                            help: TXL.t("settings.dictation.model.help", "Un modelo pequeño pega antes; uno grande se equivoca menos.")) {
                    Picker("", selection: $model) {
                        Text(TXL.t("settings.dictation.asDefaults", "Como en Ajustes › Idioma")).tag(DictationPreferences.useDefault)
                        Divider()
                        ForEach(ModelCapabilities.catalogue) { entry in
                            let name = ModelCatalog.formattedName(for: entry.id, showTechnical: TaskModelPreferences.shared.showTechnicalNames)
                            Text(name).tag(entry.id)
                        }
                    }
                    .labelsHidden().fixedSize()
                }
                if model == "base" && !hasSeenFastDictationNotice {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(TXL.t("settings.dictation.fastSuggestion", "Hay un modelo de dictado más rápido y preciso: Rápido (Parakeet)."))
                            .font(.system(size: 11))
                            .foregroundStyle(TX.Colors.textPrimary)
                        HStack(spacing: 8) {
                            Button(TXL.t("settings.dictation.changeToFast", "Cambiar a Rápido")) {
                                model = "parakeet-tdt-0.6b-v3"
                                hasSeenFastDictationNotice = true
                            }
                            .buttonStyle(TXPrimaryButtonStyle())
                            .controlSize(.small)
                            Button(TXL.t("settings.dictation.keepLight", "Mantener Ligero")) {
                                hasSeenFastDictationNotice = true
                            }
                            .buttonStyle(TXSecondaryButtonStyle())
                            .controlSize(.small)
                        }
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(TX.Colors.purpleX.opacity(0.08)))
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
                }
                TXSeparator()
                SettingsRow(label: TXL.t("settings.dictation.translate", "Traducir al inglés")) {
                    Toggle("", isOn: $translate).toggleStyle(.switch).labelsHidden()
                }
                TXSeparator()
                SettingsRow(label: TXL.t("settings.dictation.fillers", "Quitar muletillas"),
                            help: TXL.t("settings.dictation.fillers.help", "Quita «eh», «mmm» y las palabras repetidas por titubeo.")) {
                    Toggle("", isOn: $removeFillers).toggleStyle(.switch).labelsHidden()
                }
                TXSeparator()
                CustomWordsEditor()
            }

            SettingsGroup(title: TXL.t("settings.dictation.group.insert", "Pegado")) {
                SettingsRow(label: TXL.t("settings.dictation.insertion", "Cómo llega el texto"), help: insertionHelp) {
                    Picker("", selection: $insertion) {
                        Text(TXL.t("settings.dictation.insertion.paste", "Pegar")).tag(DictationPreferences.Insertion.paste.rawValue)
                        Text(TXL.t("settings.dictation.insertion.type", "Escribir")).tag(DictationPreferences.Insertion.type.rawValue)
                        Text(TXL.t("settings.dictation.insertion.copy", "Solo copiar")).tag(DictationPreferences.Insertion.copyOnly.rawValue)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                if insertion == DictationPreferences.Insertion.paste.rawValue {
                    TXSeparator()
                    SettingsRow(label: TXL.t("settings.dictation.keepClipboard", "Dejar el dictado en el portapapeles"),
                                help: TXL.t("settings.dictation.keepClipboard.help", "Si está apagado, el portapapeles vuelve a tener lo que había antes.")) {
                        Toggle("", isOn: $keepInClipboard).toggleStyle(.switch).labelsHidden()
                    }
                }
                if insertion != DictationPreferences.Insertion.copyOnly.rawValue {
                    TXSeparator()
                    SettingsRow(label: TXL.t("settings.dictation.autoSubmit", "Enviar al terminar"),
                                help: TXL.t("settings.dictation.autoSubmit.help", "Pulsa Intro por ti, útil en chats.")) {
                        Picker("", selection: $autoSubmit) {
                            Text(TXL.t("settings.dictation.autoSubmit.off", "No")).tag(DictationPreferences.AutoSubmit.off.rawValue)
                            Text(TXL.t("settings.dictation.autoSubmit.enter", "Intro")).tag(DictationPreferences.AutoSubmit.enter.rawValue)
                            Text(verbatim: "⌘ Intro").tag(DictationPreferences.AutoSubmit.commandEnter.rawValue)
                        }
                        .labelsHidden().fixedSize()
                    }
                }
                TXSeparator()
                SettingsRow(label: TXL.t("settings.dictation.trailingSpace", "Añadir un espacio al final"),
                            help: TXL.t("settings.dictation.trailingSpace.help", "Para seguir dictando sin juntar las frases.")) {
                    Toggle("", isOn: $trailingSpace).toggleStyle(.switch).labelsHidden()
                }
            }

            SettingsGroup(title: TXL.t("settings.dictation.group.indicator", "Indicador")) {
                SettingsRow(label: TXL.t("settings.dictation.overlay", "Dónde aparece"),
                            help: TXL.t("settings.dictation.overlay.help", "La cápsula que dice «Escuchando…». Los avisos de permisos aparecen siempre.")) {
                    Picker("", selection: $overlay) {
                        Text(TXL.t("settings.dictation.overlay.bottom", "Abajo")).tag(DictationPreferences.OverlayPosition.bottom.rawValue)
                        Text(TXL.t("settings.dictation.overlay.top", "Arriba")).tag(DictationPreferences.OverlayPosition.top.rawValue)
                        Text(TXL.t("settings.dictation.overlay.hidden", "Oculto")).tag(DictationPreferences.OverlayPosition.hidden.rawValue)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
            }

            Text(TXL.t("settings.dictation.note", "El dictado no pasa por la cola ni se guarda en el historial."))
                .font(.system(size: 12)).foregroundStyle(TX.Colors.textSecondary)
        }
        .onAppear {
            recorder.refreshMicrophoneList()
            axTrusted = AXIsProcessTrusted()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            axTrusted = AXIsProcessTrusted()
        }
    }

    private var activationHelp: String {
        switch DictationPreferences.Activation(rawValue: activation) ?? .automatic {
        case .automatic: return TXL.t("settings.dictation.activation.automatic.help", "Mantén pulsado y suelta para pegar, o pulsa una vez para empezar y otra para pegar.")
        case .hold: return TXL.t("settings.dictation.activation.hold.help", "Dicta mientras mantienes pulsado el atajo. Al soltar, se pega.")
        case .toggle: return TXL.t("settings.dictation.activation.toggle.help", "Pulsa una vez para empezar y otra para pegar.")
        }
    }

    private var insertionHelp: String {
        switch DictationPreferences.Insertion(rawValue: insertion) ?? .paste {
        case .paste: return TXL.t("settings.dictation.insertion.paste.help", "Rápido y funciona en casi todas las apps.")
        case .type: return TXL.t("settings.dictation.insertion.type.help", "Para campos que no dejan pegar. Más lento con textos largos.")
        case .copyOnly: return TXL.t("settings.dictation.insertion.copy.help", "No toca la app en uso: pega tú con ⌘V cuando quieras.")
        }
    }
}

/// Click, then press the new shortcut. Esc leaves it as it was.
private struct ShortcutRecorder: View {
    @ObservedObject private var dictation = DictationManager.shared
    @State private var listening = false
    @State private var monitor: Any?
    @State private var rejected = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 6) {
            Button {
                listening ? stop() : start()
            } label: {
                Text(listening ? TXL.t("settings.dictation.shortcut.listening", "Pulsa el atajo…") : dictation.shortcut.displayName)
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(listening ? TX.Colors.accentText : TX.Colors.textPrimary)
                    .frame(minWidth: 120)
                    .padding(.horizontal, 10)
                    .frame(height: TX.Size.control)
                    .background(RoundedRectangle(cornerRadius: TX.Radius.control, style: .continuous).fill(TX.Colors.bgControl))
                    .overlay(RoundedRectangle(cornerRadius: TX.Radius.control, style: .continuous)
                        .strokeBorder(listening ? TX.Colors.purpleX : (rejected ? TX.Colors.error : .clear), lineWidth: 1))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(TXL.f("settings.dictation.shortcut.a11y", "Atajo de dictado, %@", dictation.shortcut.displayName))
            .accessibilityHint(TXL.t("settings.dictation.shortcut.a11yHint", "Actívalo y pulsa la combinación nueva"))
            if dictation.shortcut != .standard && !listening {
                Button {
                    dictation.setShortcut(.standard)
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(TXIconButtonStyle(iconSize: 12))
                .help(TXL.t("settings.dictation.shortcut.reset", "Volver a ⌃⌥ Espacio"))
                .accessibilityLabel(TXL.t("settings.dictation.shortcut.reset", "Volver a ⌃⌥ Espacio"))
            }
        }
        .opacity(isEnabled ? 1 : 0.5)
        .onDisappear { stop() }
    }

    private func start() {
        rejected = false
        listening = true
        // The current shortcut would be swallowed by the system before reaching us.
        dictation.suspendHotKey()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) && event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
                stop()
                return nil
            }
            guard let shortcut = DictationShortcut(event: event) else {
                rejected = true
                NSSound.beep()
                return nil
            }
            stop(resume: false)
            if !dictation.setShortcut(shortcut) {
                rejected = true
                dictation.resumeHotKey()
            }
            return nil
        }
    }

    private func stop(resume: Bool = true) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard listening else { return }
        listening = false
        if resume { dictation.resumeHotKey() }
    }
}

/// Names and terms whisper should spell right (Handy's «Palabras personalizadas»).
private struct CustomWordsEditor: View {
    @State private var words = DictationPreferences.customWords
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(TXL.t("settings.dictation.words", "Palabras que debe conocer"))
                        .font(.system(size: 13)).foregroundStyle(TX.Colors.textPrimary)
                    Text(TXL.t("settings.dictation.words.help", "Nombres, marcas o términos técnicos, escritos como quieres verlos."))
                        .font(.system(size: 11)).foregroundStyle(TX.Colors.textSecondary)
                }
                Spacer(minLength: 12)
                TextField(TXL.t("settings.dictation.words.placeholder", "Añadir palabra"), text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
                    .onSubmit(add)
                    .accessibilityLabel(TXL.t("settings.dictation.words.placeholder", "Añadir palabra"))
            }
            if !words.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(words, id: \.self) { word in
                        HStack(spacing: 4) {
                            Text(word).font(.system(size: 12))
                            Button { remove(word) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)) }
                                .buttonStyle(.plain)
                                .foregroundStyle(TX.Colors.textSecondary)
                                .accessibilityLabel(TXL.f("settings.dictation.words.remove", "Quitar %@", word))
                        }
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .background(Capsule().fill(TX.Colors.bgControl))
                    }
                }
            }
        }
        .padding(.vertical, 8)
    }

    private func add() {
        let word = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        guard !word.isEmpty, !words.contains(where: { $0.caseInsensitiveCompare(word) == .orderedSame }) else { return }
        words.append(word)
        DictationPreferences.customWords = words
    }

    private func remove(_ word: String) {
        words.removeAll { $0 == word }
        DictationPreferences.customWords = words
    }
}

// MARK: - IA local

private struct AISettings: View {
    @ObservedObject private var ai = AIController.shared
    var body: some View {
        SettingsGroup {
            SettingsRow(label: TXL.t("settings.ai.provider", "Proveedor por defecto")) {
                Picker("", selection: Binding(get: { ai.provider }, set: { ai.provider = $0 })) {
                    Text(verbatim: "Apple Foundation Models").tag(AIProviderKind.appleFoundation)
                    Text(verbatim: "Ollama").tag(AIProviderKind.ollama)
                    Text(verbatim: "LM Studio").tag(AIProviderKind.lmstudio)
                }
                .labelsHidden().fixedSize()
            }
            if ai.provider != .appleFoundation, !ai.models.isEmpty {
                TXSeparator()
                SettingsRow(label: TXL.t("ai.model", "Modelo")) {
                    Picker("", selection: Binding(get: { ai.selectedModel ?? "" }, set: { ai.setModel($0) })) {
                        ForEach(ai.models, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
            }
            TXSeparator()
            SettingsRow(label: TXL.t("settings.ai.status", "Estado")) {
                switch ai.availability {
                case .checking: ProgressView().controlSize(.small)
                case .available: Text(TXL.t("ai.available", "Disponible")).font(.system(size: 12))
                case .unavailable(let reason): Text(reason).font(.system(size: 12)).foregroundStyle(TX.Colors.textSecondary).multilineTextAlignment(.trailing)
                }
                Button(TXL.t("ai.recheck", "Volver a comprobar")) { ai.check() }.buttonStyle(TXBorderlessButtonStyle())
            }
        }
        .onAppear { ai.check() }
    }
}

// MARK: - Automatización (spec 6.22)

private struct AutomationSettings: View {
    @ObservedObject private var folders = WatchedFoldersManager.shared
    @State private var selection: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroup(title: TXL.t("automation.folders", "Carpetas vigiladas")) {
                if folders.folders.isEmpty {
                    Text(TXL.t("automation.folders.empty", "No hay carpetas vigiladas."))
                        .font(.system(size: 12)).foregroundStyle(TX.Colors.textSecondary).frame(minHeight: 36)
                }
                ForEach(folders.folders, id: \.self) { folder in
                    HStack(spacing: 10) {
                        Image(systemName: "folder").foregroundStyle(TX.Colors.textSecondary).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(TXFormat.displayPath(folder.path))
                                .font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                            Text(state(of: folder))
                                .font(.system(size: 11))
                                .foregroundStyle(FileManager.default.fileExists(atPath: folder.path) ? TX.Colors.textSecondary : TX.Colors.error)
                        }
                        Spacer()
                    }
                    .frame(minHeight: 52)
                    .contentShape(Rectangle())
                    .background(selection == folder ? TX.Colors.selectionRow : .clear)
                    .onTapGesture { selection = folder }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(selection == folder ? [.isSelected, .isButton] : .isButton)
                    .accessibilityAction { selection = folder }
                }
                HStack(spacing: 0) {
                    Button { addFolder() } label: { Image(systemName: "plus") }
                        .buttonStyle(TXIconButtonStyle(iconSize: 12))
                        .help(TXL.t("automation.folders.add", "Añadir carpeta"))
                        .accessibilityLabel(TXL.t("automation.folders.add", "Añadir carpeta"))
                    Button { if let s = selection { folders.remove(s); selection = nil } } label: { Image(systemName: "minus") }
                        .buttonStyle(TXIconButtonStyle(iconSize: 12))
                        .disabled(selection == nil)
                        .help(TXL.t("automation.folders.remove", "Quitar carpeta"))
                        .accessibilityLabel(TXL.t("automation.folders.remove", "Quitar carpeta"))
                    Spacer()
                    Toggle(TXL.t("automation.autoSRT", "Exportar SRT automáticamente"), isOn: Binding(get: { folders.autoExport }, set: { folders.setAutoExport($0) }))
                        .toggleStyle(.checkbox).font(.system(size: 12))
                }
                .padding(.vertical, 4)
            }
            Text(TXL.t("automation.folders.note", "Los archivos nuevos se transcriben con el preset por defecto y aparecen en En proceso. El SRT automático se guarda junto al archivo original."))
                .font(.system(size: 11)).foregroundStyle(TX.Colors.textSecondary)
                .padding(.bottom, TX.Space.s16)

            SettingsGroup(title: TXL.t("automation.cli", "Línea de comandos")) {
                SettingsRow(label: TXL.t("automation.cli.tool", "Herramienta tx"),
                            help: CLIInstall.isInstalled ? nil : TXL.t("automation.cli.install.help", "Se instala desde el repositorio del proyecto con el script de instalación.")) {
                    Text(CLIInstall.isInstalled ? TXL.f("automation.cli.installed", "Instalada en %@", "~/.local/bin/tx") : TXL.t("cli.notInstalled", "No instalada"))
                        .font(.system(size: 12)).foregroundStyle(TX.Colors.textSecondary)
                    if !CLIInstall.isInstalled { CopyCommandButton(command: CLIInstall.installCommand) }
                }
                ForEach(["tx transcribe <archivo>", "tx models", "tx version"], id: \.self) { command in
                    copyLine(command)
                }
                Text(TXL.t("automation.cli.note", "tx usa Transcriptor X, que debe estar abierto."))
                    .font(.system(size: 11)).foregroundStyle(TX.Colors.textSecondary).padding(.vertical, 6)
            }
            SettingsGroup(title: TXL.t("automation.shortcuts", "Atajos y Spotlight")) {
                SettingsRow(label: TXL.t("automation.shortcuts.text", "La acción Transcribir archivo está disponible en la app Atajos y en Spotlight.")) {
                    Button(TXL.t("automation.shortcuts.open", "Abrir Atajos")) {
                        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.shortcuts") {
                            NSWorkspace.shared.openApplication(at: url, configuration: .init())
                        }
                    }
                    .buttonStyle(TXSecondaryButtonStyle())
                }
            }
            SettingsGroup(title: TXL.t("automation.links", "Enlaces transcriptorx://")) {
                copyLine("transcriptorx://transcribe?url=…", note: TXL.t("automation.links.transcribe", "Abre el sheet de enlace con la URL preparada"))
                copyLine("transcriptorx://open", note: TXL.t("automation.links.open", "Muestra la ventana"))
            }
        }
    }

    private func copyLine(_ command: String, note: String? = nil) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(command).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                if let note { Text(note).font(.system(size: 11)).foregroundStyle(TX.Colors.textSecondary) }
            }
            Spacer()
            Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(command, forType: .string) } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(TXIconButtonStyle(iconSize: 12))
            .help(TXL.t("common.copy", "Copiar"))
            .accessibilityLabel(TXL.f("common.copyItem", "Copiar %@", command))
        }
        .frame(minHeight: 36)
    }

    private func state(of folder: URL) -> String {
        guard FileManager.default.fileExists(atPath: folder.path) else { return TXL.t("automation.folder.missing", "La carpeta ya no existe") }
        guard FileManager.default.isReadableFile(atPath: folder.path) else { return TXL.t("automation.folder.noAccess", "Sin permiso de acceso · Volver a elegir") }
        return TXL.t("automation.folder.watching", "Vigilando")
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url { folders.add(url) }
    }
}

// MARK: - Privacidad (literal content, spec 6.20)

private struct PrivacySettings: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(TXL.t("privacy.lead", "Transcriptor X procesa el audio, el texto y la IA en este Mac."))
                .font(.system(size: 13, weight: .medium))
            VStack(alignment: .leading, spacing: 6) {
                bullet(TXL.t("privacy.noAccounts", "Sin cuentas"))
                bullet(TXL.t("privacy.noTelemetry", "Sin telemetría ni analíticas"))
                bullet(TXL.t("privacy.noRemoteConfig", "Sin configuración remota"))
            }
            TXGroupHeader(title: TXL.t("privacy.connections", "Cuándo se conecta a internet"))
            VStack(alignment: .leading, spacing: 6) {
                bullet(TXL.t("privacy.link", "Al descargar un enlace que pegas"))
                bullet(TXL.t("privacy.model", "Al descargar un modelo que eliges"))
                bullet(TXL.t("privacy.speakerModel", "La primera vez que identificas hablantes, para descargar su modelo (Hugging Face)"))
                bullet(TXL.t("privacy.updates", "Una vez por semana, para comprobar si hay actualizaciones (Sparkle)"))
            }
            Text(TXL.t("privacy.localAI", "Los proveedores de IA locales (Ollama, LM Studio) se contactan dentro del Mac."))
                .font(.system(size: 12)).foregroundStyle(TX.Colors.textSecondary)
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(TX.Colors.textSecondary).accessibilityHidden(true)
            Text(text).font(.system(size: 13))
        }
    }
}

// MARK: - Actualizaciones (spec 6.27)

private struct UpdatesSettings: View {
    @ObservedObject private var updater = UpdaterModel.shared

    var body: some View {
        SettingsGroup {
            SettingsRow(label: statusText) {
                Button(TXL.t("updates.checkNow", "Buscar ahora")) { updater.checkForUpdates() }
                    .buttonStyle(TXSecondaryButtonStyle())
                    .disabled(updater.isChecking)
            }
        }
    }

    private var statusText: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        if updater.isChecking { return TXL.t("updates.checking", "Buscando…") }
        if updater.availableVersion != nil { return TXL.t("updates.available", "Versión nueva disponible · Ver novedades") }
        if updater.lastError != nil { return TXL.t("updates.error", "No se pudo comprobar. Revisa la conexión a internet.") }
        if let date = updater.lastCheck {
            let f = RelativeDateTimeFormatter()
            f.locale = TXL.locale
            return TXL.f("updates.upToDate", "Tienes la última versión (%@) · Comprobado %@", version, f.localizedString(for: date, relativeTo: Date()))
        }
        return TXL.f("updates.version", "Versión %@", version)
    }
}
