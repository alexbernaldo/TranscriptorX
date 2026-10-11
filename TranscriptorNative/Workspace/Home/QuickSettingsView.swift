import SwiftUI

/// Languages offered by the existing app (kept), auto-detect first.
enum TranscriptionLanguages {
    static let codes = ["auto", "es", "en", "fr", "de", "it", "pt", "ja", "zh"]
}

/// Quick settings (spec 6.5): preset, language and model on one line; below, the audio and
/// text options as always-visible tiles, each with an ⓘ that explains it in plain words.
struct QuickSettingsRow: View {
    @ObservedObject var model: QuickSettingsModel
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { controls }
                VStack(alignment: .leading, spacing: 8) { controls }
            }
            .frame(minHeight: 36)
            if model.isCustom, let last = model.lastPresetId, let title = QuickSettingsModel.presetTitle(last) {
                HStack(spacing: 8) {
                    TXStatusTag(text: TXL.t("preset.custom", "Personalizado"))
                    Button(TXL.f("preset.backTo", "Volver a %@", title)) { model.apply(preset: last) }
                        .buttonStyle(TXBorderlessButtonStyle())
                }
            }
            if !compact {
                OptionTilesSection(model: model)
                    .padding(.top, 6)
            }
        }
    }

    @ViewBuilder private var controls: some View {
        presetControl
        LanguagePicker(model: model)
        ModelPicker(model: model)
    }

    private var presetControl: some View {
        Picker("", selection: Binding(
            get: { model.presetId ?? "" },
            set: { if !$0.isEmpty { model.apply(preset: $0) } })) {
            ForEach(QuickSettingsModel.presetIds, id: \.self) { id in
                Text(QuickSettingsModel.presetTitle(id) ?? id).tag(id)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .accessibilityLabel(TXL.t("preset.a11y", "Preset"))
        .help(TXL.t("preset.help", "Configuración para clases, podcasts o entrevistas"))
    }
}

struct LanguagePicker: View {
    @ObservedObject var model: QuickSettingsModel

    var body: some View {
        let englishOnly = ModelCapabilities.isEnglishOnly(model.settings.selectedModelId)
        // A menu sized to the current value, like the model menu: a pop-up takes the width
        // of its longest item («Detectar automáticamente») or truncates when compressed.
        Menu {
            ForEach(TranscriptionLanguages.codes, id: \.self) { code in
                Button {
                    model.settings.language = code
                    model.userChanged()
                } label: {
                    if model.settings.language == code {
                        Label(TXFormat.languageName(code), systemImage: "checkmark")
                    } else {
                        Text(TXFormat.languageName(code))
                    }
                }
            }
        } label: {
            Text(TXFormat.languageName(model.settings.language))
        }
        .fixedSize()
        .disabled(englishOnly)
        .help(englishOnly ? TXL.t("language.englishOnly", "Este modelo solo transcribe inglés") : TXL.t("language.help", "Idioma del audio"))
        .accessibilityLabel(TXL.t("language.a11y", "Idioma"))
        .accessibilityValue(TXFormat.languageName(model.settings.language))
    }
}

/// Model menu grouped by «Multilingües» / «Solo inglés», with disk size and state (spec 6.5).
struct ModelPicker: View {
    @ObservedObject var model: QuickSettingsModel
    @ObservedObject private var downloads = ModelDownloadCenter.shared

    var body: some View {
        let catalogue = ModelCapabilities.catalogue
        let multilingual = catalogue.filter { !$0.englishOnly }
        let english = catalogue.filter { $0.englishOnly }
        Menu {
            Section(TXL.t("models.group.multilingual", "Multilingües")) {
                ForEach(multilingual) { entry in item(entry) }
            }
            if !english.isEmpty {
                Section(TXL.t("models.group.english", "Solo inglés")) {
                    ForEach(english) { entry in item(entry) }
                }
            }
            Divider()
            Button(TXL.t("models.manage", "Gestionar modelos…")) { SettingsNavigator.open(.models) }
        } label: {
            Text(model.settings.selectedModelId)
        }
        .fixedSize()
        .help(TXL.t("models.help", "Modelo de transcripción"))
        .accessibilityLabel(TXL.f("models.a11y", "Modelo, %@", model.settings.selectedModelId))
    }

    private func item(_ entry: ModelCapabilities.Entry) -> some View {
        let downloaded = downloads.revision >= 0 && downloads.isDownloaded(entry.id)
        let state = downloaded ? TXL.t("models.state.downloaded", "Descargado") : TXL.f("models.state.download", "Descargar · %@", entry.size)
        return Button {
            model.settings.selectedModelId = entry.id
            model.userChanged()
        } label: {
            if model.settings.selectedModelId == entry.id {
                Label("\(entry.id) · \(state)", systemImage: "checkmark")
            } else {
                Text("\(entry.id) · \(state)")
            }
        }
    }
}

/// The five job options as tiles under the quick settings. Plain-language names; the ⓘ on each
/// tile says what it does and when it helps, so nobody has to know what «VAD» means.
enum QuickOption: String, CaseIterable, Identifiable {
    case noise, normalize, vad, speakers, translate
    var id: String { rawValue }

    var title: String {
        switch self {
        case .noise: return TXL.t("tile.noise", "Reducir ruido")
        case .normalize: return TXL.t("tile.normalize", "Igualar volumen")
        case .vad: return TXL.t("tile.vad", "Saltar silencios")
        case .speakers: return TXL.t("tile.speakers", "Quién habla")
        case .translate: return TXL.t("tile.translate", "Traducir al inglés")
        }
    }

    var icon: String {
        switch self {
        case .noise: return "wand.and.stars"
        case .normalize: return "speaker.wave.2"
        case .vad: return "waveform"
        case .speakers: return "person.2"
        case .translate: return "character.bubble"
        }
    }

    var explanation: String {
        switch self {
        case .noise:
            return TXL.t("tile.noise.info", "Limpia el ruido de fondo, como ventiladores, tráfico o eco, para que la voz se entienda mejor.")
        case .normalize:
            return TXL.t("tile.normalize.info", "Sube lo que se oye bajo y baja lo que se oye fuerte, para que todo suene a un volumen parecido.")
        case .vad:
            return TXL.t("tile.vad.info", "Se salta los tramos en los que nadie habla. Transcribe más rápido y evita frases inventadas en los silencios.")
        case .speakers:
            return ModelCapabilities.speakersHelp
        case .translate:
            return TXL.t("tile.translate.info", "Escribe la transcripción directamente en inglés, sea cual sea el idioma del audio.")
        }
    }

    var idealFor: String {
        switch self {
        case .noise: return TXL.t("tile.noise.ideal", "Útil en grabaciones caseras o en la calle.")
        case .normalize: return TXL.t("tile.normalize.ideal", "Útil si alguien habla lejos del micrófono.")
        case .vad: return TXL.t("tile.vad.ideal", "Útil en grabaciones con pausas largas.")
        case .speakers: return TXL.t("tile.speakers.ideal", "Útil en entrevistas y reuniones.")
        case .translate: return TXL.t("tile.translate.ideal", "Útil si necesitas el texto en inglés.")
        }
    }
}

struct OptionTilesSection: View {
    @ObservedObject var model: QuickSettingsModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 0) {
                TXGroupHeader(title: TXL.t("tile.header", "Opciones"))
                Button {
                    SettingsNavigator.open(.language)
                } label: {
                    Label(TXL.t("tile.allSettings", "Más ajustes…"), systemImage: "gearshape")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(TXBorderlessButtonStyle(tint: TX.Colors.textSecondary))
                .fixedSize()
                .help(TXL.t("tile.allSettings.help", "Abrir Ajustes ⌘,"))
            }
            HStack(spacing: 8) {
                ForEach(QuickOption.allCases) { option in
                    OptionTile(option: option, model: model, isOn: isOn(option), isEnabled: isEnabled(option)) {
                        withAnimation(reduceMotion ? nil : TX.Motion.tileToggle) { toggle(option) }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(TXL.t("tile.header", "Opciones"))
    }

    private func isOn(_ option: QuickOption) -> Bool {
        switch option {
        case .noise: return model.noiseReduction != .off
        case .normalize: return model.settings.normalize
        case .vad: return model.settings.useVAD
        case .speakers: return model.settings.enableDiarization
        case .translate: return model.settings.translate
        }
    }

    private func isEnabled(_ option: QuickOption) -> Bool {
        option != .translate || !ModelCapabilities.isEnglishOnly(model.settings.selectedModelId)
    }

    private func toggle(_ option: QuickOption) {
        switch option {
        case .noise: model.noiseReduction = model.noiseReduction == .off ? model.preferredNoise : .off
        case .normalize: model.settings.normalize.toggle(); model.userChanged()
        case .vad: model.settings.useVAD.toggle(); model.userChanged()
        case .speakers: model.settings.enableDiarization.toggle(); model.userChanged()
        case .translate: model.settings.translate.toggle(); model.userChanged()
        }
    }
}

private struct OptionTile: View {
    let option: QuickOption
    @ObservedObject var model: QuickSettingsModel
    let isOn: Bool
    let isEnabled: Bool
    let onToggle: () -> Void
    @State private var hovering = false
    @State private var showInfo = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: onToggle) {
            VStack(spacing: 8) {
                Image(systemName: option.icon)
                    .font(.system(size: 18, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(isOn ? TX.Colors.accentText : TX.Colors.textSecondary)
                    .frame(height: 22)
                Text(option.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isOn ? TX.Colors.textPrimary : TX.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    // Two-line slot so icons line up whether the name wraps or not.
                    .frame(height: 30, alignment: .top)
            }
            .padding(.horizontal, 6)
            .padding(.top, 16)
            .frame(maxWidth: .infinity)
            .frame(height: 84, alignment: .top)
            .opacity(isEnabled ? 1 : 0.4)
            .background(
                RoundedRectangle(cornerRadius: TX.Radius.dropZone, style: .continuous)
                    .fill(background)
            )
            .overlay(
                RoundedRectangle(cornerRadius: TX.Radius.dropZone, style: .continuous)
                    .strokeBorder(isOn ? TX.Colors.purpleX.opacity(0.6) : TX.Colors.border, lineWidth: 1)
            )
            .overlay(alignment: .topLeading) {
                if isOn {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(TX.Colors.accentText)
                        .padding(7)
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.6).combined(with: .opacity))
                        .accessibilityHidden(true)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: TX.Radius.dropZone, style: .continuous))
        }
        .buttonStyle(TilePressStyle(reduceMotion: reduceMotion))
        .disabled(!isEnabled)
        .onHover { hovering = $0 }
        .animation(TX.Motion.hover, value: hovering)
        .overlay(alignment: .topTrailing) { infoButton }
        .help(option.title)
        .accessibilityLabel(option.title)
        .accessibilityValue(isOn ? TXL.t("tile.on", "Activado") : TXL.t("tile.off", "Desactivado"))
        .accessibilityHint(option.explanation)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private var background: Color {
        if isOn { return TX.Colors.selectionRow }
        return hovering && isEnabled ? TX.Colors.bgHover : TX.Colors.bgSurface
    }

    private var infoButton: some View {
        Button { showInfo.toggle() } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 12))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(showInfo ? TX.Colors.accentText : TX.Colors.textTertiary)
        .padding(2)
        .help(TXL.f("tile.info.help", "Qué hace «%@»", option.title))
        .accessibilityLabel(TXL.f("tile.info.help", "Qué hace «%@»", option.title))
        .popover(isPresented: $showInfo, arrowEdge: .bottom) {
            OptionInfo(option: option, model: model, isOn: isOn, isEnabled: isEnabled, onToggle: onToggle)
        }
    }
}

/// Press feedback for tiles: a short scale-down that confirms the click.
private struct TilePressStyle: ButtonStyle {
    let reduceMotion: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(TX.Motion.release, value: configuration.isPressed)
    }
}

