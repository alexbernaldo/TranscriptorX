import SwiftUI

/// How a job is shown everywhere (sidebar row, job view, menu bar). Single mapping from
/// the real job state to text, progress kind and tag (spec 6.6, 8.1, 8.2).
@MainActor
struct JobPresentation {
    let job: TranscriptionJob
    var queuePosition: Int?
    var modelDownload: ModelDownloadCenter.State?

    init(_ job: TranscriptionJob) {
        self.job = job
        self.queuePosition = JobManager.shared.queuePosition(of: job.id)
        self.modelDownload = ModelDownloadCenter.shared.state(for: job.settings.selectedModelId)
    }

    var title: String { job.displayTitle }

    /// «Transcribiendo · 34 %», «En cola · 2.º», «Descargando · 34 MB de 80 MB»…
    var statusLine: String {
        let base = phaseText
        if case .watchedFolder(let name) = job.source { return "\(name) · \(base)" }
        return base
    }

    var phaseText: String {
        switch job.status {
        case .failed:
            return TXL.f("job.status.error", "Error · %@", shortError)
        case .recoverable:
            return TXL.t("job.status.recoverable", "No terminó la última vez")
        case .waitingModel:
            let model = job.settings.selectedModelId
            switch modelDownload {
            case .downloading(let received, let total) where total > 0:
                return TXL.f("job.status.waitingModelProgress", "Esperando modelo · descargando %@ (%d %%)", model, Int(Double(received) / Double(total) * 100))
            case .downloading, .pending:
                return TXL.f("job.status.waitingModelDownloading", "Esperando modelo · descargando %@", model)
            case .failed:
                return TXL.f("job.status.modelFailed", "No se pudo descargar %@", model)
            case nil:
                return TXL.f("job.status.modelMissing", "%@ no está descargado", model)
            }
        case .queued:
            if let p = queuePosition, p > 0 {
                return TXL.f("job.status.queuedPosition", "En cola · %@", Self.ordinal(p))
            }
            return TXL.t("job.status.queued", "En cola")
        case .completed:
            return TXL.t("job.status.ready", "Lista")
        case .cancelled:
            return TXL.t("job.status.cancelled", "Cancelado")
        case .processing:
            switch job.phase {
            case .queued, .finishing:
                return TXL.t("job.phase.preparing", "Preparando…")
            case .waitingModel:
                return TXL.t("job.phase.waitingModel", "Esperando modelo")
            case .downloading(let received, let total, let fraction):
                if let received, let total, total > 0 {
                    return TXL.f("job.phase.downloadingBytes", "Descargando · %@ de %@", TXFormat.bytes(received), TXFormat.bytes(total))
                }
                if let fraction { return TXL.f("job.phase.downloadingPercent", "Descargando · %d %%", Int(fraction * 100)) }
                return TXL.t("job.phase.downloading", "Descargando…")
            case .retryingDownload:
                return TXL.t("job.phase.retrying", "Reintentando con otro método de descarga (Innertube)…")
            case .fetchingSubtitles:
                return TXL.t("job.phase.subtitles", "Obteniendo los subtítulos del vídeo…")
            case .loadingModel:
                return TXL.t("job.phase.loadingModel", "Cargando modelo…")
            case .preprocessing(let detail):
                if let detail { return TXL.f("job.phase.preprocessingDetail", "Preprocesando audio · %@", detail) }
                return TXL.t("job.phase.preprocessing", "Preprocesando audio…")
            case .transcribing:
                if job.hasMeasuredProgress { return TXL.f("job.phase.transcribingPercent", "Transcribiendo · %d %%", job.progress) }
                return TXL.t("job.phase.transcribing", "Transcribiendo…")
            case .downloadingSpeakerModels(let fraction):
                if let fraction { return TXL.f("job.phase.speakerModelsPercent", "Descargando el modelo de hablantes · %d %%", Int(fraction * 100)) }
                return TXL.t("job.phase.speakerModels", "Preparando el modelo de hablantes…")
            case .detectingSpeakers(let fraction):
                if let fraction { return TXL.f("job.phase.speakersPercent", "Identificando hablantes · %d %%", Int(fraction * 100)) }
                return TXL.t("job.phase.speakers", "Identificando hablantes…")
            }
        }
    }

