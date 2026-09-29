import Foundation

// MARK: - Transcription Task
struct TranscriptionTask: Identifiable, Codable {
    let id: String
    var status: TaskStatus
    var progress: Int
    var message: String
    var text: String?
    var logs: [LogEntry]
    var steps: [StepProgress]
    
    enum TaskStatus: String, Codable {
        case pending, processing, completed, error, cancelled
    }
    
    struct LogEntry: Codable, Identifiable {
        var id: String { "\(timestamp)-\(message.prefix(10))" }
        let timestamp: String
        let type: String
        let message: String
    }
    
    struct StepProgress: Codable, Identifiable {
        var id: String { step }
        let step: String
        let progress: Int
        let label: String
    }
}

// MARK: - Transcription Segment (for interactive viewer)
struct TranscriptionSegment: Identifiable, Codable {
    let id: UUID
    let startTime: TimeInterval  // segundos
    let endTime: TimeInterval
    var text: String
    let speaker: Int?            // nil si no hay diarización, 0,1,2... si hay
    var isFavorite: Bool
    var isDeleted: Bool
    var originalText: String?    // non-nil after first text edit (stores original)
    var editHistory: [String]    // previous versions (oldest -> newest)
    
    init(id: UUID = UUID(), startTime: TimeInterval, endTime: TimeInterval, text: String, speaker: Int? = nil, isFavorite: Bool = false, isDeleted: Bool = false, originalText: String? = nil, editHistory: [String] = []) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
        self.speaker = speaker
        self.isFavorite = isFavorite
        self.isDeleted = isDeleted
        self.originalText = originalText
        self.editHistory = editHistory
    }
    
    // Backward-compatible decoding: old JSON won't have new fields
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        startTime = try container.decode(TimeInterval.self, forKey: .startTime)
        endTime = try container.decode(TimeInterval.self, forKey: .endTime)
        text = try container.decode(String.self, forKey: .text)
        speaker = try container.decodeIfPresent(Int.self, forKey: .speaker)
        isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        isDeleted = try container.decodeIfPresent(Bool.self, forKey: .isDeleted) ?? false
        originalText = try container.decodeIfPresent(String.self, forKey: .originalText)
        editHistory = try container.decodeIfPresent([String].self, forKey: .editHistory) ?? []
    }
    
    /// Create a copy with updated text, preserving original and history.
    func withText(_ newText: String) -> TranscriptionSegment {
        var copy = TranscriptionSegment(
            id: self.id,
            startTime: self.startTime,
            endTime: self.endTime,
            text: self.text,
            speaker: self.speaker,
            isFavorite: self.isFavorite,
            isDeleted: self.isDeleted,
            originalText: self.originalText,
            editHistory: self.editHistory
        )
        guard newText != self.text else { return copy }
        if copy.originalText == nil {
            copy.originalText = self.text
        }
        if copy.editHistory.last != self.text {
            copy.editHistory.append(self.text)
        }
        copy.text = newText
        return copy
    }
    
    var formattedTimeRange: String {
        let start = formatTime(startTime)
        let end = formatTime(endTime)
        return "\(start) → \(end)"
    }
    
    var formattedStartTime: String {
        formatTime(startTime)
    }
    
    private func formatTime(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%02d:%02d", mins, secs)
    }
}

// MARK: - Transcription Result
struct TranscriptionResult {
    var segments: [TranscriptionSegment]
    var plainText: String
    var showTimestamps: Bool
    
    init(segments: [TranscriptionSegment] = [], showTimestamps: Bool = true) {
        self.segments = segments
        self.plainText = segments.map { $0.text }.joined(separator: " ")
        self.showTimestamps = showTimestamps
    }
    
    init(plainText: String) {
        self.segments = []
        self.plainText = plainText
        self.showTimestamps = false
    }
    
    /// Generate SRT subtitle format
    func toSRT() -> String {
        var srt = ""
        let activeSegments = segments.filter { !$0.isDeleted }
        for (index, segment) in activeSegments.enumerated() {
            srt += "\(index + 1)\n"
            srt += "\(formatSRTTime(segment.startTime)) --> \(formatSRTTime(segment.endTime))\n"
            
            // Add speaker prefix if diarization is enabled
            if let speaker = segment.speaker {
                srt += "[Hablante \(speaker + 1)] "
            }
            srt += "\(segment.text)\n\n"
        }
        return srt
    }
    
