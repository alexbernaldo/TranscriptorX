import SwiftUI

/// Configuration of the jobs created from one view (Inicio, link sheet, record popover), spec 6.5.
///
/// A preset fixes language, model, preprocessing and transcription options; everything else
/// comes from the defaults edited in Ajustes › Idioma. Changing a value the preset fixed
/// turns the configuration into «Personalizado».
@MainActor
final class QuickSettingsModel: ObservableObject {
    static let presetIds = ["lecture", "podcast", "interview"]
    /// No default preset unless the user chooses one in Ajustes › Idioma (keeps the previous behaviour).
    static let defaultPresetId = ""

    @Published var settings: TranscriptionSettings
    /// Preset currently applied and unchanged, or nil when custom.
    @Published private(set) var presetId: String?
    /// Last preset applied (for «Volver a Entrevista»).
    @Published private(set) var lastPresetId: String?
    /// Strength used when «Reducir ruido» is switched on from a tile.
    var preferredNoise: NoiseReduction = .deepFilter

    /// Inicio and Ajustes › Idioma show the same configuration: every change here is
    /// saved as the default, and a change in Ajustes is reflected here at once.
    private let syncsWithDefaults: Bool
    private var isPulling = false
    private var observers: [NSObjectProtocol] = []

    init(defaults: TranscriptionSettings = QuickSettingsModel.defaultSettings(), syncsWithDefaults: Bool = false) {
        self.syncsWithDefaults = syncsWithDefaults
        settings = defaults
        let preset = UserDefaults.standard.string(forKey: "defaults.preset") ?? Self.defaultPresetId
        if Self.presetIds.contains(preset) { apply(preset: preset) }
        sanitize()
        guard syncsWithDefaults else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .defaultSettingsChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.pullDefaults() }
        })
        observers.append(center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.pullPreset() }
        })
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    /// Saves this configuration as the default (Ajustes › Idioma).
    private func pushDefaults() {
        guard syncsWithDefaults, !isPulling else { return }
        isPulling = true
        defer { isPulling = false }
        if DefaultsModel.shared.settings != settings { DefaultsModel.shared.settings = settings }
        let preset = presetId ?? ""
        if UserDefaults.standard.string(forKey: "defaults.preset") ?? "" != preset {
            UserDefaults.standard.set(preset, forKey: "defaults.preset")
        }
    }

    /// Ajustes changed a default: take it, and recompute whether a preset still applies.
    private func pullDefaults() {
        guard !isPulling else { return }
        let saved = DefaultsModel.shared.settings
        guard saved != settings else { return }
        isPulling = true
        defer { isPulling = false }
        settings = saved
        sanitize()
        if let id = presetId, !matches(preset: id) { presetId = nil }
    }

    /// The «Preset por defecto» picker in Ajustes.
    private func pullPreset() {
        guard !isPulling else { return }
        let preset = UserDefaults.standard.string(forKey: "defaults.preset") ?? ""
        guard preset != (presetId ?? "") else { return }
        isPulling = true
        defer { isPulling = false }
        if Self.presetIds.contains(preset) {
            apply(preset: preset)
            if DefaultsModel.shared.settings != settings { DefaultsModel.shared.settings = settings }
        } else {
            presetId = nil
        }
    }

    nonisolated static func defaultSettings() -> TranscriptionSettings {
        guard let data = UserDefaults.standard.data(forKey: "transcription_settings"),
              let saved = try? JSONDecoder().decode(TranscriptionSettings.self, from: data) else { return .default }
        return saved
    }

    static func presetSettings(_ id: String) -> TranscriptionSettings {
        switch id {
        case "lecture": return .lecture
        case "podcast": return .podcast
        default: return .interview
        }
    }

    static func presetTitle(_ id: String?) -> String? {
        switch id {
        case "lecture": return TXL.t("preset.lecture", "Clase")
        case "podcast": return TXL.t("preset.podcast", "Podcast")
        case "interview": return TXL.t("preset.interview", "Entrevista")
        default: return nil
        }
    }

    /// Modelo asignado a cada preset mostrado con su nombre amigable (6.6).
    static func presetModelName(_ id: String?) -> String? {
        switch id {
        case "lecture": return ModelCatalog.descriptor(id: "large-v3")?.displayName
        case "podcast": return ModelCatalog.descriptor(id: "medium")?.displayName
        case "interview": return ModelCatalog.descriptor(id: "large-v3-turbo")?.displayName
        default: return nil
        }
    }

    /// Settings for a preset id on top of the user's defaults (record popover).
    static func settings(forPreset id: String) -> TranscriptionSettings {
        let model = QuickSettingsModel()
        if presetIds.contains(id) { model.apply(preset: id) }
        model.sanitize()
        return model.settings
    }

    var presetTitle: String? { Self.presetTitle(presetId) }
    var isCustom: Bool { presetId == nil && lastPresetId != nil }

    func apply(preset id: String) {
        let p = Self.presetSettings(id)
        settings.language = p.language
        settings.selectedModelId = p.selectedModelId
        settings.useVAD = p.useVAD
        settings.vadThreshold = p.vadThreshold
        settings.vadMinSilenceDuration = p.vadMinSilenceDuration
        settings.enableDiarization = p.enableDiarization
        settings.deepfilter = p.deepfilter
        settings.isolateVoice = p.isolateVoice
        settings.normalize = p.normalize
        settings.suppressNonSpeech = p.suppressNonSpeech
        settings.translate = p.translate
        settings.initialPrompt = p.initialPrompt
        presetId = id
        lastPresetId = id
        sanitize()
        pushDefaults()
    }

    /// Call after any manual change: a value differing from the preset makes it «Personalizado».
    func userChanged() {
        sanitize()
        if let id = presetId, !matches(preset: id) { presetId = nil }
        pushDefaults()
    }

    /// The values a preset fixes are still the preset's.
    private func matches(preset id: String) -> Bool {
        let p = Self.presetSettings(id)
        let presetDiarization = p.enableDiarization && ModelCapabilities.supportsDiarization(p.selectedModelId)
        return settings.language == p.language
            && settings.selectedModelId == p.selectedModelId
            && settings.useVAD == p.useVAD
            && settings.deepfilter == p.deepfilter
            && settings.isolateVoice == p.isolateVoice
            && settings.normalize == p.normalize
            && settings.translate == p.translate
            && settings.enableDiarization == presetDiarization
    }

    /// Removes options the chosen model cannot honour (spec 6.5 compatibility notes).
    func sanitize() {
        if !ModelCapabilities.supportsDiarization(settings.selectedModelId) { settings.enableDiarization = false }
        if ModelCapabilities.isEnglishOnly(settings.selectedModelId) {
            settings.language = "en"
            settings.translate = false
        }
    }

    /// Noise reduction as one choice: Desactivada · DeepFilter · Demucs.
    enum NoiseReduction: String, CaseIterable, Identifiable {
        case off, deepFilter, demucs
        var id: String { rawValue }
        var title: String {
            switch self {
            case .off: return TXL.t("options.noise.off", "Desactivada")
            case .deepFilter: return "DeepFilter"
            case .demucs: return "Demucs"
            }
        }
    }

    var noiseReduction: NoiseReduction {
        get { settings.isolateVoice ? .demucs : (settings.deepfilter ? .deepFilter : .off) }
        set {
            settings.deepfilter = newValue == .deepFilter
            settings.isolateVoice = newValue == .demucs
            if newValue != .off { preferredNoise = newValue }
            userChanged()
        }
    }

    /// Short summary for job views and chips: preset, model, language, active options.
    var summaryTags: [String] { Self.summaryTags(for: settings, presetName: presetTitle) }

    static func summaryTags(for s: TranscriptionSettings, presetName: String?) -> [String] {
        var tags: [String] = []
        if let presetName { tags.append(presetName) }
        let modelDesc = ModelCatalog.descriptor(id: s.selectedModelId)
        let showTech = TaskModelPreferences.shared.showTechnicalNames
        let modelName = modelDesc.map { ModelCatalog.formattedName(for: $0.id, showTechnical: showTech) } ?? s.selectedModelId
        let engineBadge = modelDesc?.engine.badge ?? "Whisper"
        tags.append("\(modelName) · \(engineBadge)")
        tags.append(TXFormat.languageName(s.language))
        if s.isolateVoice { tags.append("Demucs") } else if s.deepfilter { tags.append("DeepFilter") }
        if s.normalize { tags.append(TXL.t("options.tag.normalize", "Normalizar")) }
        if s.useVAD { tags.append(TXL.t("options.tag.vad", "Detección de voz")) }
        if s.enableDiarization { tags.append(TXL.t("options.tag.speakers", "Hablantes")) }
        if s.translate { tags.append(TXL.t("options.tag.translate", "Traducir al inglés")) }
        return tags
    }
}

