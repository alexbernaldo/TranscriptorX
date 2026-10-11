import SwiftUI
import AVFoundation

/// Popover «Grabar» (340 pt, spec 6.7). Sources are exclusive: the recorder captures the
/// microphone or the system audio, one at a time (spec 12.1 #4 validated against the code).
struct RecordPopover: View {
    @ObservedObject private var recording = RecordingController.shared
    @ObservedObject private var recorder = SystemAudioRecorder.shared
    @StateObject private var preview = MicLevelPreview()
    @AppStorage("liveCaptionEnabled") private var captionsEnabled = false

    private var source: SystemAudioRecorder.AudioSource { recorder.selectedSource }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(TXL.t("record.popover.title", "Grabar"))
                .txStyle(TX.Typography.sectionTitle)
                .foregroundStyle(TX.Colors.textPrimary)

            VStack(alignment: .leading, spacing: 10) {
                sourceRow(.microphone)
                sourceRow(.system)
                Text(TXL.t("record.popover.oneSource", "Se graba una fuente cada vez."))
                    .font(.system(size: 11))
                    .foregroundStyle(TX.Colors.textSecondary)
            }

            TXSeparator()

            HStack(spacing: 8) {
                Text(TXL.t("record.popover.transcribeWith", "Transcribir con"))
                    .font(.system(size: 13))
                    .foregroundStyle(TX.Colors.textSecondary)
                Picker("", selection: $recording.presetId) {
                    Text(TXL.t("preset.defaults", "Valores por defecto")).tag("")
                    ForEach(QuickSettingsModel.presetIds, id: \.self) { id in
                        Text(QuickSettingsModel.presetTitle(id) ?? id).tag(id)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel(TXL.t("record.popover.preset", "Preset de la transcripción"))
            }
            Text(summary)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(TX.Colors.textSecondary)
                .lineLimit(1)

            Toggle(TXL.t("record.popover.captions", "Subtítulos en pantalla"), isOn: $captionsEnabled)
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.system(size: 13))

            HStack {
                Spacer()
                Button(TXL.t("record.popover.start", "Empezar a grabar")) { recording.start() }
                    .buttonStyle(TXPrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(recording.permissionState(for: source) == .denied || recording.isActive)
            }
        }
        .padding(16)
        .frame(width: 340)
        .onAppear { updatePreview() }
        .onDisappear { preview.stop() }
        .txOnChange(of: recorder.selectedSource) { _ in updatePreview() }
    }

    private var summary: String {
        let s = QuickSettingsModel.settings(forPreset: recording.presetId)
        return "\(TXFormat.languageName(s.language)) · \(s.selectedModelId)"
    }

    private func updatePreview() {
        if source == .microphone, recording.permissionState(for: .microphone) == .granted,
           recorder.selectedMicrophone?.isDefault ?? true {
            preview.start()
        } else {
            preview.stop()
        }
    }

    // MARK: Source rows

    @ViewBuilder
    private func sourceRow(_ kind: SystemAudioRecorder.AudioSource) -> some View {
        let selected = source == kind
        let permission = recording.permissionState(for: kind)
        HStack(alignment: .top, spacing: 8) {
            Button {
                recorder.selectedSource = kind
            } label: {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(selected ? TX.Colors.purpleX : TX.Colors.textSecondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(kind == .microphone ? TXL.t("record.source.mic", "Micrófono") : TXL.t("record.source.system", "Audio del sistema"))
            .accessibilityAddTraits(selected ? [.isSelected] : [])

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(kind == .microphone ? TXL.t("record.source.mic", "Micrófono") : TXL.t("record.source.system", "Audio del sistema"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(TX.Colors.textPrimary)
                    Spacer()
                    if selected, permission == .granted, kind == .microphone, preview.isRunning {
                        LevelFragments(level: preview.level, height: 14)
                    }
                }
                switch permission {
                case .granted:
                    if kind == .microphone {
                        if !recorder.availableMicrophones.isEmpty {
                            Picker("", selection: Binding(get: { recorder.selectedMicrophone?.id ?? 0 },
                                                          set: { id in recorder.selectedMicrophone = recorder.availableMicrophones.first { $0.id == id }; updatePreview() })) {
                                ForEach(recorder.availableMicrophones) { mic in Text(mic.name).tag(mic.id) }
                            }
                            .labelsHidden()
                            .controlSize(.small)
                            .accessibilityLabel(TXL.t("record.mic.device", "Dispositivo de entrada"))
                        }
                    } else {
                        Text(TXL.t("record.source.system.detail", "Todo el sonido del Mac"))
                            .font(.system(size: 12))
                            .foregroundStyle(TX.Colors.textSecondary)
                    }
                case .notDetermined:
                    Text(kind == .microphone
                         ? TXL.t("permission.mic.explain", "Para grabar tu voz, macOS te pedirá acceso al micrófono.")
                         : TXL.t("permission.screen.explain", "Para grabar el sonido del Mac, macOS te pedirá este permiso. Transcriptor X solo captura audio."))
                        .font(.system(size: 12))
                        .foregroundStyle(TX.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(TXL.t("permission.allow", "Permitir…")) {
                        Task { await recording.requestPermission(for: kind); updatePreview() }
                    }
                    .buttonStyle(TXSecondaryButtonStyle(size: .small))
                case .denied:
                    Text(kind == .microphone
                         ? TXL.t("permission.mic.denied", "Sin acceso al micrófono")
                         : TXL.t("permission.screen.denied", "Sin acceso al audio del sistema. Puede que tengas que volver a abrir la app."))
                        .font(.system(size: 12))
                        .foregroundStyle(TX.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(TXL.t("permission.openSettings", "Abrir Ajustes del Sistema")) {
                        recording.openPrivacySettings(for: kind)
                    }
                    .buttonStyle(TXBorderlessButtonStyle())
                }
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// Level of the default input while the popover is open (only with permission already granted).
@MainActor
final class MicLevelPreview: ObservableObject {
    @Published private(set) var level: Float = 0
    @Published private(set) var isRunning = false
    private var engine: AVAudioEngine?

    func start() {
        guard engine == nil else { return }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0 else { return }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let data = buffer.floatChannelData?[0] else { return }
            var sum: Float = 0
            let n = Int(buffer.frameLength)
            for i in 0..<n { sum += data[i] * data[i] }
            let rms = sqrt(sum / Float(max(n, 1)))
            let db = 20 * log10(max(rms, 0.000_01))
            let normalized = max(0, min(1, (db + 55) / 50))
            Task { @MainActor in self?.level = normalized }
        }
        do {
            try engine.start()
            self.engine = engine
            isRunning = true
        } catch {
            input.removeTap(onBus: 0)
        }
    }

    func stop() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        isRunning = false
        level = 0
    }
}
