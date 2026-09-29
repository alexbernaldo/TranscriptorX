import Foundation

/// Manages crash recovery and session persistence
/// Implements "Write-Ahead Logging" pattern for data safety
actor RecoveryManager {
    static let shared = RecoveryManager()
    
    // MARK: - Paths
    
    private let appSupportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Transcriptor")
    
    private nonisolated var manifestsDir: URL {
        appSupportDir.appendingPathComponent("Manifests")
    }
    
    private nonisolated var recoveredDir: URL {
        appSupportDir.appendingPathComponent("Recovered")
    }
    
    private nonisolated var tempRecordingsDir: URL {
        appSupportDir.appendingPathComponent("TempRecordings")
    }
    
    // MARK: - Manifest Types
    
    struct RecordingManifest: Codable {
        let id: UUID
        let startTime: Date
        let audioFilePath: String
        let source: String // "system" or "microphone"
        var lastUpdateTime: Date
        var durationAtLastUpdate: TimeInterval
        var status: Status
        
        enum Status: String, Codable {
            case recording
            case finalizing
            case completed
            case interrupted
        }
    }
    
    struct TranscriptionManifest: Codable {
        let id: UUID
        let startTime: Date
        let audioFilePath: String
        let modelId: String
        var lastUpdateTime: Date
        var segments: [PartialSegment]
        var status: Status
        
        struct PartialSegment: Codable {
            let startTime: Double
            let endTime: Double
            let text: String
            let speaker: String?
        }
        
        enum Status: String, Codable {
            case loading
            case processing
            case completed
            case interrupted
        }
    }
    
    struct RecoveredItem: Identifiable {
        let id: UUID
        let type: RecoveryType
        let date: Date
        let fileURL: URL
        let duration: TimeInterval?
        let partialText: String?
        
        enum RecoveryType {
            case audio
            case transcription
        }
    }
    
    // MARK: - Initialization
    
    private init() {
        // Create directories if needed
        try? FileManager.default.createDirectory(at: manifestsDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: recoveredDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: tempRecordingsDir, withIntermediateDirectories: true)
    }
    
    // MARK: - Recording Session Management
    
    /// Start a new recording session - creates manifest before recording starts
    func beginRecordingSession(source: String) async throws -> (sessionId: UUID, audioURL: URL) {
        let sessionId = UUID()
        let audioFileName = "recording_\(sessionId.uuidString).wav"
        let audioURL = tempRecordingsDir.appendingPathComponent(audioFileName)
        
        let manifest = RecordingManifest(
            id: sessionId,
            startTime: Date(),
            audioFilePath: audioURL.path,
            source: source,
            lastUpdateTime: Date(),
            durationAtLastUpdate: 0,
            status: .recording
        )
        
        try saveRecordingManifest(manifest)
        
        AppLogger.shared.log("Recording session started", category: .recording, metadata: ["sessionId": sessionId.uuidString])
        
        return (sessionId, audioURL)
    }
    
    /// Update recording progress (call periodically during recording)
    func updateRecordingProgress(sessionId: UUID, duration: TimeInterval) async throws {
        guard var manifest = try loadRecordingManifest(sessionId: sessionId) else { return }
        
        manifest.lastUpdateTime = Date()
        manifest.durationAtLastUpdate = duration
        
        try saveRecordingManifest(manifest)
    }
    
    /// Mark recording as finalizing (transitioning to save)
    func markRecordingFinalizing(sessionId: UUID) async throws {
        guard var manifest = try loadRecordingManifest(sessionId: sessionId) else { return }
        
        manifest.status = .finalizing
        manifest.lastUpdateTime = Date()
        
        try saveRecordingManifest(manifest)
    }
    
    /// Complete recording session - removes manifest on success
    func completeRecordingSession(sessionId: UUID, finalURL: URL) async throws {
        // Move file from temp to final location if different
        let manifest = try loadRecordingManifest(sessionId: sessionId)
        
        if let manifest = manifest, manifest.audioFilePath != finalURL.path {
            let tempURL = URL(fileURLWithPath: manifest.audioFilePath)
            if FileManager.default.fileExists(atPath: tempURL.path) {
                try? FileManager.default.removeItem(at: finalURL)
                try FileManager.default.moveItem(at: tempURL, to: finalURL)
            }
        }
        
        // Remove manifest - session completed successfully
        try deleteRecordingManifest(sessionId: sessionId)
        
        AppLogger.shared.log("Recording session completed", category: .recording, metadata: ["sessionId": sessionId.uuidString])
    }
    
    /// Cancel recording session - cleans up temp files
    func cancelRecordingSession(sessionId: UUID) async throws {
        if let manifest = try loadRecordingManifest(sessionId: sessionId) {
            // Delete temp audio file
            let tempURL = URL(fileURLWithPath: manifest.audioFilePath)
            try? FileManager.default.removeItem(at: tempURL)
        }
        
        // Remove manifest
        try deleteRecordingManifest(sessionId: sessionId)
        
        AppLogger.shared.log("Recording session cancelled", category: .recording, metadata: ["sessionId": sessionId.uuidString])
    }
    
    // MARK: - Transcription Session Management
    
    /// Start a new transcription session
    func beginTranscriptionSession(audioURL: URL, modelId: String) async throws -> UUID {
        let sessionId = UUID()
        
        let manifest = TranscriptionManifest(
            id: sessionId,
            startTime: Date(),
            audioFilePath: audioURL.path,
            modelId: modelId,
            lastUpdateTime: Date(),
            segments: [],
            status: .loading
        )
        
        try saveTranscriptionManifest(manifest)
        
        AppLogger.shared.log("Transcription session started", category: .transcription, metadata: [
            "sessionId": sessionId.uuidString,
            "modelId": modelId
        ])
        
        return sessionId
    }
    
    /// Update transcription progress with new segments
    func updateTranscriptionProgress(sessionId: UUID, status: TranscriptionManifest.Status, newSegments: [TranscriptionManifest.PartialSegment]? = nil) async throws {
        guard var manifest = try loadTranscriptionManifest(sessionId: sessionId) else { return }
        
        manifest.status = status
        manifest.lastUpdateTime = Date()
        
        if let segments = newSegments {
            manifest.segments.append(contentsOf: segments)
        }
        
        try saveTranscriptionManifest(manifest)
    }
    
    /// Complete transcription session
    func completeTranscriptionSession(sessionId: UUID) async throws {
        try deleteTranscriptionManifest(sessionId: sessionId)
        
        AppLogger.shared.log("Transcription session completed", category: .transcription, metadata: ["sessionId": sessionId.uuidString])
    }
    
    // MARK: - Recovery on Launch
    
    /// Check for interrupted sessions and recover them
    /// Call this on app launch, before showing main UI
    func checkForRecoverableItems() async -> [RecoveredItem] {
        var recoveredItems: [RecoveredItem] = []
        
        // Check recording manifests
        let recordingManifests = loadAllRecordingManifests()
        for manifest in recordingManifests where manifest.status != .completed {
            // Found interrupted recording
            let tempURL = URL(fileURLWithPath: manifest.audioFilePath)
            
            if FileManager.default.fileExists(atPath: tempURL.path) {
                // Move to recovered folder
                let recoveredFileName = "recovered_\(manifest.id.uuidString).wav"
                let recoveredURL = recoveredDir.appendingPathComponent(recoveredFileName)
                
                do {
                    try? FileManager.default.removeItem(at: recoveredURL)
                    try FileManager.default.moveItem(at: tempURL, to: recoveredURL)
                    
                    recoveredItems.append(RecoveredItem(
                        id: manifest.id,
                        type: .audio,
                        date: manifest.startTime,
                        fileURL: recoveredURL,
                        duration: manifest.durationAtLastUpdate,
                        partialText: nil
                    ))
                    
                    AppLogger.shared.log("Recovered interrupted recording", category: .recovery, metadata: [
                        "sessionId": manifest.id.uuidString,
                        "duration": String(format: "%.1f", manifest.durationAtLastUpdate)
                    ])
                } catch {
                    AppLogger.shared.log("Failed to recover recording", category: .error, metadata: [
                        "sessionId": manifest.id.uuidString,
                        "error": error.localizedDescription
                    ])
                }
            }
            
            // Clean up manifest
            try? deleteRecordingManifest(sessionId: manifest.id)
        }
        
        // Check transcription manifests
        let transcriptionManifests = loadAllTranscriptionManifests()
        for manifest in transcriptionManifests where manifest.status != .completed {
            if !manifest.segments.isEmpty {
                // Has partial transcription - save it
                let partialText = manifest.segments.map { $0.text }.joined(separator: " ")
                let recoveredFileName = "recovered_\(manifest.id.uuidString).txt"
                let recoveredURL = recoveredDir.appendingPathComponent(recoveredFileName)
                
                do {
                    try partialText.write(to: recoveredURL, atomically: true, encoding: .utf8)
                    
                    recoveredItems.append(RecoveredItem(
                        id: manifest.id,
                        type: .transcription,
                        date: manifest.startTime,
                        fileURL: recoveredURL,
                        duration: nil,
                        partialText: String(partialText.prefix(200))
                    ))
                    
                    AppLogger.shared.log("Recovered partial transcription", category: .recovery, metadata: [
                        "sessionId": manifest.id.uuidString,
                        "segmentCount": String(manifest.segments.count)
                    ])
                } catch {
                    AppLogger.shared.log("Failed to save partial transcription", category: .error, metadata: [
                        "error": error.localizedDescription
                    ])
                }
            }
            
            // Clean up manifest
            try? deleteTranscriptionManifest(sessionId: manifest.id)
        }
        
        return recoveredItems
    }
    
    /// Get list of recovered items in the Recovered folder
    func getRecoveredItems() -> [RecoveredItem] {
        var items: [RecoveredItem] = []
        
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: recoveredDir,
            includingPropertiesForKeys: [.creationDateKey, .fileSizeKey]
        ) else { return [] }
        
        for url in contents {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let creationDate = attributes[.creationDate] as? Date else { continue }
            
            let isAudio = ["m4a", "wav", "mp3"].contains(url.pathExtension.lowercased())
            
            items.append(RecoveredItem(
                id: UUID(),
                type: isAudio ? .audio : .transcription,
                date: creationDate,
                fileURL: url,
                duration: nil,
                partialText: isAudio ? nil : (try? String(contentsOf: url, encoding: .utf8).prefix(200)).map(String.init)
            ))
        }
        
        return items.sorted { $0.date > $1.date }
    }
    
    /// Delete a recovered item
    func deleteRecoveredItem(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }
    
    // MARK: - Private Helpers
    
    private func manifestPath(for sessionId: UUID, type: String) -> URL {
        manifestsDir.appendingPathComponent("\(type)_\(sessionId.uuidString).json")
    }
    
    private func saveRecordingManifest(_ manifest: RecordingManifest) throws {
        let path = manifestPath(for: manifest.id, type: "recording")
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: path, options: .atomic)
    }
    
    private func loadRecordingManifest(sessionId: UUID) throws -> RecordingManifest? {
        let path = manifestPath(for: sessionId, type: "recording")
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        let data = try Data(contentsOf: path)
        return try JSONDecoder().decode(RecordingManifest.self, from: data)
    }
    
    private func deleteRecordingManifest(sessionId: UUID) throws {
        let path = manifestPath(for: sessionId, type: "recording")
        try? FileManager.default.removeItem(at: path)
    }
    
    private func loadAllRecordingManifests() -> [RecordingManifest] {
        guard let contents = try? FileManager.default.contentsOfDirectory(at: manifestsDir, includingPropertiesForKeys: nil) else { return [] }
        
        return contents.compactMap { url -> RecordingManifest? in
            guard url.lastPathComponent.hasPrefix("recording_") else { return nil }
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(RecordingManifest.self, from: data)
        }
    }
    
    private func saveTranscriptionManifest(_ manifest: TranscriptionManifest) throws {
        let path = manifestPath(for: manifest.id, type: "transcription")
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: path, options: .atomic)
    }
    
    private func loadTranscriptionManifest(sessionId: UUID) throws -> TranscriptionManifest? {
        let path = manifestPath(for: sessionId, type: "transcription")
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        let data = try Data(contentsOf: path)
        return try JSONDecoder().decode(TranscriptionManifest.self, from: data)
    }
    
    private func deleteTranscriptionManifest(sessionId: UUID) throws {
        let path = manifestPath(for: sessionId, type: "transcription")
        try? FileManager.default.removeItem(at: path)
    }
    
    private func loadAllTranscriptionManifests() -> [TranscriptionManifest] {
        guard let contents = try? FileManager.default.contentsOfDirectory(at: manifestsDir, includingPropertiesForKeys: nil) else { return [] }
        
        return contents.compactMap { url -> TranscriptionManifest? in
            guard url.lastPathComponent.hasPrefix("transcription_") else { return nil }
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(TranscriptionManifest.self, from: data)
        }
    }
    
    // MARK: - Public Recovery Methods
    
    /// Get all recoverable items for the UI
    func getRecoveredItems() async throws -> [RecoveredItem] {
        var items: [RecoveredItem] = []
        
        // Check manifests directory for incomplete sessions
        guard let manifestFiles = try? FileManager.default.contentsOfDirectory(at: manifestsDir, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return []
        }
        
        for file in manifestFiles where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file) else { continue }
            
            // Try to decode as recording manifest
            if let manifest = try? JSONDecoder().decode(RecordingManifest.self, from: data),
               manifest.status == .interrupted || manifest.status == .recording {
                let audioURL = URL(fileURLWithPath: manifest.audioFilePath)
                if FileManager.default.fileExists(atPath: audioURL.path) {
                    items.append(RecoveredItem(
                        id: manifest.id,
                        type: .audio,
                        date: manifest.startTime,
                        fileURL: audioURL,
                        duration: manifest.durationAtLastUpdate,
                        partialText: nil
                    ))
                }
            }
            
            // Try to decode as transcription manifest
            if let manifest = try? JSONDecoder().decode(TranscriptionManifest.self, from: data),
               manifest.status == .interrupted || manifest.status == .processing {
                let audioURL = URL(fileURLWithPath: manifest.audioFilePath)
                let partialText = manifest.segments.map { $0.text }.joined(separator: " ")
                
                items.append(RecoveredItem(
                    id: manifest.id,
                    type: .transcription,
                    date: manifest.startTime,
                    fileURL: audioURL,
                    duration: nil,
                    partialText: partialText.isEmpty ? nil : String(partialText.prefix(200))
                ))
            }
        }
        
        return items.sorted { $0.date > $1.date }
    }
    
    /// Delete a recovered item by ID
    func deleteRecoveredItem(_ id: UUID) async throws {
        // Try both types
        let recordingPath = manifestPath(for: id, type: "recording")
        let transcriptionPath = manifestPath(for: id, type: "transcription")
        
        try? FileManager.default.removeItem(at: recordingPath)
        try? FileManager.default.removeItem(at: transcriptionPath)
    }
}