/// What each whisper model can do, from the catalogue (spec 12.1 #7).
enum ModelCapabilities {
    /// Speakers are identified after whisper (SpeakerDiarizationService), so every
    /// model supports it, in any language.
    static func supportsDiarization(_ modelId: String) -> Bool { true }

    /// Help under «Identificar hablantes»: what happens the first time.
    static var speakersHelp: String {
        SpeakerDiarizationService.areModelsDownloaded
            ? TXL.t("options.speakers.help", "Detecta quién habla en este Mac. Funciona en cualquier idioma.")
            : TXL.t("options.speakers.helpDownload", "Detecta quién habla en este Mac. La primera vez descarga el modelo de hablantes.")
    }
    /// English-only models end in «.en»; none of the catalogue models is one.
    static func isEnglishOnly(_ modelId: String) -> Bool {
        ModelCatalog.descriptor(id: modelId)?.isEnglishOnly ?? (modelId.hasSuffix(".en") || modelId.contains(".en-"))
    }

    struct Entry: Identifiable {
        let id: String
        let size: String
        let neuralEngine: Bool
        let englishOnly: Bool
    }

    /// Vista derivada de ModelCatalog (única fuente de verdad)
    static var catalogue: [Entry] {
        let showExp = UserDefaults.standard.bool(forKey: "showExperimentalModels")
        return ModelCatalog.visible(showExperimental: showExp)
            .map { d in
                Entry(
                    id: d.id,
                    size: ModelStorageService.shared.displaySize(for: d.id),
                    neuralEngine: d.capabilities.computeUnits == .neuralEngine,
                    englishOnly: d.isEnglishOnly
                )
            }
    }
}
