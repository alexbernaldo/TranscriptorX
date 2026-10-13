import Foundation
import SwiftUI

/// Ajustes de cada motor (Ajustes › Modelos › Avanzado). Se leen desde cualquier hilo.
enum ModelEngineSettings {
    static let keyNemotronChunk = "models.nemotron.chunkMs"
    static let keyFastVersion = "models.fast.version"

    /// Latencia elegida para Nemotron. El inglés no tiene 4480 ms: usa 2240.
    static func nemotronChunkMs(for modelId: String) -> Int {
        let saved = UserDefaults.standard.integer(forKey: keyNemotronChunk)
        let chunk = saved == 0 ? 1120 : saved
        let supported = NemotronStreamingEngine.supportedChunks(modelId: modelId)
        return supported.contains(chunk) ? chunk : (supported.last ?? 2240)
    }

    /// ID que usa «Rápido» en Automático: v3 (por defecto) o Ultra.
    static var fastModelId: String {
        UserDefaults.standard.string(forKey: keyFastVersion) == "parakeet-ultra" ? "parakeet-ultra" : ModelResolver.fast
    }
}

/// Resultado de preparar los ajustes de un trabajo: el modelo concreto y el aviso para el banner.
struct PreparedModel: Equatable {
    var settings: TranscriptionSettings
    /// El usuario tenía «Automático» (Trabajo en proceso puede afinar el modelo con el idioma detectado).
    var wasAutomatic: Bool
    var notice: ModelNotice?
}

/// Resuelve el modelo real de un trabajo o dictado. No depende del hilo principal.
enum ModelSelection {
    static let autoToken = "auto"

    static func context(language: String?, translate: Bool) -> ModelResolverContext {
        var ctx = ModelResolverContext(
            installed: ModelStorageService.shared.installedModelIds(),
            osMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
            showExperimental: UserDefaults.standard.bool(forKey: TaskModelPreferences.keyShowExperimental),
            language: language,
            translateToEnglish: translate)
        ctx.fastModelId = ModelEngineSettings.fastModelId
        return ctx
    }

    /// Cambia «auto» (o un modelo que no sirve para el idioma) por un ID concreto.
    /// Un modelo elegido a mano y sin descargar se respeta: el trabajo espera a que se descargue.
    static func prepare(_ settings: TranscriptionSettings, task: ModelTask,
                        filesAssignment: ModelAssignment = .automatic) -> PreparedModel {
        let assignment = ModelAssignment(storage: settings.selectedModelId)
        let ctx = context(language: settings.language, translate: settings.translate)
        let resolution = ModelResolver.resolve(task: task, assignment: assignment,
                                               filesAssignment: filesAssignment, in: ctx)
        var out = settings
        switch assignment {
        case .automatic:
            guard let id = resolution.model?.id ?? resolution.needsDownload?.id else {
                return PreparedModel(settings: settings, wasAutomatic: true, notice: resolution.notice)
            }
            out.selectedModelId = id
            let notice: ModelNotice? = resolution.notice == .languageAutoDetectedByParakeet ? resolution.notice : nil
            return PreparedModel(settings: out, wasAutomatic: true, notice: notice)
        case .model(let id):
            out.selectedModelId = id
            guard let requested = ModelCatalog.descriptor(id: id),
                  let why = ModelResolver.incompatibility(of: requested, task: task, in: ctx) else {
                return PreparedModel(settings: out, wasAutomatic: false, notice: nil)
            }
            // No sirve para este idioma o ajuste: el siguiente compatible, con aviso.
            let auto = ModelResolver.resolve(task: task, assignment: .automatic, filesAssignment: filesAssignment, in: ctx)
            guard let used = auto.model ?? auto.needsDownload else {
                return PreparedModel(settings: out, wasAutomatic: false, notice: nil)
            }
            out.selectedModelId = used.id
            return PreparedModel(settings: out, wasAutomatic: false,
                                 notice: .incompatible(requested: id, used: used.id, reason: why))
        }
    }
}

