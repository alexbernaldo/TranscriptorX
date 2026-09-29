import Foundation

private var isSpanishUI: Bool {
    UserDefaults.standard.string(forKey: "app_ui_language") == "es"
}

private func localizedState(_ spanish: String, _ english: String) -> String {
    isSpanishUI ? spanish : english
}

/// Explicit state machine for recording operations
/// Provides granular states for immediate UI feedback
enum RecordingState: Equatable {
    // Idle states
    case idle
    case requestingPermission
    
    // Initialization states (these justify "wait" to user)
    case preparingAudio          // "Preparando micrófono..."
    case initializingCapture     // "Iniciando captura..."
    
    // Active recording states
    case recording(duration: TimeInterval)
    case paused(duration: TimeInterval)
    
    // Finalization states
    case stopping                // "Finalizando grabación..."
    case saving                  // "Guardando archivo..."
    
    // Terminal states
    case completed(url: URL, duration: TimeInterval)
    case failed(error: RecordingError)
    case cancelled
    
    // MARK: - State Properties
    
    var isIdle: Bool {
        switch self {
        case .idle, .cancelled: return true
        default: return false
        }
    }
    
    var isActive: Bool {
        switch self {
        case .recording, .paused: return true
        default: return false
        }
    }
    
    var isTransitioning: Bool {
        switch self {
        case .requestingPermission, .preparingAudio, .initializingCapture, .stopping, .saving:
            return true
        default:
            return false
        }
    }
    
    var canStart: Bool {
        switch self {
        case .idle, .cancelled, .completed, .failed: return true
        default: return false
        }
    }
    
    var canStop: Bool {
        switch self {
        case .recording, .paused: return true
        default: return false
        }
    }
    
    var canPause: Bool {
        if case .recording = self { return true }
        return false
    }
    
    var canResume: Bool {
        if case .paused = self { return true }
        return false
    }
    
    // MARK: - UI Display
    
    var displayText: String {
        switch self {
        case .idle:
            return localizedState("Listo para grabar", "Ready to record")
        case .requestingPermission:
            return localizedState("Solicitando permisos...", "Requesting permissions...")
        case .preparingAudio:
            return localizedState("Preparando audio...", "Preparing audio...")
        case .initializingCapture:
            return localizedState("Iniciando captura...", "Initializing capture...")
        case .recording(let duration):
            return formatDuration(duration)
        case .paused(let duration):
            return localizedState("Pausado · \(formatDuration(duration))", "Paused · \(formatDuration(duration))")
        case .stopping:
            return localizedState("Finalizando...", "Stopping...")
        case .saving:
            return localizedState("Guardando...", "Saving...")
        case .completed(_, let duration):
            return localizedState(
                "Grabación lista · \(formatDuration(duration))",
                "Recording ready · \(formatDuration(duration))"
            )
        case .failed(let error):
            return error.userMessage
        case .cancelled:
            return localizedState("Cancelado", "Cancelled")
        }
    }
    
    var statusIcon: String {
        switch self {
        case .idle, .cancelled:
            return "mic.fill"
        case .requestingPermission, .preparingAudio, .initializingCapture:
            return "hourglass"
        case .recording:
            return "record.circle"
        case .paused:
            return "pause.circle"
        case .stopping, .saving:
            return "hourglass"
        case .completed:
            return "checkmark.circle.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        }
    }
    
    var showsSpinner: Bool {
        switch self {
        case .requestingPermission, .preparingAudio, .initializingCapture, .stopping, .saving:
            return true
        default:
            return false
        }
    }
    
    var accentColor: String {
        switch self {
        case .idle, .cancelled:
            return "secondary"
        case .requestingPermission, .preparingAudio, .initializingCapture:
            return "orange"
        case .recording:
            return "red"
        case .paused:
            return "yellow"
        case .stopping, .saving:
            return "blue"
        case .completed:
            return "green"
        case .failed:
            return "red"
        }
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

// MARK: - Recording Error

enum RecordingError: LocalizedError, Equatable {
    case permissionDenied
    case noMicrophoneAvailable
    case noDisplayAvailable
    case audioEngineFailure(String)
    case fileCreationFailed
    case encodingFailed
    case writerError(String)
    case unknown(String)
    
    var errorDescription: String? {
        userMessage
    }
    
    var userMessage: String {
        switch self {
        case .permissionDenied:
            return localizedState(
                "Permiso denegado. Actívalo en Preferencias del Sistema.",
                "Permission denied. Enable it in System Settings."
            )
        case .noMicrophoneAvailable:
            return localizedState("No se detectó ningún micrófono.", "No microphone was detected.")
        case .noDisplayAvailable:
            return localizedState("No se pudo acceder a la pantalla.", "Could not access the display.")
        case .audioEngineFailure(let detail):
            return localizedState("Error de audio: \(detail)", "Audio error: \(detail)")
        case .fileCreationFailed:
            return localizedState("No se pudo crear el archivo de audio.", "Could not create the audio file.")
        case .encodingFailed:
            return localizedState("Error al codificar el audio.", "Audio encoding failed.")
        case .writerError(let detail):
            return localizedState("Error de escritura: \(detail)", "Writer error: \(detail)")
        case .unknown(let detail):
            return localizedState("Error desconocido: \(detail)", "Unknown error: \(detail)")
        }
    }
    
    static func == (lhs: RecordingError, rhs: RecordingError) -> Bool {
        lhs.userMessage == rhs.userMessage
    }
}

// MARK: - Transcription State

enum TranscriptionState: Equatable {
    case idle
    case checkingModel
    case downloadingModel(progress: Double)
    case loadingModel(progress: Double)
    case preprocessing         // "Optimizando audio..."
    case transcribing(progress: Double)  // Actual transcription
    case postprocessing        // "Formateando texto..."
    case completed
    case failed(String)
    case cancelled
    
    var isActive: Bool {
        switch self {
        case .idle, .completed, .failed, .cancelled: return false
        default: return true
        }
    }
    
    var displayText: String {
        switch self {
        case .idle:
            return ""
        case .checkingModel:
            return localizedState("Verificando modelo...", "Checking model...")
        case .downloadingModel(let progress):
            return localizedState(
                "Descargando modelo \(Int(progress * 100))%",
                "Downloading model \(Int(progress * 100))%"
            )
        case .loadingModel(let progress):
            return localizedState(
                "Cargando IA \(Int(progress * 100))%",
                "Loading AI \(Int(progress * 100))%"
            )
        case .preprocessing:
            return localizedState("Optimizando audio...", "Optimizing audio...")
        case .transcribing(let progress):
            return localizedState("Transcribiendo \(Int(progress * 100))%", "Transcribing \(Int(progress * 100))%")
        case .postprocessing:
            return localizedState("Formateando texto...", "Formatting text...")
        case .completed:
            return localizedState("Completado", "Completed")
        case .failed(let error):
            return localizedState("Error: \(error)", "Error: \(error)")
        case .cancelled:
            return localizedState("Cancelado", "Cancelled")
        }
    }
    
    var progress: Double? {
        switch self {
        case .downloadingModel(let p), .loadingModel(let p), .transcribing(let p):
            return p
        case .checkingModel, .preprocessing:
            return nil // Indeterminate
        case .postprocessing:
            return 0.95 // Almost done
        default:
            return nil
        }
    }
    
    var showsProgress: Bool {
        switch self {
        case .downloadingModel, .loadingModel, .transcribing:
            return true
        default:
            return false
        }
    }
    
    var showsSpinner: Bool {
        switch self {
        case .checkingModel, .preprocessing, .postprocessing:
            return true
        default:
            return false
        }
    }
}