/// ⓘ popover: what the option does, when it helps, and the switch itself.
private struct OptionInfo: View {
    let option: QuickOption
    @ObservedObject var model: QuickSettingsModel
    let isOn: Bool
    let isEnabled: Bool
    let onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: option.icon)
                    .font(.system(size: 15))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(TX.Colors.accentText)
                    .accessibilityHidden(true)
                Text(option.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(TX.Colors.textPrimary)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(option.explanation)
                    .foregroundStyle(TX.Colors.textPrimary)
                Text(isEnabled ? option.idealFor : TXL.t("tile.translate.unsupported", "Este modelo solo transcribe inglés, así que no hace falta traducir."))
                    .foregroundStyle(TX.Colors.textSecondary)
            }
            .font(.system(size: 12))
            .fixedSize(horizontal: false, vertical: true)

            if option == .noise { strengthPicker }

            TXSeparator()
            HStack {
                Text(isOn ? TXL.t("tile.on", "Activado") : TXL.t("tile.off", "Desactivado"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(TX.Colors.textSecondary)
                    .accessibilityHidden(true)
                Spacer()
                Toggle(option.title, isOn: Binding(get: { isOn }, set: { if $0 != isOn { onToggle() } }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(!isEnabled)
            }
        }
        .padding(16)
        .frame(width: 280, alignment: .leading)
    }

    /// Ligera (DeepFilter) or Intensa (Demucs); choosing one also turns the option on.
    private var strengthPicker: some View {
        let current = model.noiseReduction == .off ? model.preferredNoise : model.noiseReduction
        return VStack(alignment: .leading, spacing: 6) {
            Picker(TXL.t("tile.noise.strength", "Intensidad"), selection: Binding(
                get: { current },
                set: { model.preferredNoise = $0; model.noiseReduction = $0 })) {
                Text(TXL.t("tile.noise.light", "Ligera")).tag(QuickSettingsModel.NoiseReduction.deepFilter)
                Text(TXL.t("tile.noise.strong", "Intensa")).tag(QuickSettingsModel.NoiseReduction.demucs)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel(TXL.t("tile.noise.strength", "Intensidad"))
            Text(current == .demucs
                 ? TXL.t("tile.noise.strong.info", "Separa la voz de la música. Tarda más.")
                 : TXL.t("tile.noise.light.info", "Rápida. Ideal para ruido de fondo."))
                .font(.system(size: 11))
                .foregroundStyle(TX.Colors.textSecondary)
        }
    }
}
