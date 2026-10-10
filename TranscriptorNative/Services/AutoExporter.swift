import Foundation

/// Writes an export next to a destination without showing UI (watch folders, batch).
enum AutoExporter {
    static func export(transcription: Transcription, settings: TranscriptionSettings,
                       format: ExportFormat, destination: URL) {
        let doc = ExportDocument.from(transcription: transcription, result: nil,
                                      settings: settings, fileName: transcription.title)
        guard !doc.isEmpty else { return }
        let name = transcription.title.replacingOccurrences(of: "/", with: "-")
        let url = destination.appendingPathComponent("\(name).\(format.rawValue)")
        do {
            let data: Data
            switch format {
            case .txt: data = Data(doc.plainText.utf8)
            case .json: data = try JSONExportGenerator().generate(from: doc)
            case .csv: data = try CSVExportGenerator(includeTimestamps: true).generate(from: doc)
            case .html: data = try HTMLExportGenerator().generate(from: doc)
            case .md: data = Data(transcription.text.utf8)
            case .srt:
                data = Data(TranscriptionResult(segments: transcription.segments ?? []).toSRT(speakerNames: transcription.speakerNames).utf8)
            case .vtt:
                data = Data(TranscriptionResult(segments: transcription.segments ?? []).toVTT(speakerNames: transcription.speakerNames).utf8)
            default:
                AppLogger.shared.log("AutoExporter: format not supported: \(format.rawValue)", category: .transcription)
                return
            }
            try data.write(to: url)
            AppLogger.shared.log("AutoExporter: wrote \(url.lastPathComponent)", category: .transcription)
        } catch {
            AppLogger.shared.logError(error, context: "AutoExporter", category: .transcription)
        }
    }
}
