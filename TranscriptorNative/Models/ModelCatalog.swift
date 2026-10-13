import Foundation

// MARK: - Engines

/// Motor que ejecuta un modelo. El texto visible (insignia) sale de `badge`.
enum ModelEngineKind: String, Codable, CaseIterable, Sendable {
    case whisper, parakeet, nemotron, cohere

    /// Insignia de motor en la vista normal: solo el nombre comercial.
    var badge: String {
        switch self {
        case .whisper: return "Whisper"
        case .parakeet: return "Parakeet"
        case .nemotron: return "Nemotron"
        case .cohere: return "Cohere"
        }
    }
}

enum ModelComputeUnits: String, Codable, Sendable {
    case neuralEngine, cpuAndGPU, cpuOnly
}

/// Idiomas que admite un motor/modelo.
enum LanguageSupport: Equatable, Sendable {
    case any
    case only(Set<String>)

    func contains(_ code: String) -> Bool {
        switch self {
        case .any: return true
        case .only(let set): return set.contains(code)
        }
    }
}

/// Capacidades declaradas por un motor. Valores por defecto de cada motor en `TranscriptionEngines`.
struct EngineCapabilities: Equatable, Sendable {
    var supportsStreaming: Bool
    var supportsWordTimestamps: Bool
    var supportsTranslateToEnglish: Bool
    var supportedLanguages: LanguageSupport
    var isEnglishOnly: Bool
    var computeUnits: ModelComputeUnits
    /// Versión mayor mínima de macOS.
    var minOSMajor: Int
    /// Duración máxima por llamada (Cohere: 35 s). `nil` = sin límite.
    var maxChunkSeconds: Double?
}

/// Abstracción de motor. whisper.cpp se ejecuta hoy como subproceso (`TranscriptionService`);
/// su implementación solo declara capacidades y no cambia el comportamiento.
protocol TranscriptionEngine: Sendable {
    static var kind: ModelEngineKind { get }
    static var capabilities: EngineCapabilities { get }
}

enum WhisperCLIEngine: TranscriptionEngine {
    static let kind = ModelEngineKind.whisper
    static let capabilities = EngineCapabilities(
        supportsStreaming: false, supportsWordTimestamps: true, supportsTranslateToEnglish: true,
        supportedLanguages: .any, isEnglishOnly: false, computeUnits: .neuralEngine,
        minOSMajor: 14, maxChunkSeconds: nil)
}

// MARK: - Descriptor

enum ModelGroup: Int, Codable, CaseIterable, Comparable, Sendable {
    case recommended, advanced, experimental
    static func < (a: ModelGroup, b: ModelGroup) -> Bool { a.rawValue < b.rawValue }
}

enum ModelTask: String, Codable, CaseIterable, Sendable {
    case files, recording, liveCaptions, dictation
}

/// Estado de un modelo en este Mac.
enum ModelState: Equatable, Sendable {
    case notDownloaded
    case downloading(progress: Double)
    case ready
    case corrupt
    case unsupportedOS(required: Int)
}

/// Escala relativa 1…5, orientativa (no son WER ni RTF medidos).
struct ModelScales: Equatable, Sendable {
    let speed: Int
    let accuracy: Int
}

struct ModelDescriptor: Identifiable, Equatable, Sendable {
    /// ID técnico: clave persistente; nunca cambia.
    let id: String
    let engine: ModelEngineKind
    /// Claves de Localizable (el español es la base).
    let nameKey: String, nameDefault: String
    let subtitleKey: String, subtitleDefault: String
    let group: ModelGroup
    let languages: LanguageSupport
    let capabilities: EngineCapabilities
    let sourceRepo: String
    let license: String
    let attribution: String?
    let scales: ModelScales
    /// Etiqueta de capacidad (p. ej. «Neural Engine», «Tiempo real»), clave + texto.
    let capabilityBadgeKey: String?, capabilityBadgeDefault: String?
    /// Parakeet Redux solo se muestra si el paquete resuelto lo expone.
    var minOS: Int { capabilities.minOSMajor }
    var isEnglishOnly: Bool { capabilities.isEnglishOnly }
    var supportsStreaming: Bool { capabilities.supportsStreaming }