    /// Generate VTT subtitle format
    func toVTT() -> String {
        var vtt = "WEBVTT\n\n"
        let activeSegments = segments.filter { !$0.isDeleted }
        for segment in activeSegments {
            vtt += "\(formatVTTTime(segment.startTime)) --> \(formatVTTTime(segment.endTime))\n"
            
            if let speaker = segment.speaker {
                vtt += "<v Hablante \(speaker + 1)>"
            }
            vtt += "\(segment.text)\n\n"
        }
        return vtt
    }
    
    /// Generate Markdown format with timestamps and speaker labels
    func toMarkdown() -> String {
        var md = "# Transcripción\n\n"
        
        // If we don't have segments (e.g., URL transcript / legacy imports), fall back to plain text.
        if segments.isEmpty {
            md += plainText.trimmingCharacters(in: .whitespacesAndNewlines)
            md += "\n"
            return md
        }
        
        let activeSegments = segments.filter { !$0.isDeleted }
        let hasSpeakers = activeSegments.contains { $0.speaker != nil }
        
        if hasSpeakers {
            var currentSpeaker: Int? = nil
            
            for segment in activeSegments {
                if segment.speaker != currentSpeaker {
                    currentSpeaker = segment.speaker
                    md += "\n## Hablante \((currentSpeaker ?? 0) + 1)\n\n"
                }
                
                if showTimestamps {
                    md += "**[\(segment.formattedStartTime)]** "
                }
                md += segment.text + "\n\n"
            }
        } else {
            // Simple format with timestamps
            for segment in activeSegments {
                if showTimestamps {
                    md += "**[\(segment.formattedStartTime)]** "
                }
                md += segment.text + "\n\n"
            }
        }
        
        return md
    }
    
    private func formatSRTTime(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds) / 3600
        let mins = (Int(seconds) % 3600) / 60
        let secs = Int(seconds) % 60
        let ms = Int((seconds.truncatingRemainder(dividingBy: 1)) * 1000)
        return String(format: "%02d:%02d:%02d,%03d", hours, mins, secs, ms)
    }
    
    private func formatVTTTime(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds) / 3600
        let mins = (Int(seconds) % 3600) / 60
        let secs = Int(seconds) % 60
        let ms = Int((seconds.truncatingRemainder(dividingBy: 1)) * 1000)
        return String(format: "%02d:%02d:%02d.%03d", hours, mins, secs, ms)
    }
}

// MARK: - Audio File
struct AudioFile: Identifiable {
    let id = UUID()
    let url: URL
    let name: String
    let size: Int64
    var duration: TimeInterval?
    