    /// Progress rule: measured → determinate; working → indeterminate; waiting → dashed.
    var progress: TXProgressKind? {
        switch job.status {
        case .queued, .waitingModel:
            if case .downloading(let r, let t) = modelDownload, t > 0, job.status == .waitingModel {
                return .determinate(Double(r) / Double(t))
            }
            return .waiting
        case .processing:
            switch job.phase {
            case .downloading(_, _, let fraction): return fraction.map { .determinate($0) } ?? .indeterminate
            case .transcribing: return job.hasMeasuredProgress ? .determinate(Double(job.progress) / 100) : .indeterminate
            case .downloadingSpeakerModels(let fraction), .detectingSpeakers(let fraction):
                return fraction.map { .determinate($0) } ?? .indeterminate
            default: return .indeterminate
            }
        default:
            return nil
        }
    }

    /// Status tag (spec 3.4): En cola (neutral), Preparando/Transcribiendo (purple), Descargando (info),
    /// Error, Recuperable (warning).
    var tag: (String, TXTagKind)? {
        switch job.status {
        case .failed: return (TXL.t("job.tag.error", "Error"), .error)
        case .recoverable: return (TXL.t("job.tag.recoverable", "Recuperable"), .warning)
        case .queued: return (TXL.t("job.tag.queued", "En cola"), .neutral)
        case .waitingModel: return (TXL.t("job.tag.waitingModel", "Esperando modelo"), .neutral)
        case .processing:
            switch job.phase {
            case .downloading, .retryingDownload, .fetchingSubtitles: return (TXL.t("job.tag.downloading", "Descargando"), .info)
            case .transcribing: return (TXL.t("job.tag.transcribing", "Transcribiendo"), .purple)
            case .downloadingSpeakerModels: return (TXL.t("job.tag.downloading", "Descargando"), .info)
            case .detectingSpeakers: return (TXL.t("job.tag.speakers", "Hablantes"), .purple)
            default: return (TXL.t("job.tag.preparing", "Preparando"), .purple)
            }
        default: return nil
        }
    }

    var shortError: String {
        guard let error = job.error else { return job.errorMessage ?? "" }
        switch error.kind {
        case .link(let e): return LinkErrorCopy(e).title
        case .missingDependency(let name): return TXL.f("error.missing.short", "Falta %@", name)
        case .unreadableFile: return TXL.t("error.unreadable.short", "Archivo ilegible")
        case .engine: return TXL.t("error.engine.short", "La transcripción se detuvo")
        case .modelDownload: return TXL.t("error.modelDownload.short", "Modelo no descargado")
        case .other: return error.message
        }
    }

    var accessibilityLabel: String {
        "\(title), \(phaseText)"
    }

    var accessibilityValue: String? {
        if case .determinate(let v)? = progress { return "\(Int(v * 100)) %" }
        return nil
    }

    static func ordinal(_ n: Int) -> String {
        TXL.isSpanish ? "\(n).º" : {
            let suffix: String
            switch (n % 10, n % 100) {
            case (1, let h) where h != 11: suffix = "st"
            case (2, let h) where h != 12: suffix = "nd"
            case (3, let h) where h != 13: suffix = "rd"
            default: suffix = "th"
            }
            return "\(n)\(suffix)"
        }()
    }
}

/// Phases listed in the job view (done / current / pending).
enum JobStep: CaseIterable {
    case downloading, preparing, loadingModel, preprocessing, transcribing, speakers

    var title: String {
        switch self {
        case .downloading: return TXL.t("job.step.downloading", "Descargando")
        case .preparing: return TXL.t("job.step.preparing", "Preparando")
        case .loadingModel: return TXL.t("job.step.loadingModel", "Cargando modelo")
        case .preprocessing: return TXL.t("job.step.preprocessing", "Preprocesando audio")
        case .transcribing: return TXL.t("job.step.transcribing", "Transcribiendo")
        case .speakers: return TXL.t("job.step.speakers", "Identificando hablantes")
        }
    }

