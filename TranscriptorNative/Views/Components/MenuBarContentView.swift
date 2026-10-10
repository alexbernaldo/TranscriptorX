import SwiftUI
import AppKit

// MARK: - Menu Bar Panel (#10)
/// Panel del menú de barra: última transcripción, grabación, cola y acciones rápidas.
struct MenuBarContentView: View {
    @EnvironmentObject var viewModel: TranscriptionViewModel
    @EnvironmentObject var localizationManager: LocalizationManager
    @ObservedObject private var recorder = SystemAudioRecorder.shared
    @ObservedObject private var jobManager = JobManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let latest = viewModel.transcriptions.first {
                Button {
                    NSApp.activate(ignoringOtherApps: true)
                    viewModel.selectTranscription(latest)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "doc.text")
                            .frame(width: 16)
                            .foregroundColor(.textSecondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(latest.title)
                                .font(.bodyMedium)
                                .foregroundColor(.textPrimary)
                                .lineLimit(1)
                            Text(latest.formattedDate)
                                .font(.caption)
                                .foregroundColor(.textTertiary)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Divider()
            }

            // Grabar / Detener (#10)
            if recorder.isRecording {
                Button {
                    Task { _ = await recorder.stopRecording() }
                } label: {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(Color.white)
                            .frame(width: 8, height: 8)
                        Text(localizationManager.text("menubar.stop", fallback: "Detener")
                              + " (" + formatDuration(recorder.recordingDuration) + ")")
                            .font(.bodyMedium)
                            .foregroundColor(.white)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(Capsule().fill(Color.red))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    recorder.selectedSource = .system
                    Task { await recorder.startRecording() }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "record.circle")
                            .frame(width: 16)
                            .foregroundColor(.red)
                        Text(localizationManager.text("menubar.record", fallback: "Grabar sistema"))
                            .font(.bodyMedium)
                            .foregroundColor(.textPrimary)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if let error = recorder.errorMessage, !error.isEmpty {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
                    .lineLimit(2)
            }

            if !jobManager.jobs.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(jobManager.jobs) { job in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(job.fileName)
                                    .font(.caption)
                                    .foregroundColor(.textSecondary)
                                    .lineLimit(1)
                                Spacer()
                                Text("\(job.progress)%")
                                    .font(.caption2)
                                    .foregroundColor(.textTertiary)
                            }
                            ProgressView(value: Double(job.progress) / 100.0)
                                .progressViewStyle(.linear)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                Divider()
            }

            menuRow(
                localizationManager.text("menubar.newTranscription", fallback: "Nueva transcripción"),
                icon: "plus"
            ) {
                NSApp.activate(ignoringOtherApps: true)
                NotificationCenter.default.post(name: .showNewTranscription, object: nil)
            }
            menuRow(
                localizationManager.text("menubar.history", fallback: "Historial"),
                icon: "clock"
            ) {
                NSApp.activate(ignoringOtherApps: true)
                NotificationCenter.default.post(name: .showLibrary, object: nil)
            }
            menuRow(
                localizationManager.text("menubar.settings", fallback: "Ajustes"),
                icon: "gearshape"
            ) {
                NSApp.activate(ignoringOtherApps: true)
                NotificationCenter.default.post(name: .showSettings, object: nil)
            }

            Divider()

            menuRow(
                localizationManager.text("menubar.quit", fallback: "Salir de Transcriptor X"),
                icon: "power"
            ) {
                NSApp.terminate(nil)
            }
        }
        .padding(.vertical, 8)
        .frame(width: 300)
        .background(
            Color.bgSecondary
                .background(.ultraThinMaterial)
        )
        .overlay(
            Rectangle()
                .stroke(Color.borderSubtle, lineWidth: 1)
        )
    }

    private func menuRow(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .frame(width: 16)
                    .foregroundColor(.textSecondary)
                Text(title)
                    .font(.bodyMedium)
                    .foregroundColor(.textPrimary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func formatDuration(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
