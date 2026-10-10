import Foundation

/// Save/open a whole project (metadata + transcript + optional media) as a .transcriptor ZIP.
enum ProjectPackage {
    static let fileExtension = "transcriptor"
    private static let zip = "/usr/bin/zip"
    private static let unzip = "/usr/bin/unzip"

    static func save(transcription: Transcription, to destination: URL) throws {
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("txpkg_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let manifest: [String: Any] = [
            "version": 1,
            "title": transcription.title,
            "createdAt": ISO8601DateFormatter().string(from: transcription.createdAt),
            "language": transcription.language,
            "duration": transcription.duration
        ]
        try JSONSerialization.data(withJSONObject: manifest)
            .write(to: work.appendingPathComponent("manifest.json"))
        try JSONEncoder().encode(transcription)
            .write(to: work.appendingPathComponent("transcript.json"))

        if let media = transcription.sourceURL, FileManager.default.fileExists(atPath: media.path) {
            let mediaDir = work.appendingPathComponent("media")
            try FileManager.default.createDirectory(at: mediaDir, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: media, to: mediaDir.appendingPathComponent(media.lastPathComponent))
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: zip)
        proc.currentDirectoryURL = work
        proc.arguments = ["-r", "-q", destination.path, "."]
        try proc.run(); proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { throw ProjectError.zipFailed }
    }

    static func open(from source: URL) throws -> (transcription: Transcription, settings: TranscriptionSettings?) {
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("txpkg_open_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: unzip)
        proc.arguments = ["-q", source.path, "-d", work.path]
        try proc.run(); proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { throw ProjectError.unzipFailed }

        let data = try Data(contentsOf: work.appendingPathComponent("transcript.json"))
        let transcription = try JSONDecoder().decode(Transcription.self, from: data)
        return (transcription, nil)
    }

    enum ProjectError: LocalizedError {
        case zipFailed, unzipFailed

        private var isSpanishUI: Bool {
            UserDefaults.standard.string(forKey: "app_ui_language") == "es"
        }

        private func localized(_ spanish: String, _ english: String) -> String {
            isSpanishUI ? spanish : english
        }

        var errorDescription: String? {
            switch self {
            case .zipFailed: return localized("No se pudo crear el paquete .transcriptor",
                                              "Could not create the .transcriptor package")
            case .unzipFailed: return localized("El paquete .transcriptor está dañado o es de otra app",
                                                "The .transcriptor package is damaged or from another app")
            }
        }
    }
}
