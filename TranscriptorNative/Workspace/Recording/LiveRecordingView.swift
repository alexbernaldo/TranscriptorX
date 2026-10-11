import SwiftUI

/// Vista En vivo (spec 6.9). The recorder writes a file and does not transcribe while
/// recording (spec 12.1 #3), so this view shows the recording strip and the level; the text
/// appears in the job view as soon as the recording stops and the engine runs.
struct LiveRecordingView: View {
    @ObservedObject private var controller = RecordingController.shared
    @ObservedObject private var recorder = SystemAudioRecorder.shared
    @AppStorage("liveCaptionEnabled") private var captionsEnabled = false
    @EnvironmentObject var workspace: WorkspaceState

    var body: some View {
        VStack(spacing: 0) {
            strip
            TXSeparator()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch controller.phase {
                    case .failed(let message):
                        ErrorBlock(title: TXL.t("recording.interrupted.title", "La grabación se ha interrumpido"),
                                   explanation: message, details: nil) {
                            if controller.usesMicrophone {
                                Button(TXL.t("recording.chooseMic", "Elegir otro micrófono")) {
                                    controller.dismissError()
                                    workspace.showRecordPopover = true
                                }
                                .buttonStyle(TXSecondaryButtonStyle())
                            } else {
                                Button(TXL.t("permission.openSettings", "Abrir Ajustes del Sistema")) {
                                    controller.openPrivacySettings(for: .system)
                                }
                                .buttonStyle(TXSecondaryButtonStyle())
                            }
                            Button(TXL.t("common.close", "Cerrar")) { controller.dismissError(); workspace.goHome() }
                                .buttonStyle(TXBorderlessButtonStyle())
                        }
                    case .idle:
                        TXEmptyState(systemImage: "mic", title: TXL.t("live.idle.title", "No hay ninguna grabación en curso"),
                                     message: TXL.t("live.idle.text", "Pulsa Grabar para empezar.")) {
                            Button(TXL.t("record.button", "Grabar")) { controller.primaryAction() }
                                .buttonStyle(TXPrimaryButtonStyle(size: .large))
                        }
                        .padding(.top, 80)
                    default:
                        VStack(alignment: .leading, spacing: 12) {
                            Text(TXL.t("live.readOnly", "Podrás editar el texto cuando termine la grabación."))
                                .font(.system(size: 12))
                                .foregroundStyle(TX.Colors.textSecondary)
                            HStack(spacing: 12) {
                                LevelFragments(level: recorder.audioLevel, height: 28)
                                Text(controller.phase == .processing
                                     ? TXL.t("live.processing.text", "Preparando la transcripción de la grabación…")
                                     : TXL.t("live.recording.text", "El texto aparecerá aquí en cuanto detengas la grabación: se transcribe el audio completo en este Mac."))
                                    .txStyle(TX.Typography.transcript)
                                    .foregroundStyle(TX.Colors.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            WaitingFragments()
                        }
                    }
                }
                .frame(maxWidth: TX.Size.readingColumn, alignment: .leading)
                .padding(.horizontal, TX.Space.s32)
                .padding(.vertical, TX.Space.s24)
                .frame(maxWidth: .infinity)
            }
        }
        .background(TX.Colors.bgWindow)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(TXL.t("region.live", "Grabación en curso"))
    }

    /// 44 pt strip on bg.surface: dot, «Grabando · 12:04», source, captions button, «Detener».
    private var strip: some View {
        HStack(spacing: 12) {
            if controller.phase == .recording {
                Circle().fill(TX.Colors.record).frame(width: 8, height: 8).accessibilityHidden(true)
                Text(TXL.f("live.recording", "Grabando · %@", TXFormat.clock(recorder.recordingDuration)))
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundStyle(TX.Colors.textPrimary)
            } else if controller.phase == .processing || controller.phase == .starting {
                ProgressView().controlSize(.small).accessibilityHidden(true)
                Text(controller.phase == .starting
                     ? TXL.t("live.starting", "Preparando la captura…")
                     : TXL.t("live.processing", "Procesando la grabación…"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(TX.Colors.textPrimary)
            } else {
                Text(TXL.t("live.title", "Grabación"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(TX.Colors.textSecondary)
            }
            TXChip(text: controller.usesMicrophone ? TXL.t("record.source.mic", "Micrófono") : TXL.t("record.source.system", "Audio del sistema"))
            Spacer()
            Button { captionsEnabled.toggle() } label: {
                Image(systemName: captionsEnabled ? "captions.bubble.fill" : "captions.bubble")
            }
            .buttonStyle(TXIconButtonStyle(isActive: captionsEnabled))
            .help(captionsEnabled ? TXL.t("captions.off.help", "Desactivar subtítulos en pantalla") : TXL.t("captions.on.help", "Activar subtítulos en pantalla"))
            .accessibilityLabel(TXL.t("captions.toggle", "Subtítulos en pantalla"))
            .accessibilityValue(captionsEnabled ? TXL.t("a11y.on", "activado") : TXL.t("a11y.off", "desactivado"))
            if controller.phase == .recording {
                Button(TXL.t("recording.stop", "Detener")) { controller.stop() }
                    .buttonStyle(RecordStopButtonStyle())
                    .keyboardShortcut(".", modifiers: .command)
                    .help(TXL.t("recording.stop.help", "Detener ⌘."))
            }
        }
        .padding(.horizontal, TX.Space.s16)
        .frame(height: 44)
        .background(TX.Colors.bgSurface)
    }
}

/// «Detener»: secondary button with a record-coloured border.
struct RecordStopButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(TX.Colors.textPrimary)
            .padding(.horizontal, 14)
            .frame(height: TX.Size.control)
            .background(RoundedRectangle(cornerRadius: TX.Radius.control, style: .continuous)
                .fill(configuration.isPressed ? TX.Colors.bgPressed : TX.Colors.bgControl))
            .overlay(RoundedRectangle(cornerRadius: TX.Radius.control, style: .continuous)
                .strokeBorder(TX.Colors.record, lineWidth: 1))
    }
}