    var formattedSize: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }
    
    var formattedDuration: String {
        guard let duration = duration else { return "--:--" }
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

// MARK: - Model Info
struct ModelInfo: Identifiable, Hashable {
    let id: String
    let name: String           // Nombre amigable
    let technicalName: String  // Nombre técnico (para info)
    let size: String
    let speed: String
    let quality: Int // 1-5
    let recommended: Bool
    let description: String    // Descripción detallada
    
    var qualityStars: String {
        String(repeating: "●", count: quality) + String(repeating: "○", count: 5 - quality)
    }

    func localizedName(_ appLanguage: AppLanguage) -> String {
        guard appLanguage == .en else { return name }
        switch id {
        case "tiny": return "Ultra Fast"
        case "base": return "Fast"
        case "small": return "Balanced"
        case "medium": return "Precise"
        case "large-v3-turbo": return "Professional"
        case "large-v3": return "Maximum Quality"
        default: return name
        }
    }

    func localizedSpeed(_ appLanguage: AppLanguage) -> String {
        guard appLanguage == .en else { return speed }
        switch speed {
        case "Instantáneo": return "Instant"
        case "Muy rápido": return "Very fast"
        case "Normal": return "Normal"
        case "Lento": return "Slow"
        case "Muy lento": return "Very slow"
        default: return speed
        }
    }

    func localizedDescription(_ appLanguage: AppLanguage) -> String {
        guard appLanguage == .en else { return description }
        switch id {
        case "tiny":
            return "Fastest option. Ideal for quick tests or very clear audio. It may miss complex words."
        case "base":
            return "Good balance between speed and quality. Recommended to start. Works well with clear audio."
        case "small":
            return "Better accuracy for most cases. Good for interviews and podcasts with good audio quality."
        case "medium":
            return "High accuracy. Ideal for important transcriptions where precision is a priority."
        case "large-v3-turbo":
            return "Best available quality with optimized speed. For professional transcriptions and difficult audio."
        case "large-v2":
            return "Previous high-quality version. Useful if V3 does not give the expected results."
        case "large-v3":
            return "Maximum possible precision. For noisy audio, complex accents, or technical vocabulary."
        default:
            return description
        }
    }
    
    // Modelos con nombres amigables
    static let allModels: [ModelInfo] = [
        ModelInfo(
            id: "tiny",
            name: "Ultra Rápido",
            technicalName: "Whisper Tiny",
            size: "75 MB",
            speed: "Instantáneo",
            quality: 1,
            recommended: false,
            description: "El más rápido. Ideal para pruebas rápidas o audios muy claros. Puede tener errores en palabras complejas."
        ),
        ModelInfo(
            id: "base",
            name: "Rápido",
            technicalName: "Whisper Base", 
            size: "142 MB",
            speed: "Muy rápido",
            quality: 2,
            recommended: true,
            description: "Buen equilibrio entre velocidad y calidad. Recomendado para empezar. Funciona bien con audios claros."
        ),
        ModelInfo(
            id: "small",
            name: "Equilibrado",
            technicalName: "Whisper Small",
            size: "466 MB",
            speed: "Normal",
            quality: 3,
            recommended: false,
            description: "Mejor precisión para la mayoría de casos. Bueno para entrevistas y podcasts con buena calidad de audio."
        ),
        ModelInfo(
            id: "medium",
            name: "Preciso",
            technicalName: "Whisper Medium",
            size: "1.5 GB",
            speed: "Lento",
            quality: 4,
            recommended: false,
            description: "Alta precisión. Ideal para transcripciones importantes donde la exactitud es prioritaria."
        ),
        ModelInfo(
            id: "large-v3-turbo",
            name: "Profesional",
            technicalName: "Whisper Large V3 Turbo",
            size: "1.6 GB",
            speed: "Normal",
            quality: 5,
            recommended: false,
            description: "La mejor calidad disponible con velocidad optimizada. Para transcripciones profesionales y audios difíciles."
        ),
        ModelInfo(
            id: "large-v2",
            name: "Large V2",
            technicalName: "Whisper Large V2",
            size: "2.9 GB",
            speed: "Muy lento",
            quality: 5,
            recommended: false,
            description: "Anterior versión de mayor calidad. Útil si V3 no da los resultados esperados."
        ),
        ModelInfo(
            id: "large-v3",
            name: "Máxima Calidad",
            technicalName: "Whisper Large V3",
            size: "2.9 GB",
            speed: "Muy lento",
            quality: 5,
            recommended: false,
            description: "Máxima precisión posible. Para audios con ruido, acentos complejos o vocabulario técnico. Requiere más tiempo."
        )
    ]
}

// MARK: - Settings
struct TranscriptionSettings: Codable, Equatable {
    var language: String = "es"
    var selectedModelId: String = "base"
    
    // Preprocessing options
    var deepfilter: Bool = false       // DeepFilterNet noise reduction
    var isolateVoice: Bool = false     // Demucs voice separation
    var normalize: Bool = false        // EBU R128 normalization
    
    // VAD options
    var useVAD: Bool = false                   // Enable Voice Activity Detection
    var vadThreshold: Double = 0.6             // VAD threshold (0.5-0.8 recommended)
    var vadMinSilenceDuration: Int = 700       // Min silence to split (ms)
    var vadMinSpeechDuration: Int = 250        // Min speech duration (ms)
    var vadSpeechPad: Int = 30                 // Padding around speech (ms)
    
    // Whisper decoding options
    var temperature: Double = 0.0              // 0 = deterministic, higher = creative
    var noSpeechThreshold: Double = 0.6        // Threshold for detecting no speech
    var entropyThreshold: Double = 2.4         // Entropy threshold for decoder fail
    var beamSize: Int = 5                      // Beam search size
    var bestOf: Int = 5                        // Best candidates to keep
    var suppressNonSpeech: Bool = true         // Suppress non-speech tokens
    
    // Diarization (speaker detection)
    var enableDiarization: Bool = false        // Enable tinydiarize for speaker turns
    
    // CoreML Neural Engine acceleration
    var useCoreML: Bool = false                 // Use Neural Engine when available
    
    // Output options
    var timestamps: Bool = true                // Generate timestamps (needed for interactive viewer)
    var translate: Bool = false
    var keepAudioFileInHistory: Bool = true    // Persist audio in app history for later playback
    
    // Context prompt for better accuracy
    var initialPrompt: String = ""             // Initial context prompt
    
    static let `default` = TranscriptionSettings()
    
    // Presets for different scenarios
    static let lecture = TranscriptionSettings(
        language: "en",
        selectedModelId: "large-v3",
        useVAD: true,
        vadThreshold: 0.6,
        vadMinSilenceDuration: 700,
        temperature: 0.0,
        suppressNonSpeech: true,
        enableDiarization: true,
        initialPrompt: "Academic lecture. Technical vocabulary."
    )
    
    static let podcast = TranscriptionSettings(
        language: "es",
        selectedModelId: "medium",
        useVAD: true,
        vadThreshold: 0.5,
        vadMinSilenceDuration: 500,
        temperature: 0.0,
        suppressNonSpeech: true,
        enableDiarization: true
    )
    
    static let interview = TranscriptionSettings(
        language: "es",
        selectedModelId: "large-v3-turbo",
        useVAD: true,
        vadThreshold: 0.5,
        temperature: 0.0,
        enableDiarization: true,
        timestamps: true
    )
}

// MARK: - Export Format
enum ExportFormat: String, CaseIterable {
    case txt  = "txt"
    case srt  = "srt"
    case vtt  = "vtt"
    case md   = "md"
    case csv  = "csv"
    case html = "html"
    case pdf  = "pdf"
    case docx = "docx"
    
    var description: String {
        switch self {
        case .txt:  return "Texto plano (.txt)"
        case .srt:  return "Subtítulos SRT (.srt)"
        case .vtt:  return "Subtítulos VTT (.vtt)"
        case .md:   return "Markdown (.md)"
        case .csv:  return "CSV (.csv)"
        case .html: return "HTML (.html)"
        case .pdf:  return "PDF (.pdf)"
        case .docx: return "Word (.docx)"
        }
    }
    
    func localizedDescription(_ lang: AppLanguage) -> String {
        switch self {
        case .txt:  return lang == .es ? "Texto plano (.txt)"    : "Plain Text (.txt)"
        case .srt:  return lang == .es ? "Subtítulos SRT (.srt)" : "SRT Subtitles (.srt)"
        case .vtt:  return lang == .es ? "Subtítulos VTT (.vtt)" : "VTT Subtitles (.vtt)"
        case .md:   return lang == .es ? "Markdown (.md)"        : "Markdown (.md)"
        case .csv:  return lang == .es ? "Hoja de cálculo (.csv)": "Spreadsheet (.csv)"
        case .html: return lang == .es ? "Página web (.html)"    : "Web Page (.html)"
        case .pdf:  return lang == .es ? "Documento PDF (.pdf)"  : "PDF Document (.pdf)"
        case .docx: return lang == .es ? "Documento Word (.docx)": "Word Document (.docx)"
        }
    }
    
    var icon: String {
        switch self {
        case .txt:  return "doc.text"
        case .srt:  return "captions.bubble"
        case .vtt:  return "captions.bubble.fill"
        case .md:   return "doc.richtext"
        case .csv:  return "tablecells"
        case .html: return "globe"
        case .pdf:  return "doc.text.fill"
        case .docx: return "doc.fill"
        }
    }
    
    /// Formats that require timed segments to produce meaningful output
    var requiresSegments: Bool {
        switch self {
        case .srt, .vtt: return true
        default: return false
        }
    }
}

// MARK: - Transcription (Saved Item)
struct Transcription: Identifiable, Codable {
    let id: UUID
    var title: String
    var text: String
    var language: String
    var duration: TimeInterval
    var createdAt: Date
    var isFavorite: Bool
    var sourceURL: URL?
    var segments: [TranscriptionSegment]?
    
    init(
        id: UUID = UUID(),
        title: String,
        text: String,
        language: String = "es",
        duration: TimeInterval = 0,
        createdAt: Date = Date(),
        isFavorite: Bool = false,
        sourceURL: URL? = nil,
        segments: [TranscriptionSegment]? = nil
    ) {
        self.id = id
        self.title = title
        self.text = text
        self.language = language
        self.duration = duration
        self.createdAt = createdAt
        self.isFavorite = isFavorite
        self.sourceURL = sourceURL
        self.segments = segments
    }
    
    var formattedDuration: String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
    
    var formattedDate: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: createdAt, relativeTo: Date())
    }
    
    var languageDisplayName: String {
        LocalizationHelpers.languageDisplayName(language)
    }
}