    /// Nombre localizado (la UI usa esto; el ID solo con «Mostrar nombres técnicos»).
    var displayName: String { TXL.t(nameKey, nameDefault) }
    var subtitle: String { TXL.t(subtitleKey, subtitleDefault) }
}

// MARK: - Catalog

enum ModelCatalog {
    static let languagesParakeetV3: Set<String> = [
        "bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el", "hu", "it",
        "lv", "lt", "mt", "pl", "pt", "ro", "sk", "sl", "es", "sv", "ru", "uk"]
    static let languagesNemotronMultilingual: Set<String> = ["en", "es", "fr", "it", "pt", "de", "zh", "ja"]

    private static func caps(
        _ base: EngineCapabilities, streaming: Bool? = nil, english: Bool? = nil,
        languages: LanguageSupport? = nil, minOS: Int? = nil, words: Bool? = nil,
        translate: Bool? = nil, chunk: Double?? = nil
    ) -> EngineCapabilities {
        var c = base
        if let streaming { c.supportsStreaming = streaming }
        if let english { c.isEnglishOnly = english }
        if let languages { c.supportedLanguages = languages }
        if let minOS { c.minOSMajor = minOS }
        if let words { c.supportsWordTimestamps = words }
        if let translate { c.supportsTranslateToEnglish = translate }
        if let chunk { c.maxChunkSeconds = chunk }
        return c
    }

    private static let parakeetBase = EngineCapabilities(
        supportsStreaming: false, supportsWordTimestamps: true, supportsTranslateToEnglish: false,
        supportedLanguages: .only(languagesParakeetV3), isEnglishOnly: false,
        computeUnits: .neuralEngine, minOSMajor: 14, maxChunkSeconds: nil)
    private static let nemotronBase = EngineCapabilities(
        supportsStreaming: true, supportsWordTimestamps: false, supportsTranslateToEnglish: false,
        supportedLanguages: .only(languagesNemotronMultilingual), isEnglishOnly: false,
        computeUnits: .neuralEngine, minOSMajor: 14, maxChunkSeconds: nil)

    private static func whisper(
        _ id: String, _ nameDefault: String, _ subtitle: String, _ group: ModelGroup,
        speed: Int, accuracy: Int
    ) -> ModelDescriptor {
        ModelDescriptor(
            id: id, engine: .whisper,
            nameKey: "model.\(id).name", nameDefault: nameDefault,
            subtitleKey: "model.\(id).subtitle", subtitleDefault: subtitle,
            group: group, languages: .any, capabilities: WhisperCLIEngine.capabilities,
            sourceRepo: "ggerganov/whisper.cpp", license: "MIT",
            attribution: nil, scales: ModelScales(speed: speed, accuracy: accuracy),
            capabilityBadgeKey: nil, capabilityBadgeDefault: nil)
    }

