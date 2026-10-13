import Foundation
import SwiftUI

/// Gestión de asignación de modelos por tarea y preferencias avanzadas de modelos.
@MainActor
final class TaskModelPreferences: ObservableObject {
    static let shared = TaskModelPreferences()

    private let defaults = UserDefaults.standard

    // Claves de UserDefaults
    static let keyFiles = "task.model.files"
    static let keyRecording = "task.model.recording"
    static let keyLiveCaptions = "task.model.liveCaptions"
    static let keyDictation = "dictation.model"
    static let keyShowTechnical = "showTechnicalModelNames"
    static let keyShowExperimental = "showExperimentalModels"
    static let keySeenRenameNotice = "hasSeenModelNamesNotice_v2"

    @Published var filesAssignment: ModelAssignment {
        didSet { defaults.set(filesAssignment.storage, forKey: Self.keyFiles) }
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
    @Published var hasSeenRenameNotice: Bool {
        didSet { defaults.set(hasSeenRenameNotice, forKey: Self.keySeenRenameNotice) }
    }

    private init() {
        // Carga inicial
        let fRaw = defaults.string(forKey: Self.keyFiles) ?? "auto"
        let rRaw = defaults.string(forKey: Self.keyRecording) ?? "auto"
        let lRaw = defaults.string(forKey: Self.keyLiveCaptions) ?? "auto"
        let dRaw = defaults.string(forKey: Self.keyDictation) ?? "auto"

        self.filesAssignment = ModelAssignment(storage: fRaw)
        self.recordingAssignment = ModelAssignment(storage: rRaw)
        self.liveCaptionsAssignment = ModelAssignment(storage: lRaw)
        // Migración de "useDefault" heredado de dictado -> .automatic
        self.dictationAssignment = (dRaw == "useDefault" || dRaw == "auto" || dRaw.isEmpty) ? .automatic : ModelAssignment(storage: dRaw)

        self.showTechnicalNames = defaults.bool(forKey: Self.keyShowTechnical)
        self.showExperimental = defaults.bool(forKey: Self.keyShowExperimental)
        self.hasSeenRenameNotice = defaults.bool(forKey: Self.keySeenRenameNotice)
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
        case .files:
            filesAssignment = assignment
            // Sincroniza con TranscriptionSettings.selectedModelId para compatibilidad
            if case .model(let id) = assignment {
                NotificationCenter.default.post(name: .filesModelChanged, object: id)
            }
        case .recording:
            recordingAssignment = assignment
        case .liveCaptions:
            liveCaptionsAssignment = assignment
        case .dictation:
            dictationAssignment = assignment
        }
    }

    /// Resuelve el modelo efectivo en el contexto actual del sistema.
    func resolve(task: ModelTask, currentLanguage: String? = nil, translate: Bool = false) -> ModelResolution {
        let installed = ModelStorageService.shared.installedModelIds()
        let osMajor = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        let ctx = ModelResolverContext(
            installed: installed,
            osMajor: osMajor,
            showExperimental: showExperimental,
            language: currentLanguage,
            translateToEnglish: translate
        )
        return ModelResolver.resolve(
            task: task,
            assignment: assignment(for: task),
            filesAssignment: filesAssignment,
            in: ctx
        )
    }

    /// Texto del aviso único sobre el cambio de nombres (6.5 / instrucción del usuario).
    /// «Los modelos tienen nombres nuevos. Tu selección no ha cambiado: Ligero (antes Rápido).»
    var renameNoticeText: String? {
        guard !hasSeenRenameNotice else { return nil }
        let currentId = defaults.string(forKey: "selectedModelId") ?? "base"
        guard let descriptor = ModelCatalog.descriptor(id: currentId) else { return nil }
        let newName = descriptor.displayName
        if let oldName = ModelCatalog.legacyDisplayNames[currentId], oldName != newName {
            return TXL.f("models.renameNotice.diff", "Los modelos tienen nombres nuevos. Tu selección no ha cambiado: %@ (antes %@).", newName, oldName)
        } else {
            return TXL.f("models.renameNotice.same", "Los modelos tienen nombres nuevos. Tu selección no ha cambiado: %@.", newName)
        }
    }

    func dismissRenameNotice() {
        hasSeenRenameNotice = true
    }
}

extension Notification.Name {
    static let filesModelChanged = Notification.Name("tx.filesModelChanged")
}
