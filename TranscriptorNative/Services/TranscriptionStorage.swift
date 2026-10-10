import Foundation

extension Notification.Name {
    static let transcriptionsDidChange = Notification.Name("transcriptionsDidChange")
}

// MARK: - Transcription Storage Service
/// API pública de persistencia del historial. Internamente delega en
/// `TranscriptionDatabase` (SQLite + FTS5, #6); el JSON monolítico solo
/// sobrevive como backup de migración (`transcriptions.json.bak`).
final class TranscriptionStorage {

    static let shared = TranscriptionStorage()

    private let fileManager = FileManager.default

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

    private var db: TranscriptionDatabase { TranscriptionDatabase.shared }

    private init() {}

    private func postDidChange() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .transcriptionsDidChange, object: nil)
        }
    }

    // MARK: - Public API

    /// Load all saved transcriptions (activas; la papelera está en `loadTrash()`)
    func loadTranscriptions() -> [Transcription] {
        db.loadAll()
    }

    /// Upserts diferenciales de los indicados (no borra filas ausentes:
    /// preserva la papelera y otros registros).
    func saveTranscriptions(_ transcriptions: [Transcription]) {
        transcriptions.forEach { db.upsert($0) }
        AppLogger.shared.log("Saved \(transcriptions.count) transcriptions to storage", category: .app)
        postDidChange()
    }

    /// Add or update a single transcription
    func saveTranscription(_ transcription: Transcription) {
        db.upsert(transcription)
        postDidChange()
    }

    /// Soft-delete: pasa la transcripción a la papelera (#18).
    /// Papelera: el audio se elimina en purgeTrash/deleteForever (#18).
    func deleteTranscription(id: UUID) {
        db.setDeleted(id: id, at: Date())
        postDidChange()
    }

    /// Toggle favorite status
    func toggleFavorite(id: UUID) -> Transcription? {
        guard var transcription = db.find(id: id) else { return nil }
        transcription.isFavorite.toggle()
        db.upsert(transcription)
        postDidChange()
        return transcription
    }

    /// Clear all transcriptions (activos + papelera)
    func clearAll() {
        db.clearAll()
        AppLogger.shared.log("Cleared all transcriptions from storage", category: .app)
        postDidChange()
    }

    // MARK: - Trash API (#18)

    /// Transcripciones en la papelera, ordenadas por fecha de borrado.
    func loadTrash() -> [Transcription] {
        db.loadTrash()
    }

    /// Restaura una transcripción de la papelera al historial activo.
    func restoreTranscription(id: UUID) {
        db.setDeleted(id: id, at: nil)
        postDidChange()
    }

    /// Borrado definitivo: fila + audio persistido.
    func deleteForever(id: UUID) {
        db.removeForever(id: id)
        deleteAudioFile(for: id)
        postDidChange()
    }

    /// Purga automática por retención (días en UserDefaults `trashRetentionDays`, default 30).
    func purgeTrash() {
        let days = UserDefaults.standard.object(forKey: "trashRetentionDays") as? Int ?? 30
        let purged = db.purgeTrash(olderThanDays: days)
        guard !purged.isEmpty else { return }
        purged.forEach { deleteAudioFile(for: $0) }
        AppLogger.shared.log("Purged \(purged.count) trashed transcriptions", category: .app)
        postDidChange()
    }

    /// Búsqueda a nivel de texto sobre el historial activo (FTS5, con fallback LIKE).
    func searchTranscriptions(matching query: String) -> [Transcription] {
        db.search(matching: query)
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
