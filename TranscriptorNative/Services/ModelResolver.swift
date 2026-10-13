import Foundation

/// Por qué un modelo no sirve para una tarea concreta (texto secundario del selector, 6.1).
enum ModelIncompatibility: Equatable, Sendable {
    case language
    case translateNeedsWhisper
    case notRealtime
    case needsOS(Int)

    /// Textos de 6.1.
    var reason: String {
        switch self {
        case .language: return TXL.t("models.incompat.language", "No admite este idioma")
        case .translateNeedsWhisper: return TXL.t("models.incompat.translate", "No traduce al inglés")
        case .notRealtime: return TXL.t("models.incompat.realtime", "No funciona en tiempo real")
        case .needsOS(let v): return TXL.f("models.incompat.os", "Necesita macOS %d", v)
        }
    }
}

/// Entorno del que depende la resolución. Todo es inyectable para poder probarlo.
struct ModelResolverContext: Sendable {
    /// IDs técnicos con archivos presentes y sanos en disco.
    var installed: Set<String>
    var osMajor: Int
    var showExperimental: Bool = false
    /// Código ISO elegido o detectado; `nil`/«auto» = desconocido.
    var language: String?
    var translateToEnglish: Bool = false

    var knownLanguage: String? {
        guard let l = language?.lowercased(), !l.isEmpty, l != "auto" else { return nil }
        return String(l.prefix(2))
    }
}

/// Aviso de cambio de modelo (6.4): se muestra como banner, nunca como alerta modal.
enum ModelNotice: Equatable, Sendable {
    /// El modelo pedido no admite el idioma/ajuste; se usa `used`.
    case incompatible(requested: String, used: String, reason: ModelIncompatibility)
    /// El modelo pedido no está descargado; se usa `used` esta vez.
    case notDownloaded(requested: String, used: String?)
    /// Subtítulos en vivo sin modelo compatible para el idioma.
    case noLiveModel(language: String)
}

struct ModelResolution: Equatable, Sendable {
    /// Modelo a usar ahora. `nil` si no hay ninguno utilizable.
    var model: ModelDescriptor?
    /// Modelo que se quiso usar y no está descargado (la UI ofrece «Descargar»).
    var needsDownload: ModelDescriptor?
    var notice: ModelNotice?
}

/// Reglas de la sección 5.3, en orden:
/// 1. elección explícita compatible y descargada;
/// 2. Automático según la tarea;
/// incompatibilidades → siguiente compatible + aviso; nunca descarga nada por sí mismo.
enum ModelResolver {
    // IDs técnicos usados por las reglas automáticas.
    static let fast = "parakeet-tdt-0.6b-v3"
    static let turbo = "large-v3-turbo"
    static let live = "nemotron-streaming-multilingual-0.6b"
    static let liveEnglish = "nemotron-streaming-en-0.6b"

    static func incompatibility(of m: ModelDescriptor, task: ModelTask, in ctx: ModelResolverContext) -> ModelIncompatibility? {
        if ctx.osMajor < m.minOS { return .needsOS(m.minOS) }
        if task == .liveCaptions, !m.supportsStreaming { return .notRealtime }
        if task != .liveCaptions, m.supportsStreaming { return .notRealtime }
        if let lang = ctx.knownLanguage, !m.languages.contains(lang) { return .language }
        if ctx.translateToEnglish, !m.capabilities.supportsTranslateToEnglish { return .translateNeedsWhisper }
        return nil
    }

    private static func usable(_ id: String, task: ModelTask, _ ctx: ModelResolverContext) -> ModelDescriptor? {
        guard let m = ModelCatalog.descriptor(id: id),
              ctx.installed.contains(id),
              incompatibility(of: m, task: task, in: ctx) == nil else { return nil }
        return m
    }