/// Gestión de asignación de modelos por tarea y preferencias avanzadas de modelos.
///
/// «Archivos» no tiene clave propia: es el modelo de los ajustes por defecto (`DefaultsModel`),
/// el mismo que muestran Quick settings e Inicio. Así hay una sola fuente de verdad.
@MainActor
final class TaskModelPreferences: ObservableObject {
    static let shared = TaskModelPreferences()

    private let defaults = UserDefaults.standard

    // Claves de UserDefaults
    static let keyRecording = "task.model.recording"
    static let keyLiveCaptions = "task.model.liveCaptions"
    static let keyDictation = "dictation.model"
    static let keyShowTechnical = "showTechnicalModelNames"
    static let keyShowExperimental = "showExperimentalModels"
    static let keyRenameNoticePending = "models.renameNotice.pending"
    /// Clave del dictado en versiones anteriores para «usar el modelo de archivos».
    static let legacyDictationDefault = "useDefault"

    @Published var filesAssignment: ModelAssignment {
        didSet {
            guard !isPulling, DefaultsModel.shared.settings.selectedModelId != filesAssignment.storage else { return }
            DefaultsModel.shared.settings.selectedModelId = filesAssignment.storage
        }
    }
    @Published var recordingAssignment: ModelAssignment {
        didSet { defaults.set(recordingAssignment.storage, forKey: Self.keyRecording) }
    }
    @Published var liveCaptionsAssignment: ModelAssignment {
        didSet { defaults.set(liveCaptionsAssignment.storage, forKey: Self.keyLiveCaptions) }
    }
    @Published var dictationAssignment: ModelAssignment {
        didSet { defaults.set(dictationAssignment.storage, forKey: Self.keyDictation) }
    }
    @Published var showTechnicalNames: Bool {
        didSet { defaults.set(showTechnicalNames, forKey: Self.keyShowTechnical) }
    }
    @Published var showExperimental: Bool {
        didSet { defaults.set(showExperimental, forKey: Self.keyShowExperimental) }
    }
    @Published var nemotronChunkMs: Int {
        didSet { defaults.set(nemotronChunkMs, forKey: ModelEngineSettings.keyNemotronChunk); ModelStorageService.shared.notifyChanged() }
    }
    @Published var fastModelId: String {
        didSet { defaults.set(fastModelId, forKey: ModelEngineSettings.keyFastVersion) }
    }
    @Published private(set) var renameNoticePending: Bool

    private var isPulling = false
    private var observer: NSObjectProtocol?

