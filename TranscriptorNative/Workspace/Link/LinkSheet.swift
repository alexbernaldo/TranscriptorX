import SwiftUI
import AppKit

/// Transcribir desde un enlace (spec 6.4). The job lives in the queue from the start: the sheet
/// shows its phases and errors and can be closed («Seguir en segundo plano») at any time.
/// YouTube links keep the existing choice between the video's subtitles and transcribing the audio.
struct LinkSheet: View {
    let prefill: String?
    let fromScheme: Bool
    let existingJobId: UUID?
    @EnvironmentObject var workspace: WorkspaceState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var jobs = JobManager.shared
    @StateObject private var quick = QuickSettingsModel(syncsWithDefaults: true)
    @State private var link = ""
    @State private var method: URLJobMethod = .audio
    @State private var jobId: UUID?
    @FocusState private var fieldFocused: Bool

    private var trimmed: String { link.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isValid: Bool {
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), url.host != nil else { return false }
        return scheme == "http" || scheme == "https"
    }
    private var isYouTube: Bool {
        guard let host = URL(string: trimmed)?.host?.lowercased() else { return false }
        return host.contains("youtube.com") || host.contains("youtu.be")
    }
    private var job: TranscriptionJob? { jobId.flatMap { jobs.job($0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(TXL.t("link.title", "Transcribir desde un enlace"))
                .txStyle(TX.Typography.sectionTitle)
                .foregroundStyle(TX.Colors.textPrimary)
            if fromScheme && job == nil {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "info.circle").foregroundStyle(TX.Colors.info).accessibilityHidden(true)
                    Text(TXL.t("link.fromScheme", "Enlace recibido desde otra aplicación. Revísalo antes de continuar."))
                        .font(.system(size: 12)).foregroundStyle(TX.Colors.textPrimary)
                }
            }
            if let job, job.status != .failed {
                progressBlock(job)
            } else {
                form
            }
            if let job, job.status == .failed {
                JobErrorPanel(job: job).environmentObject(workspace)
            }
            buttons
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            if let existingJobId, let existing = jobs.job(existingJobId) {
                if case .url(let l) = existing.source { link = l }
                method = existing.urlMethod ?? .audio
                if existing.status != .failed { jobId = existingJobId }
            } else if let prefill {
                link = prefill
            }
            fieldFocused = true
        }
        .txOnChange(of: job?.status) { status in
            // Finished in the sheet: the document opens and the sheet closes.
            if status == .completed {
                if let id = jobId { workspace.open(document: id) }
                dismiss()
            }
        }
    }

    // MARK: Form

    private var form: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TextField(TXL.t("link.placeholder", "https://"), text: $link)
                    .txField(error: !trimmed.isEmpty && !isValid)
                    .focused($fieldFocused)
                    .onSubmit { if isValid { start() } }
                    .accessibilityLabel(TXL.t("link.field", "Enlace"))
                Button(TXL.t("link.paste", "Pegar")) {
                    // The app never reads the clipboard on its own: only when this button is pressed.
                    if let s = NSPasteboard.general.string(forType: .string) { link = s.trimmingCharacters(in: .whitespacesAndNewlines) }
                }
                .buttonStyle(TXSecondaryButtonStyle())
            }
            if !trimmed.isEmpty && !isValid {
                Text(TXL.t("link.invalid", "Esto no parece un enlace"))
                    .font(.system(size: 12))
                    .foregroundStyle(TX.Colors.error)
            } else if isValid {
                Text(originLine)
                    .font(.system(size: 12))
                    .foregroundStyle(TX.Colors.textSecondary)
            }
            if isYouTube {
                Picker("", selection: $method) {
                    Text(TXL.t("link.method.audio", "Transcribir el audio")).tag(URLJobMethod.audio)
                    Text(TXL.t("link.method.subtitles", "Usar los subtítulos del vídeo")).tag(URLJobMethod.subtitles)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                .font(.system(size: 13))
                Text(method == .subtitles
                     ? TXL.t("link.method.subtitles.help", "Más rápido; sin marcas de tiempo por segmento. Si el vídeo no tiene subtítulos, se transcribirá el audio.")
                     : TXL.t("link.method.audio.help", "Descarga el audio y lo transcribe en este Mac."))
                    .font(.system(size: 11))
                    .foregroundStyle(TX.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !(isYouTube && method == .subtitles) {
                QuickSettingsRow(model: quick, compact: true)
            }
        }
    }

    private var originLine: String {
        if isYouTube {
            return method == .subtitles
                ? TXL.t("link.origin.youtubeSubtitles", "YouTube · subtítulos del vídeo")
                : TXL.t("link.origin.youtube", "YouTube · descarga con yt-dlp")
        }
        return TXL.t("link.origin.other", "Otro sitio · se descargará el audio")
    }

    // MARK: Progress inside the sheet

    private func progressBlock(_ job: TranscriptionJob) -> some View {
        let p = JobPresentation(job)
        return VStack(alignment: .leading, spacing: 8) {
            Text(trimmed)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(TX.Colors.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if job.subtitlesFallback {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(TX.Colors.warning).accessibilityHidden(true)
                    Text(TXL.t("link.notice.noSubtitles.text", "Este vídeo no tiene subtítulos. Se transcribirá el audio en tu Mac."))
                        .font(.system(size: 12)).foregroundStyle(TX.Colors.textPrimary)
                }
            }
            Text(p.statusLine)
                .font(.system(size: 13).monospacedDigit())
                .foregroundStyle(TX.Colors.textPrimary)
            if let kind = p.progress { TXProgressLine(kind: kind) }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Buttons

    private var buttons: some View {
        HStack {
            Spacer()
            if let job, job.status != .failed {
                Button(TXL.t("link.cancelJob", "Cancelar trabajo")) {
                    workspace.cancel(job: job.id)
                    dismiss()
                }
                .buttonStyle(TXSecondaryButtonStyle())
                Button(TXL.t("link.background", "Seguir en segundo plano")) { dismiss() }
                    .buttonStyle(TXPrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            } else {
                Button(TXL.t("common.cancel", "Cancelar")) { dismiss() }
                    .buttonStyle(TXSecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button(TXL.t("link.start", "Descargar y transcribir")) { start() }
                    .buttonStyle(TXPrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
        }
    }

    private func start() {
        guard isValid else { return }
        let m: URLJobMethod = isYouTube ? method : .audio
        if let existingJobId, jobs.job(existingJobId)?.status == .failed {
            jobs.changeLink(jobId: existingJobId, to: trimmed)
            jobId = existingJobId
            return
        }
        if let failed = jobId, jobs.job(failed)?.status == .failed {
            jobs.changeLink(jobId: failed, to: trimmed)
            return
        }
        jobId = jobs.enqueueLink(trimmed, method: m, settings: quick.settings, presetName: quick.presetTitle)
    }
}