    /// Todos los modelos conocidos. Las escalas son **orientativas** (no medidas) hasta tener
    /// los números de `Tools/eval`.
    static let all: [ModelDescriptor] = [
        // Recomendados
        ModelDescriptor(
            id: "parakeet-tdt-0.6b-v3", engine: .parakeet,
            nameKey: "model.parakeet-v3.name", nameDefault: "Rápido",
            subtitleKey: "model.parakeet-v3.subtitle", subtitleDefault: "Dictado y archivos en idiomas europeos",
            group: .recommended, languages: .only(languagesParakeetV3), capabilities: parakeetBase,
            sourceRepo: "FluidInference/parakeet-tdt-0.6b-v3-coreml", license: "CC-BY-4.0",
            attribution: "NVIDIA Parakeet TDT 0.6B v3 (CC-BY-4.0), Core ML por FluidInference",
            scales: ModelScales(speed: 5, accuracy: 4),
            capabilityBadgeKey: "model.badge.neuralEngine", capabilityBadgeDefault: "Neural Engine"),
        whisper("large-v3-turbo", "Turbo", "La mejor relación entre calidad y velocidad", .recommended, speed: 3, accuracy: 4),
        whisper("large-v3", "Máxima precisión", "Idiomas poco comunes y conferencias", .recommended, speed: 1, accuracy: 5),
        ModelDescriptor(
            id: "nemotron-streaming-multilingual-0.6b", engine: .nemotron,
            nameKey: "model.nemotron-multi.name", nameDefault: "En vivo",
            subtitleKey: "model.nemotron-multi.subtitle", subtitleDefault: "Subtítulos y transcripción mientras grabas",
            group: .recommended, languages: .only(languagesNemotronMultilingual), capabilities: nemotronBase,
            sourceRepo: "FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML",
            license: "NVIDIA (ver model card)", attribution: nil,
            scales: ModelScales(speed: 5, accuracy: 3),
            capabilityBadgeKey: "model.badge.realtime", capabilityBadgeDefault: "Tiempo real"),
        // Avanzados
        ModelDescriptor(
            id: "parakeet-ultra", engine: .parakeet,
            nameKey: "model.parakeet-ultra.name", nameDefault: "Rápido Plus",
            subtitleKey: "model.parakeet-ultra.subtitle", subtitleDefault: "Más preciso que Rápido, misma velocidad",
            group: .advanced, languages: .only(languagesParakeetV3), capabilities: parakeetBase,
            sourceRepo: "FluidInference/parakeet-ultra-coreml", license: "CC-BY-4.0",
            attribution: "Parakeet Ultra (moondream), post-entrenamiento de NVIDIA Parakeet TDT v3 (CC-BY-4.0)",
            scales: ModelScales(speed: 5, accuracy: 4),
            capabilityBadgeKey: "model.badge.neuralEngine", capabilityBadgeDefault: "Neural Engine"),
        ModelDescriptor(
            id: "parakeet-tdt-0.6b-v2", engine: .parakeet,
            nameKey: "model.parakeet-v2.name", nameDefault: "Solo inglés",
            subtitleKey: "model.parakeet-v2.subtitle", subtitleDefault: "Máxima calidad en inglés",
            group: .advanced, languages: .only(["en"]),
            capabilities: caps(parakeetBase, english: true, languages: .only(["en"])),
            sourceRepo: "FluidInference/parakeet-tdt-0.6b-v2-coreml", license: "CC-BY-4.0",
            attribution: "NVIDIA Parakeet TDT 0.6B v2 (CC-BY-4.0), Core ML por FluidInference",
            scales: ModelScales(speed: 5, accuracy: 5),
            capabilityBadgeKey: "model.badge.englishOnly", capabilityBadgeDefault: "Solo inglés"),
        ModelDescriptor(
            id: "nemotron-streaming-en-0.6b", engine: .nemotron,
            nameKey: "model.nemotron-en.name", nameDefault: "En vivo (inglés)",
            subtitleKey: "model.nemotron-en.subtitle", subtitleDefault: "Tiempo real, solo inglés",
            group: .advanced, languages: .only(["en"]),
            capabilities: caps(nemotronBase, english: true, languages: .only(["en"])),
            sourceRepo: "FluidInference/nemotron-speech-streaming-en-0.6b-coreml",
            license: "NVIDIA (ver model card)", attribution: nil,
            scales: ModelScales(speed: 5, accuracy: 4),
            capabilityBadgeKey: "model.badge.realtime", capabilityBadgeDefault: "Tiempo real"),
        whisper("medium", "Preciso", "Podcasts", .advanced, speed: 2, accuracy: 4),
        whisper("small", "Estándar", "Clases y entrevistas en equipos modestos", .advanced, speed: 3, accuracy: 3),
        whisper("base", "Ligero", "Notas rápidas", .advanced, speed: 4, accuracy: 2),
        whisper("large-v2", "Clásico", "Audios con repeticiones", .advanced, speed: 1, accuracy: 5),
        whisper("tiny", "Express", "Solo pruebas", .advanced, speed: 5, accuracy: 1),
        // Experimentales
        ModelDescriptor(
            id: "parakeet-redux", engine: .parakeet,
            nameKey: "model.parakeet-redux.name", nameDefault: "Mini",
            subtitleKey: "model.parakeet-redux.subtitle", subtitleDefault: "Dictado en equipos con poca memoria",
            group: .experimental, languages: .only(languagesParakeetV3),
            capabilities: caps(parakeetBase, minOS: 15),
            sourceRepo: "FluidInference/parakeet-redux-coreml", license: "CC-BY-4.0",
            attribution: "Parakeet Redux (moondream), reentrenamiento ternario de NVIDIA Parakeet TDT v3 (CC-BY-4.0)",
            scales: ModelScales(speed: 5, accuracy: 3),
            capabilityBadgeKey: "model.badge.neuralEngine", capabilityBadgeDefault: "Neural Engine"),
    ]