    /// Modelo «deseado» en Automático para la tarea (aunque no esté descargado).
    static func automaticTarget(task: ModelTask, filesAssignment: ModelAssignment = .automatic,
                                in ctx: ModelResolverContext) -> ModelDescriptor? {
        func byId(_ id: String) -> ModelDescriptor? { ModelCatalog.descriptor(id: id) }
        func pickFiles() -> ModelDescriptor? {
            let fastOK = byId(fast).map { incompatibility(of: $0, task: .files, in: ctx) == nil } ?? false
            return fastOK ? byId(fast) : byId(turbo)
        }
        switch task {
        case .files, .recording:
            return pickFiles()
        case .dictation:
            return byId(fast)
        case .liveCaptions:
            if let m = byId(live), incompatibility(of: m, task: .liveCaptions, in: ctx) == nil { return m }
            if ctx.knownLanguage == "en" { return byId(liveEnglish) }
            return nil
        }
    }

    /// Mejor Whisper instalado, de más a menos preciso: último recurso cuando falta el deseado.
    private static let whisperFallbackOrder = ["large-v3", "large-v3-turbo", "large-v2", "medium", "small", "base", "tiny"]

    static func resolve(task: ModelTask, assignment: ModelAssignment, filesAssignment: ModelAssignment = .automatic,
                        in ctx: ModelResolverContext) -> ModelResolution {
        // 1. Elección explícita.
        if case .model(let id) = assignment, let requested = ModelCatalog.descriptor(id: id) {
            if let why = incompatibility(of: requested, task: task, in: ctx) {
                // Incompatible: siguiente compatible (el automático de la tarea) + aviso.
                var r = resolve(task: task, assignment: .automatic, filesAssignment: filesAssignment, in: ctx)
                if let used = r.model {
                    r.notice = .incompatible(requested: requested.id, used: used.id, reason: why)
                } else if task == .liveCaptions, let l = ctx.knownLanguage {
                    r.notice = .noLiveModel(language: l)
                }
                return r
            }
            if ctx.installed.contains(requested.id) {
                return ModelResolution(model: requested, needsDownload: nil, notice: nil)
            }
            // Compatible pero sin descargar: nunca en silencio.
            let alt = fallbackInstalled(task: task, excluding: requested.id, filesAssignment: filesAssignment, ctx)
            return ModelResolution(model: alt, needsDownload: requested,
                                   notice: .notDownloaded(requested: requested.id, used: alt?.id))
        }

        // 2. Automático.
        guard let target = automaticTarget(task: task, in: ctx) else {
            return ModelResolution(model: nil, needsDownload: nil,
                                   notice: task == .liveCaptions ? ctx.knownLanguage.map { .noLiveModel(language: $0) } : nil)
        }
        if let ok = usable(target.id, task: task, ctx) {
            return ModelResolution(model: ok, needsDownload: nil, notice: nil)
        }
        let alt = fallbackInstalled(task: task, excluding: target.id, filesAssignment: filesAssignment, ctx)
        // En Automático solo avisamos si había algo que descargar y nada mejor instalado.
        return ModelResolution(model: alt, needsDownload: target,
                               notice: alt.map { _ in .notDownloaded(requested: target.id, used: alt?.id) }
                                   ?? .notDownloaded(requested: target.id, used: nil))
    }

    /// Cadena de fallback cuando falta el modelo deseado.
    /// Dictado: Rápido → Turbo → modelo de archivos. Resto: Turbo → cualquier compatible instalado.
    private static func fallbackInstalled(task: ModelTask, excluding: String, filesAssignment: ModelAssignment,
                                          _ ctx: ModelResolverContext) -> ModelDescriptor? {
        if task == .liveCaptions {
            return [live, liveEnglish].filter { $0 != excluding }.compactMap { usable($0, task: task, ctx) }.first
        }
        var chain: [String] = []
        if task == .dictation { chain.append(fast) }
        chain.append(turbo)
        if task == .dictation, case .model(let id) = filesAssignment { chain.append(id) }
        chain.append(contentsOf: [fast])
        chain.append(contentsOf: whisperFallbackOrder)
        var seen = Set<String>([excluding])
        for id in chain where seen.insert(id).inserted {
            if let m = usable(id, task: task, ctx) { return m }
        }
        return nil
    }
}
