import SwiftUI
import AppKit

/// Trabajo en proceso (spec 6.6): title, origin, settings, phases, actions, error panel by
/// cause, and the segments the engine has produced so far (F04 streaming).
struct JobView: View {
    let job: TranscriptionJob
    @EnvironmentObject var workspace: WorkspaceState
    @ObservedObject private var downloads = ModelDownloadCenter.shared

    var body: some View {
        let p = JobPresentation(job)
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header(p)
                if job.status == .failed { JobErrorPanel(job: job) }
                if job.status == .waitingModel { waitingModelPanel }
                if job.status == .processing || job.status == .queued { phases(p) }
                actions
                if !job.streamSegments.isEmpty || job.status == .processing {
                    StreamedText(job: job)
                }
            }
            .frame(maxWidth: 560, alignment: .leading)
            .padding(.vertical, TX.Space.s40)
            .padding(.horizontal, TX.Space.s32)
            .frame(maxWidth: .infinity)
        }
        .background(TX.Colors.bgWindow)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(TXL.t("region.job", "Trabajo en proceso"))
    }

    // MARK: Header

    private func header(_ p: JobPresentation) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(p.title)
                    .txStyle(TX.Typography.documentTitle)
                    .foregroundStyle(TX.Colors.textPrimary)
                    .lineLimit(2)
                if let tag = p.tag { TXStatusTag(text: tag.0, kind: tag.1) }
            }
            Text(origin)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(TX.Colors.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(origin)
            FlowTags(tags: QuickSettingsModel.summaryTags(for: job.settings, presetName: job.urlMethod == .subtitles ? nil : job.presetName)
                     + (job.urlMethod == .subtitles ? [TXL.t("link.method.subtitles.tag", "Subtítulos de YouTube")] : [])
                     + (job.languageNotice.map { [$0] } ?? []))
        }
    }

    private var origin: String {
        if case .url(let link) = job.source { return link }
        return TXFormat.displayPath(job.fileURL.path)
    }

    // MARK: Phases (done ✓, current indicator, pending ○)

    private func phases(_ p: JobPresentation) -> some View {
        let steps = JobStep.steps(for: job)
        let current = JobStep.current(for: job)
        let currentIndex = current.flatMap { steps.firstIndex(of: $0) } ?? (job.status == .queued ? -1 : 0)
        return VStack(alignment: .leading, spacing: 10) {
            if job.status == .queued {
                HStack(spacing: 8) {
                    Text(p.statusLine).font(.system(size: 13)).foregroundStyle(TX.Colors.textSecondary)
                }
                TXProgressLine(kind: .waiting).frame(maxWidth: 240)
            }
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(spacing: 10) {
                    Group {
                        if index < currentIndex {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(TX.Colors.success)
                        } else if index == currentIndex {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "circle").foregroundStyle(TX.Colors.textTertiary)
                        }
                    }
                    .frame(width: 16)
                    .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(index == currentIndex ? p.phaseText : step.title)
                            .font(.system(size: 13, weight: index == currentIndex ? .medium : .regular).monospacedDigit())
                            .foregroundStyle(index <= currentIndex ? TX.Colors.textPrimary : TX.Colors.textSecondary)
                        if index == currentIndex, let kind = p.progress {
                            TXProgressLine(kind: kind).frame(maxWidth: 320)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityValue(index < currentIndex ? TXL.t("job.step.done", "hecho") : (index == currentIndex ? TXL.t("job.step.current", "en curso") : TXL.t("job.step.pending", "pendiente")))
            }
        }
    }

    // MARK: Waiting for a model

    @ViewBuilder private var waitingModelPanel: some View {
        let modelId = job.settings.selectedModelId
        let desc = ModelCatalog.descriptor(id: modelId)
        let modelDisplayName = desc?.displayName ?? modelId
        let technicalName = modelId

        VStack(alignment: .leading, spacing: 8) {
            switch downloads.state(for: modelId) {
            case .downloading(let received, let total):
                Text(total > 0
                     ? TXL.f("model.downloading.bytes", "Descargando %@ · %@ de %@", modelDisplayName, TXFormat.bytes(received), TXFormat.bytes(total))
                     : TXL.f("model.downloading", "Descargando %@…", modelDisplayName))
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundStyle(TX.Colors.textPrimary)
                    .help(technicalName)
                TXProgressLine(kind: total > 0 ? .determinate(Double(received) / Double(total)) : .indeterminate)
                    .frame(maxWidth: 320)
                Button(TXL.t("model.cancelDownload", "Cancelar descarga")) { downloads.cancel(modelId) }
                    .buttonStyle(TXBorderlessButtonStyle())
            case .pending:
                Text(TXL.f("model.pending", "%@ espera su turno para descargarse", modelDisplayName))
                    .font(.system(size: 13)).foregroundStyle(TX.Colors.textSecondary)
                    .help(technicalName)
                TXProgressLine(kind: .waiting).frame(maxWidth: 320)
            case .failed:
                ErrorBlock(title: TXL.f("model.downloadFailed.title", "No se pudo descargar %@", modelDisplayName),
                           explanation: TXL.t("model.downloadFailed.text", "Se ha interrumpido la conexión."),
                           details: nil) {
                    Button(TXL.t("common.retry", "Reintentar")) { downloads.download(modelId) }
                        .buttonStyle(TXSecondaryButtonStyle())
                }
                .help(technicalName)
            case nil:
                Text(TXL.f("model.notDownloaded", "%@ no está descargado", modelDisplayName))
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(TX.Colors.textPrimary)
                    .help(technicalName)
                let size = ModelStorageService.shared.displaySize(for: modelId)
                Text(TXL.f("model.downloadSize", "Ocupa %@ en disco.", size))
                    .font(.system(size: 12)).foregroundStyle(TX.Colors.textSecondary)
                Button(TXL.t("model.download", "Descargar")) { downloads.download(modelId) }
                    .buttonStyle(TXSecondaryButtonStyle())
            }
        }
    }

    // MARK: Actions

    private var actions: some View {
        HStack(spacing: 12) {
            if job.status == .recoverable {
                Button(TXL.t("recovery.resume", "Reanudar")) { JobManager.shared.retry(jobId: job.id) }
                    .buttonStyle(TXPrimaryButtonStyle())
                Button(TXL.t("recovery.discardButton", "Descartar")) { RecoveryActions.confirmDiscard(job) }
                    .buttonStyle(TXSecondaryButtonStyle())
            }
            if job.canCancel {
                Button(TXL.t("job.cancel", "Cancelar trabajo")) { workspace.cancel(job: job.id) }
                    .buttonStyle(TXSecondaryButtonStyle())
            }
            if job.fileURL.isFileURL, FileManager.default.fileExists(atPath: job.fileURL.path) {
                Button(TXL.t("common.showInFinder", "Mostrar en Finder")) {
                    NSWorkspace.shared.activateFileViewerSelecting([job.fileURL])
                }
                .buttonStyle(TXBorderlessButtonStyle())
            }
        }
    }
}