    private init() {
        filesAssignment = ModelAssignment(storage: DefaultsModel.shared.settings.selectedModelId)
        recordingAssignment = ModelAssignment(storage: defaults.string(forKey: Self.keyRecording))
        liveCaptionsAssignment = ModelAssignment(storage: defaults.string(forKey: Self.keyLiveCaptions))
        dictationAssignment = ModelAssignment(storage: Self.dictationStorage(defaults.string(forKey: Self.keyDictation)))
        showTechnicalNames = defaults.bool(forKey: Self.keyShowTechnical)
        showExperimental = defaults.bool(forKey: Self.keyShowExperimental)
        nemotronChunkMs = ModelEngineSettings.nemotronChunkMs(for: NemotronStreamingEngine.multilingualId)
        fastModelId = ModelEngineSettings.fastModelId
        renameNoticePending = defaults.bool(forKey: Self.keyRenameNoticePending)
        observer = NotificationCenter.default.addObserver(forName: .defaultSettingsChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.pullFilesAssignment() }
        }
    }

    /// «useDefault» de versiones anteriores pasa a Automático.
    nonisolated static func dictationStorage(_ raw: String?) -> String? {
        guard let raw, raw != legacyDictationDefault else { return nil }
        return raw
    }

    private func pullFilesAssignment() {
        let saved = ModelAssignment(storage: DefaultsModel.shared.settings.selectedModelId)
        guard saved != filesAssignment else { return }
        isPulling = true
        filesAssignment = saved
        isPulling = false
    }

    func assignment(for task: ModelTask) -> ModelAssignment {
        switch task {
        case .files: return filesAssignment
        case .recording: return recordingAssignment
        case .liveCaptions: return liveCaptionsAssignment
        case .dictation: return dictationAssignment
        }
    }

    func setAssignment(_ assignment: ModelAssignment, for task: ModelTask) {
        switch task {
        case .files: filesAssignment = assignment
        case .recording: recordingAssignment = assignment
        case .liveCaptions: liveCaptionsAssignment = assignment
        case .dictation: dictationAssignment = assignment
        }
    }

    /// Resuelve el modelo efectivo de una tarea con el idioma por defecto (o el indicado).
    func resolve(task: ModelTask, currentLanguage: String? = nil, translate: Bool? = nil) -> ModelResolution {
        let s = DefaultsModel.shared.settings
        var language = currentLanguage ?? s.language
        if task == .dictation, currentLanguage == nil {
            language = DictationPreferences.transcriptionSettings().language
        }
        let ctx = ModelSelection.context(language: language, translate: translate ?? (task == .files ? s.translate : false))
        return ModelResolver.resolve(task: task, assignment: assignment(for: task),
                                     filesAssignment: filesAssignment, in: ctx)
    }

    // MARK: - Aviso único de nombres nuevos

    /// «Los modelos tienen nombres nuevos. Tu selección no ha cambiado: Ligero (antes Rápido).»
    /// Solo para quien actualiza desde una versión con los nombres anteriores, una vez.
    var renameNoticeText: String? {
        guard renameNoticePending else { return nil }
        let id: String
        switch filesAssignment {
        case .model(let m): id = m
        case .automatic:
            guard case .model(let d) = dictationAssignment else {
                return TXL.t("models.renameNotice.auto", "Los modelos tienen nombres nuevos. Tu selección no ha cambiado: Automático.")
            }
            id = d
        }
        guard let descriptor = ModelCatalog.descriptor(id: id) else { return nil }
        let newName = descriptor.displayName
        if let oldName = ModelCatalog.legacyDisplayNames[id], oldName != newName {
            return TXL.f("models.renameNotice.diff", "Los modelos tienen nombres nuevos. Tu selección no ha cambiado: %@ (antes %@).", newName, oldName)
        }
        return TXL.f("models.renameNotice.same", "Los modelos tienen nombres nuevos. Tu selección no ha cambiado: %@.", newName)
    }

    func dismissRenameNotice() {
        renameNoticePending = false
        defaults.set(false, forKey: Self.keyRenameNoticePending)
    }

    // MARK: - Migración de nombres guardados como texto

    /// Se ejecuta una vez al arrancar, antes de leer cualquier preferencia de modelos.
    /// Pasa a ID técnico cualquier nombre visible guardado (con el significado que tenía entonces)
    /// y deja pendiente el aviso único si el usuario viene de una versión anterior.
    nonisolated static func migrateStoredModelNames(_ d: UserDefaults = .standard) {
        let done = "migration.modelNames.v1"
        guard !d.bool(forKey: done) else { return }
        d.set(true, forKey: done)

        let isUpgrade = d.data(forKey: "transcription_settings") != nil || d.string(forKey: keyDictation) != nil
        if let data = d.data(forKey: "transcription_settings"),
           var saved = try? JSONDecoder().decode(TranscriptionSettings.self, from: data),
           let id = ModelCatalog.migratedId(fromStored: saved.selectedModelId), id != saved.selectedModelId {
            saved.selectedModelId = id
            if let encoded = try? JSONEncoder().encode(saved) { d.set(encoded, forKey: "transcription_settings") }
        }
        for key in [keyDictation, keyRecording, keyLiveCaptions] {
            guard let raw = d.string(forKey: key), raw != legacyDictationDefault, raw != ModelSelection.autoToken else { continue }
            if let id = ModelCatalog.migratedId(fromStored: raw), id != raw { d.set(id, forKey: key) }
        }
        if isUpgrade { d.set(true, forKey: keyRenameNoticePending) }
    }
}