    static func steps(for job: TranscriptionJob) -> [JobStep] {
        let speakers: [JobStep] = job.settings.enableDiarization ? [.speakers] : []
        if job.isLink {
            if job.urlMethod == .subtitles { return [.downloading] }
            return [.downloading, .preprocessing, .loadingModel, .transcribing] + speakers
        }
        return [.preparing, .preprocessing, .loadingModel, .transcribing] + speakers
    }

    static func current(for job: TranscriptionJob) -> JobStep? {
        guard job.status == .processing else { return nil }
        switch job.phase {
        case .queued, .waitingModel, .finishing: return job.isLink ? .downloading : .preparing
        case .downloading, .retryingDownload, .fetchingSubtitles: return .downloading
        case .preprocessing: return .preprocessing
        case .loadingModel: return .loadingModel
        case .transcribing: return .transcribing
        case .downloadingSpeakerModels, .detectingSpeakers: return .speakers
        }
    }
}

/// User-facing copy for link errors (spec 8.3).
struct LinkErrorCopy {
    let title: String
    let explanation: String
    let canRetry: Bool
    let canChangeLink: Bool

    init(_ error: URLTranscriptionService.TranscriptionError) {
        switch error {
        case .videoPrivate:
            title = TXL.t("link.error.private.title", "Este vídeo es privado")
            explanation = TXL.t("link.error.private.text", "Solo pueden verlo las cuentas que su autor ha autorizado.")
            canRetry = false; canChangeLink = true
        case .videoRegionBlocked:
            title = TXL.t("link.error.region.title", "No disponible en tu región")
            explanation = TXL.t("link.error.region.text", "Su autor lo ha limitado a otros países.")
            canRetry = false; canChangeLink = true
        case .videoAgeRestricted:
            title = TXL.t("link.error.age.title", "Vídeo con restricción de edad")
            explanation = TXL.t("link.error.age.text", "YouTube exige una sesión iniciada para verlo, y la descarga no tiene una que lo permita.")
            canRetry = true; canChangeLink = true
        case .videoUnavailable, .invalidURL:
            title = TXL.t("link.error.unavailable.title", "El vídeo no está disponible")
            explanation = TXL.t("link.error.unavailable.text", "Puede que se haya eliminado o que el enlace esté incompleto.")
            canRetry = false; canChangeLink = true
        case .cookiesRequired:
            title = TXL.t("link.error.cookies.title", "No se pudieron usar las cookies")
            explanation = TXL.t("link.error.cookies.text", "YouTube ha pedido verificar la sesión y la descarga no ha podido leer las cookies del navegador.")
            canRetry = true; canChangeLink = false
        case .subtitlesDisabled, .noTranscriptAvailable:
            title = TXL.t("link.error.noSubtitles.title", "Este vídeo no tiene subtítulos")
            explanation = TXL.t("link.error.noSubtitles.text", "Elige «Transcribir el audio» para transcribirlo en tu Mac.")
            canRetry = false; canChangeLink = true
        case .dependencyMissing:
            title = TXL.t("link.error.ytdlp.title", "Falta yt-dlp")
            explanation = TXL.t("link.error.ytdlp.text", "Hace falta para descargar desde enlaces.")
            canRetry = true; canChangeLink = false
        case .pythonNotFound:
            title = TXL.t("link.error.python.title", "Falta Python")
            explanation = TXL.t("link.error.python.text", "Hace falta para leer los subtítulos de YouTube. Puedes transcribir el audio en su lugar.")
            canRetry = true; canChangeLink = false
        case .networkError, .downloadFailed, .whisperFailed, .cancelled:
            title = TXL.t("link.error.site.title", "Este sitio no permite la descarga")
            explanation = TXL.t("link.error.site.text", "No se encontró audio que se pueda descargar en esta página.")
            canRetry = true; canChangeLink = true
        }
    }
}
