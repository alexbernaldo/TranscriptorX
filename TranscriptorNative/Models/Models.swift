import Foundation

// MARK: - Transcription Segment (for interactive viewer)
struct TranscriptionSegment: Identifiable, Codable {
    let id: UUID
    var startTime: TimeInterval  // segundos
    var endTime: TimeInterval
    var text: String
    var speaker: Int?            // nil si no hay diarización, 0,1,2... si hay (var: merge #8)
    var isFavorite: Bool
    var isDeleted: Bool
    var originalText: String?    // non-nil after first text edit (stores original)
    var editHistory: [String]    // previous versions (oldest -> newest)
    var words: [WordTimestamp]?  // nil = sin datos (JSON antiguo o flag no usado)
    
    struct WordTimestamp: Codable, Equatable {
        let start: TimeInterval   // segundos
        let end: TimeInterval
        let text: String          // incluye el espacio inicial si lo traía el token
    }
    
    init(id: UUID = UUID(), startTime: TimeInterval, endTime: TimeInterval, text: String, speaker: Int? = nil, isFavorite: Bool = false, isDeleted: Bool = false, originalText: String? = nil, editHistory: [String] = [], words: [WordTimestamp]? = nil) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
        self.speaker = speaker
        self.isFavorite = isFavorite
        self.isDeleted = isDeleted
        self.originalText = originalText
        self.editHistory = editHistory
        self.words = words
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
        words = try container.decodeIfPresent([WordTimestamp].self, forKey: .words)
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
            editHistory: self.editHistory,
            words: self.words
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
    /// Speakers were requested but could not be identified (the text is still saved).
    var speakerDetectionError: String?
    
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
    func toSRT(speakerNames: [String: String]? = nil) -> String {
        var srt = ""
        let activeSegments = segments.filter { !$0.isDeleted }
        for (index, segment) in activeSegments.enumerated() {
            srt += "\(index + 1)\n"
            srt += "\(formatSRTTime(segment.startTime)) --> \(formatSRTTime(segment.endTime))\n"
            
            // Add speaker prefix if diarization is enabled
            if let speaker = segment.speaker {
                let name = speakerNames?["\(speaker)"] ?? "Hablante \(speaker + 1)"
                srt += "[\(name)] "
            }
            srt += "\(segment.text)\n\n"
        }
        return srt
    }
    
    /// Generate VTT subtitle format
    func toVTT(speakerNames: [String: String]? = nil) -> String {
        var vtt = "WEBVTT\n\n"
        let activeSegments = segments.filter { !$0.isDeleted }
        for segment in activeSegments {
            vtt += "\(formatVTTTime(segment.startTime)) --> \(formatVTTTime(segment.endTime))\n"
            
            if let speaker = segment.speaker {
                let name = speakerNames?["\(speaker)"] ?? "Hablante \(speaker + 1)"
                vtt += "<v \(name)>"
            }
            vtt += "\(segment.text)\n\n"
        }
        return vtt
    }
    
    /// Generate Markdown format with timestamps and speaker labels
    func toMarkdown(speakerNames: [String: String]? = nil) -> String {
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
                    let idx = currentSpeaker ?? 0
                    let name = speakerNames?["\(idx)"] ?? "Hablante \(idx + 1)"
                    md += "\n## \(name)\n\n"
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
    
    // Vista derivada de ModelCatalog (única fuente de verdad)
    static var allModels: [ModelInfo] {
        ModelCatalog.all.map { d in
            ModelInfo(
                id: d.id,
                name: d.displayName,
                technicalName: d.id,
                size: ModelStorageService.shared.displaySize(for: d.id),
                speed: d.scales.speed >= 4 ? "Muy rápido" : (d.scales.speed >= 3 ? "Normal" : "Lento"),
                quality: d.scales.accuracy,
                recommended: d.group == .recommended,
                description: d.subtitle
            )
        }
    }
}

// MARK: - Settings
struct TranscriptionSettings: Codable, Equatable {
    var language: String = "auto"             // detect the language by default
    /// ID técnico, o «auto» (Automático: el resolver elige el modelo al crear el trabajo).
    var selectedModelId: String = "auto"
    
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
    