// MARK: - Error panel (spec 8.3, 8.4)

struct JobErrorPanel: View {
    let job: TranscriptionJob
    @EnvironmentObject var workspace: WorkspaceState

    var body: some View {
        let error = job.error ?? JobError(kind: .other, message: job.errorMessage ?? "", technicalDetails: nil)
        switch error.kind {
        case .link(let linkError):
            let copy = LinkErrorCopy(linkError)
            ErrorBlock(title: copy.title, explanation: copy.explanation, details: error.technicalDetails) {
                if copy.canChangeLink {
                    Button(TXL.t("link.change", "Cambiar enlace")) {
                        if case .url(let link) = job.source {
                            workspace.sheet = .url(prefill: link, fromScheme: false, jobId: job.id)
                        }
                    }
                    .buttonStyle(TXSecondaryButtonStyle())
                }
                if copy.canRetry {
                    Button(TXL.t("common.retry", "Reintentar")) { JobManager.shared.retry(jobId: job.id) }
                        .buttonStyle(TXSecondaryButtonStyle())
                }
                if case .dependencyMissing = linkError {
                    CopyCommandButton(command: "brew install yt-dlp")
                }
            }
        case .missingDependency(let name):
            ErrorBlock(title: TXL.f("error.missing.title", "Falta %@", name),
                       explanation: name == "FFmpeg"
                        ? TXL.t("error.missing.ffmpeg", "Hace falta para leer audio y vídeo.")
                        : TXL.t("error.missing.whisper", "Hace falta para transcribir."),
                       details: error.technicalDetails) {
                if name == "FFmpeg" { CopyCommandButton(command: "brew install ffmpeg") }
                Button(TXL.t("diagnostics.open", "Abrir diagnóstico")) { workspace.sheet = .diagnostics }
                    .buttonStyle(TXSecondaryButtonStyle())
                Button(TXL.t("common.retry", "Reintentar")) { JobManager.shared.retry(jobId: job.id) }
                    .buttonStyle(TXBorderlessButtonStyle())
            }
        case .unreadableFile:
            ErrorBlock(title: TXL.t("error.unreadable.title", "No se puede leer este archivo"),
                       explanation: TXL.t("error.unreadable.text", "FFmpeg no reconoce su formato o está dañado."),
                       details: error.technicalDetails) {
                Button(TXL.t("common.showInFinder", "Mostrar en Finder")) {
                    NSWorkspace.shared.activateFileViewerSelecting([job.fileURL])
                }
                .buttonStyle(TXSecondaryButtonStyle())
                Button(TXL.t("job.remove", "Quitar")) {
                    JobManager.shared.remove(jobId: job.id)
                    workspace.goHome()
                }
                .buttonStyle(TXSecondaryButtonStyle())
            }
        case .modelDownload(let model):
            let desc = ModelCatalog.descriptor(id: model)
            let modelDisplayName = desc?.displayName ?? model
            ErrorBlock(title: TXL.f("model.downloadFailed.title", "No se pudo descargar %@", modelDisplayName),
                       explanation: TXL.t("model.downloadFailed.text", "Se ha interrumpido la conexión."),
                       details: error.technicalDetails) {
                Button(TXL.t("common.retry", "Reintentar")) { JobManager.shared.retry(jobId: job.id) }
                    .buttonStyle(TXSecondaryButtonStyle())
            }
            .help(model)
        case .engine, .other:
            ErrorBlock(title: TXL.t("error.engine.title", "La transcripción se ha detenido"),
                       explanation: TXL.t("error.engine.text", "whisper terminó con un error."),
                       details: error.technicalDetails ?? error.message) {
                Button(TXL.t("common.retry", "Reintentar")) { JobManager.shared.retry(jobId: job.id) }
                    .buttonStyle(TXSecondaryButtonStyle())
                    .disabled(!job.canRetry)
                Menu(TXL.t("error.tryOtherModel", "Probar con otro modelo")) {
                    ForEach(ModelCatalog.all.filter { $0.id != job.settings.selectedModelId }) { entry in
                        Button("\(entry.displayName) · \(entry.engine.badge)") {
                            JobManager.shared.retry(jobId: job.id, modelId: entry.id)
                        }
                        .help(entry.id)
                    }
                }
                .fixedSize()
            }
        }
        if job.status == .failed {
            Button(TXL.t("job.removeFromQueue", "Quitar de la cola")) {
                JobManager.shared.remove(jobId: job.id)
                workspace.goHome()
            }
            .buttonStyle(TXBorderlessButtonStyle(tint: TX.Colors.textSecondary))
        }
    }
}

