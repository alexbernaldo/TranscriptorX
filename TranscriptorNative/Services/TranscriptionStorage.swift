import Foundation

extension Notification.Name {
    static let transcriptionsDidChange = Notification.Name("transcriptionsDidChange")
}

// MARK: - Transcription Storage Service
/// Handles persistence of transcriptions to disk using JSON encoding
final class TranscriptionStorage {
    
    static let shared = TranscriptionStorage()
    
    private let fileManager = FileManager.default
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    
    // Storage directory inside Application Support
    private var storageDirectory: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appFolder = appSupport.appendingPathComponent("TranscriptorNative", isDirectory: true)
        
        // Create directory if needed
        if !fileManager.fileExists(atPath: appFolder.path) {
            try? fileManager.createDirectory(at: appFolder, withIntermediateDirectories: true)
        }
        
        return appFolder
    }
    
    private var transcriptionsFile: URL {
        storageDirectory.appendingPathComponent("transcriptions.json")
    }
    
    private init() {
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }
    
    // MARK: - Public API
    
    /// Load all saved transcriptions
    func loadTranscriptions() -> [Transcription] {
        guard fileManager.fileExists(atPath: transcriptionsFile.path) else {
            return []
        }
        
        do {
            let data = try Data(contentsOf: transcriptionsFile)
            let transcriptions = try decoder.decode([Transcription].self, from: data)
            AppLogger.shared.log("Loaded \(transcriptions.count) transcriptions from storage", category: .app)
            return transcriptions.sorted { $0.createdAt > $1.createdAt }
        } catch {
            AppLogger.shared.log("Failed to load transcriptions: \(error.localizedDescription)", level: .error, category: .app)
            return []
        }
    }
    
    /// Save all transcriptions
    func saveTranscriptions(_ transcriptions: [Transcription]) {
        do {
            let data = try encoder.encode(transcriptions)
            try data.write(to: transcriptionsFile, options: .atomic)
            AppLogger.shared.log("Saved \(transcriptions.count) transcriptions to storage", category: .app)
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .transcriptionsDidChange, object: nil)
            }
        } catch {
            AppLogger.shared.log("Failed to save transcriptions: \(error.localizedDescription)", level: .error, category: .app)
        }
    }
    
    /// Add or update a single transcription
    func saveTranscription(_ transcription: Transcription) {
        var transcriptions = loadTranscriptions()
        
        if let index = transcriptions.firstIndex(where: { $0.id == transcription.id }) {
            transcriptions[index] = transcription
        } else {
            transcriptions.insert(transcription, at: 0)
        }
        
        saveTranscriptions(transcriptions)
    }
    
    /// Delete a transcription by ID
    func deleteTranscription(id: UUID) {
        var transcriptions = loadTranscriptions()
        transcriptions.removeAll { $0.id == id }
        saveTranscriptions(transcriptions)
    }
    
    /// Toggle favorite status
    func toggleFavorite(id: UUID) -> Transcription? {
        var transcriptions = loadTranscriptions()
        
        guard let index = transcriptions.firstIndex(where: { $0.id == id }) else {
            return nil
        }
        
        transcriptions[index].isFavorite.toggle()
        saveTranscriptions(transcriptions)
        
        return transcriptions[index]
    }
    
    /// Clear all transcriptions
    func clearAll() {
        try? fileManager.removeItem(at: transcriptionsFile)
        AppLogger.shared.log("Cleared all transcriptions from storage", category: .app)
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .transcriptionsDidChange, object: nil)
        }
    }
    
    // MARK: - Audio File Management
    
    /// Copy audio file to app storage for persistence
    func persistAudioFile(from sourceURL: URL, for transcriptionId: UUID) -> URL? {
        let audioFolder = storageDirectory.appendingPathComponent("audio", isDirectory: true)
        
        // Create audio folder if needed
        if !fileManager.fileExists(atPath: audioFolder.path) {
            try? fileManager.createDirectory(at: audioFolder, withIntermediateDirectories: true)
        }
        
        let fileExtension = sourceURL.pathExtension
        let destinationURL = audioFolder.appendingPathComponent("\(transcriptionId.uuidString).\(fileExtension)")
        
        do {
            // Remove existing file if any
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
            AppLogger.shared.log("Persisted audio file to: \(destinationURL.lastPathComponent)", category: .app)
            return destinationURL
        } catch {
            AppLogger.shared.log("Failed to persist audio file: \(error.localizedDescription)", level: .error, category: .app)
            return nil
        }
    }
    
    /// Delete persisted audio file
    func deleteAudioFile(for transcriptionId: UUID) {
        let audioFolder = storageDirectory.appendingPathComponent("audio", isDirectory: true)
        
        // Try common extensions
        let extensions = ["mp3", "wav", "m4a", "mp4", "mov", "aac", "ogg", "flac"]
        
        for ext in extensions {
            let fileURL = audioFolder.appendingPathComponent("\(transcriptionId.uuidString).\(ext)")
            if fileManager.fileExists(atPath: fileURL.path) {
                try? fileManager.removeItem(at: fileURL)
                AppLogger.shared.log("Deleted audio file: \(fileURL.lastPathComponent)", category: .app)
                break
            }
        }
    }
}