    // Export options
    var exportStyle: ExportStyle = .segments
    var exportGrouping: ExportGroupingPreference = .none
    var exportUseMilliseconds: Bool = false
    var exportFavoritesOnly: Bool = false
    var exportFPS: Int = 25                    // solo avid (25 / 30)
    
    // Meeting detection (#7)
    var autoDetectMeetings: Bool = true
    
    static let `default` = TranscriptionSettings()
    
    // Presets for different scenarios
    static let lecture = TranscriptionSettings(
        language: "auto",
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
        language: "auto",
        selectedModelId: "medium",
        useVAD: true,
        vadThreshold: 0.5,
        vadMinSilenceDuration: 500,
        temperature: 0.0,
        suppressNonSpeech: true,
        enableDiarization: true
    )
    
    static let interview = TranscriptionSettings(
        language: "auto",
        selectedModelId: "large-v3-turbo",
        useVAD: true,
        vadThreshold: 0.5,
        temperature: 0.0,
        enableDiarization: true,
        timestamps: true
    )
}

// MARK: - Export Format
enum ExportStyle: String, Codable, CaseIterable, Identifiable {
    case fullTranscript, segments, subtitles, whisper
    var id: String { rawValue }
}

enum ExportGroupingPreference: String, Codable, CaseIterable, Identifiable {
    case none, words, sentences, people
    var id: String { rawValue }
}

enum ExportFormat: String, CaseIterable {
    case txt  = "txt"
    case srt  = "srt"
    case vtt  = "vtt"
    case md   = "md"
    case csv  = "csv"
    case html = "html"
    case pdf  = "pdf"
    case docx = "docx"
    case json = "json"
    case avid = "avid"
    
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
        case .json: return "Datos JSON (.json)"
        case .avid: return "Avid CMX3600 (.avid)"
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
        case .json: return lang == .es ? "Datos JSON (.json)"    : "JSON Data (.json)"
        case .avid: return lang == .es ? "Avid CMX3600 (.avid)"  : "Avid CMX3600 (.avid)"
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
        case .json: return "curlybraces"
        case .avid: return "film"
        }
    }
    
    /// Formats that require timed segments to produce meaningful output
    var requiresSegments: Bool {
        switch self {
        case .srt, .vtt, .avid: return true
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
    var aiTitle: String?
    var aiSummary: String?
    var aiTags: [String]?
    /// Full-text translations keyed by language code (e.g. "en"). Local-only.
    var fullTextTranslations: [String: String]?
    /// Nombres de hablantes por índice (claves String "0","1",…). #8
    var speakerNames: [String: String]?
    /// ID técnico y motor con que se generó la transcripción. `nil` = registro anterior («Desconocido»).
    var modelId: String?
    var engine: String?
    var engineVersion: String?
    
    init(
        id: UUID = UUID(),
        title: String,
        text: String,
        language: String = "es",
        duration: TimeInterval = 0,
        createdAt: Date = Date(),
        isFavorite: Bool = false,
        sourceURL: URL? = nil,
        segments: [TranscriptionSegment]? = nil,
        aiTitle: String? = nil,
        aiSummary: String? = nil,
        aiTags: [String]? = nil,
        fullTextTranslations: [String: String]? = nil,
        speakerNames: [String: String]? = nil,
        modelId: String? = nil,
        engine: String? = nil,
        engineVersion: String? = nil
    ) {
        self.modelId = modelId
        self.engine = engine
        self.engineVersion = engineVersion
        self.id = id
        self.title = title
        self.text = text
        self.language = language
        self.duration = duration
        self.createdAt = createdAt
        self.isFavorite = isFavorite
        self.sourceURL = sourceURL
        self.segments = segments
        self.aiTitle = aiTitle
        self.aiSummary = aiSummary
        self.aiTags = aiTags
        self.fullTextTranslations = fullTextTranslations
        self.speakerNames = speakerNames
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