/// Error with title, explanation, actions and folded technical details (SF Mono 11 + Copiar).
struct ErrorBlock<Actions: View>: View {
    let title: String
    let explanation: String
    let details: String?
    @ViewBuilder var actions: () -> Actions
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "xmark.octagon")
                    .foregroundStyle(TX.Colors.error)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(TX.Colors.textPrimary)
                    Text(explanation)
                        .font(.system(size: 13))
                        .foregroundStyle(TX.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 8) { actions() }
                .padding(.leading, 24)
            if let details, !details.isEmpty {
                DisclosureGroup(isExpanded: $expanded) {
                    VStack(alignment: .leading, spacing: 6) {
                        ScrollView {
                            Text(details)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(TX.Colors.textSecondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 160)
                        Button(TXL.t("common.copy", "Copiar")) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(details, forType: .string)
                        }
                        .buttonStyle(TXBorderlessButtonStyle())
                    }
                    .padding(.top, 6)
                } label: {
                    Text(TXL.t("common.technicalDetails", "Detalles técnicos"))
                        .font(.system(size: 12))
                        .foregroundStyle(TX.Colors.textSecondary)
                }
                .padding(.leading, 24)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: TX.Radius.row, style: .continuous).fill(TX.Colors.error.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: TX.Radius.row, style: .continuous).strokeBorder(TX.Colors.error.opacity(0.4), lineWidth: 1))
        .accessibilityElement(children: .contain)
    }
}

struct CopyCommandButton: View {
    let command: String
    @State private var copied = false
    var body: some View {
        Button(copied ? TXL.t("common.copied", "Copiado") : TXL.t("common.copyInstall", "Copiar comando de instalación")) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
        }
        .buttonStyle(TXSecondaryButtonStyle())
        .help(command)
    }
}

/// Wrapping row of chips.
struct FlowTags: View {
    let tags: [String]
    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(tags, id: \.self) { TXChip(text: $0) }
        }
    }
}

// MARK: - Streamed segments (read-only, anchored to the end)

struct StreamedText: View {
    let job: TranscriptionJob
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pinnedToEnd = true
    @State private var seenCount = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TXSeparator()
            Text(TXL.t("job.stream.title", "Texto recibido"))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(TX.Colors.textTertiary)
                .textCase(.uppercase)
            Text(TXL.t("job.stream.hint", "Podrás editar el texto cuando termine la transcripción."))
                .font(.system(size: 12))
                .foregroundStyle(TX.Colors.textSecondary)
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(job.streamSegments) { segment in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(TXFormat.timestamp(segment.start, documentDuration: job.fileDuration ?? segment.end))
                            .txStyle(TX.Typography.timestamp)
                            .foregroundStyle(TX.Colors.textTertiary)
                            .frame(width: 64, alignment: .leading)
                        Text(segment.text)
                            .txStyle(TX.Typography.transcript)
                            .foregroundStyle(TX.Colors.textPrimary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 4)))
                }
                if job.status == .processing {
                    WaitingFragments().padding(.leading, 76).padding(.top, 4)
                }
            }
            .animation(reduceMotion ? .easeOut(duration: 0.12) : TX.Motion.liveSegment, value: job.streamSegments.count)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(TXL.t("job.stream.a11y", "Texto recibido hasta ahora"))
    }
}