    static func descriptor(id: String) -> ModelDescriptor? { all.first { $0.id == id } }

    /// Resuelve un ID técnico o un nombre visible («Turbo», «Ultra Rápido»), sin distinguir mayúsculas ni acentos.
    static func descriptor(matching query: String) -> ModelDescriptor? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        if let direct = all.first(where: { $0.id.lowercased() == q }) { return direct }
        if let byName = all.first(where: {
            $0.displayName.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) == q ||
            $0.nameDefault.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) == q
        }) { return byName }
        let legacyMap: [String: String] = [
            "ultra rapido": "tiny",
            "rapido": "base",
            "equilibrado": "small",
            "profesional": "large-v3-turbo",
            "maxima calidad": "large-v3"
        ]
        if let legacyId = legacyMap[q], let d = all.first(where: { $0.id == legacyId }) {
            return d
        }
        return nil
    }

    /// Devuelve el ID canónico para un nombre o ID existente o heredado.
    static func canonicalId(from query: String) -> String? {
        descriptor(matching: query)?.id
    }

    /// Nombre amigable según el ajuste «Mostrar nombres técnicos en toda la app».
    static func formattedName(for modelId: String, showTechnical: Bool = false) -> String {
        guard let d = descriptor(id: modelId) else { return modelId }
        return showTechnical ? "\(d.displayName) (\(d.id))" : d.displayName
    }

    /// ID técnico como nombre secundario/tooltip
    static func technicalName(id: String) -> String {
        id
    }

    /// Nombres anteriores para la migración/aviso de actualización único (6.5).
    static let legacyDisplayNames: [String: String] = [
        "tiny": "Ultra Rápido",
        "base": "Rápido",
        "small": "Equilibrado",
        "medium": "Preciso",
        "large-v3-turbo": "Profesional",
        "large-v2": "Large V2",
        "large-v3": "Máxima Calidad",
    ]

    /// ID técnico para un valor guardado por una versión anterior. Un nombre visible se interpreta
    /// con el significado que tenía entonces («Rápido» era `base`), no con el actual.
    static func migratedId(fromStored stored: String) -> String? {
        let raw = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        if descriptor(id: raw) != nil { return raw }
        let folded = raw.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        if let legacy = legacyDisplayNames.first(where: {
            $0.value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) == folded
        }) { return legacy.key }
        return canonicalId(from: raw)
    }

    /// Modelos visibles, por grupo, aplicando el ajuste «Mostrar modelos experimentales».
    static func visible(showExperimental: Bool) -> [ModelDescriptor] {
        all.filter { showExperimental || $0.group != .experimental }
            .sorted { ($0.group, index(of: $0)) < ($1.group, index(of: $1)) }
    }

    private static func index(of m: ModelDescriptor) -> Int { all.firstIndex(of: m) ?? 0 }

    /// Modelos que pueden asignarse a una tarea (las tareas en vivo solo listan streaming).
    static func eligible(for task: ModelTask, showExperimental: Bool) -> [ModelDescriptor] {
        visible(showExperimental: showExperimental).filter {
            task == .liveCaptions ? $0.supportsStreaming : !$0.supportsStreaming
        }
    }
}

// MARK: - Assignment

enum ModelAssignment: Equatable, Codable, Sendable {
    case automatic
    case model(String)

    private static let autoToken = "auto"
    init(storage: String?) {
        guard let storage, storage != Self.autoToken, !storage.isEmpty else { self = .automatic; return }
        let canonical = ModelCatalog.canonicalId(from: storage) ?? storage
        self = .model(canonical)
    }
    var storage: String {
        switch self { case .automatic: return Self.autoToken; case .model(let id): return id }
    }
}
