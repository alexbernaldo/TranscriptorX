import Foundation
import AppKit

/// Formats of the export sheet (spec 6.16) plus PDF, which the app already offered.
enum ExportKind: String, CaseIterable, Identifiable, Codable {
    case txt, md, docx, html, pdf, srt, vtt, csv, json, avid, project

    var id: String { rawValue }

    var name: String {
        switch self {
        case .txt: return TXL.t("export.format.txt", "Texto")
        case .md: return "Markdown"
        case .docx: return "Word"
        case .html: return TXL.t("export.format.html", "Web")
        case .pdf: return "PDF"
        case .srt: return "SubRip"
        case .vtt: return "WebVTT"
        case .csv: return "CSV"
        case .json: return "JSON"
        case .avid: return "Avid"
        case .project: return "Transcriptor X"
        }
    }

    /// Extension shown in SF Mono next to the name.
    var extensionLabel: String {
        switch self {
        case .avid: return "CMX3600 EDL"
        case .project: return ".transcriptor"
        default: return rawValue
        }
    }

    var fileExtension: String {
        switch self {
        case .avid: return "avid"
        case .project: return ProjectPackage.fileExtension
        default: return rawValue
        }
    }

    enum Group: CaseIterable {
        case document, subtitles, data, video, project
        var title: String {
            switch self {
            case .document: return TXL.t("export.group.document", "Documento")
            case .subtitles: return TXL.t("export.group.subtitles", "Subtítulos")
            case .data: return TXL.t("export.group.data", "Datos")
            case .video: return TXL.t("export.group.video", "Edición de vídeo")
            case .project: return TXL.t("export.group.project", "Proyecto")
            }
        }
        var kinds: [ExportKind] {
            switch self {
            case .document: return [.txt, .md, .docx, .html, .pdf]
            case .subtitles: return [.srt, .vtt]
            case .data: return [.csv, .json]
            case .video: return [.avid]
            case .project: return [.project]
            }
        }
    }

    var needsTimedSegments: Bool { self == .srt || self == .vtt || self == .avid }

    var legacyFormat: ExportFormat? {
        switch self {
        case .txt: return .txt
        case .md: return .md
        case .docx: return .docx
        case .html: return .html
        case .pdf: return .pdf
        case .srt: return .srt
        case .vtt: return .vtt
        case .csv: return .csv
        case .json: return .json
        case .avid: return .avid
        case .project: return nil
        }
    }
}

/// Options that really exist per format in `ExportDocument` and the generators (validated in 12.1 #8).
struct ExportKindOptions: Codable, Equatable {
    var style: ExportStyle = .segments
    var grouping: ExportGroupingPreference = .none
    var showSpeakerNames = true
    var favoritesOnly = false
    var includeTimestamps = true
    var useMilliseconds = false
    var showEndTimestamp = false
    var fps = 25

    enum Option {
        case style, grouping, speakerNames, favoritesOnly, timestamps, milliseconds, endTimestamp, fps
    }

    static func available(for kind: ExportKind) -> [Option] {
        switch kind {
        case .txt, .md: return [.style, .grouping, .speakerNames, .favoritesOnly, .timestamps, .milliseconds, .endTimestamp]
        case .docx, .html, .json, .pdf: return [.favoritesOnly]
        case .csv: return [.favoritesOnly, .timestamps]
        case .srt, .vtt: return [.speakerNames, .favoritesOnly]
        case .avid: return [.favoritesOnly, .fps]
        case .project: return []
        }
    }

    // Remembered per format (spec 6.16 «Las opciones se recuerdan para cada formato»).
    static func load(_ kind: ExportKind) -> ExportKindOptions {
        guard let data = UserDefaults.standard.data(forKey: "export.options.\(kind.rawValue)"),
              let o = try? JSONDecoder().decode(ExportKindOptions.self, from: data) else { return ExportKindOptions() }
        return o
    }

    func save(_ kind: ExportKind) {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: "export.options.\(kind.rawValue)") }
    }

    static func reset(_ kind: ExportKind) {
        UserDefaults.standard.removeObject(forKey: "export.options.\(kind.rawValue)")
    }

    /// One-line summary for Ajustes › Exportación.
    func summary(for kind: ExportKind) -> String {
        var parts: [String] = []
        for option in Self.available(for: kind) {
            switch option {
            case .favoritesOnly where favoritesOnly: parts.append(TXL.t("export.opt.favoritesOnly", "Solo favoritos"))
            case .timestamps: parts.append(includeTimestamps ? TXL.t("export.summary.timestamps", "con timestamps") : TXL.t("export.summary.noTimestamps", "sin timestamps"))
            case .speakerNames where !showSpeakerNames: parts.append(TXL.t("export.summary.noSpeakers", "sin hablantes"))
            case .fps: parts.append("\(fps) fps")
            default: break
            }
        }
        return parts.isEmpty ? TXL.t("export.summary.default", "Opciones por defecto") : parts.joined(separator: " · ")
    }
}

enum ExportFailure: LocalizedError {
    case noContent
    case noTimedSegments
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .noContent: return TXL.t("export.error.empty", "No hay contenido para exportar")
        case .noTimedSegments: return TXL.t("export.error.noSegments", "Este documento no tiene segmentos con tiempo")
        case .writeFailed(let m): return m
        }
    }
}

/// Writes one transcription in one format. Generators are the existing ones.
@MainActor
enum ExportEngine {
    static func data(for t: Transcription, kind: ExportKind, options o: ExportKindOptions) async throws -> Data {
        let settings = QuickSettingsModel.defaultSettings()
        var docOptions = ExportDocument.ExportOptions()
        docOptions.style = o.style
        docOptions.grouping = o.grouping
        docOptions.showTimestamps = o.includeTimestamps
        docOptions.showEndTimestamp = o.showEndTimestamp
        docOptions.useMilliseconds = o.useMilliseconds
        docOptions.showSpeakerNames = o.showSpeakerNames
        docOptions.favoritesOnly = o.favoritesOnly
        docOptions.fps = o.fps
        var settingsForDoc = settings
        settingsForDoc.language = t.language
        let document = ExportDocument.from(transcription: t, result: nil, settings: settingsForDoc,
                                           fileName: t.title, options: docOptions)
        guard !document.isEmpty else { throw ExportFailure.noContent }
        if kind.needsTimedSegments && document.segments.isEmpty { throw ExportFailure.noTimedSegments }

        switch kind {
        case .txt, .md:
            return Data(document.styledText(options: docOptions).utf8)
        case .srt, .vtt:
            var segments = (t.segments ?? []).filter { !$0.isDeleted }
            if o.favoritesOnly { segments = segments.filter(\.isFavorite) }
            if !o.showSpeakerNames { segments = segments.map { var s = $0; s.speaker = nil; return s } }
            let result = TranscriptionResult(segments: segments)
            let text = kind == .srt ? result.toSRT(speakerNames: t.speakerNames) : result.toVTT(speakerNames: t.speakerNames)
            return Data(text.utf8)
        case .csv:
            return try CSVExportGenerator(includeTimestamps: o.includeTimestamps).generate(from: document)
        case .html:
            return try HTMLExportGenerator().generate(from: document)
        case .docx:
            return try DOCXExportGenerator().generate(from: document)
        case .json:
            return try JSONExportGenerator().generate(from: document)
        case .avid:
            return try AvidExportGenerator(fps: o.fps).generate(from: document)
        case .pdf:
            return try await PDFExportGenerator().generate(from: document)
        case .project:
            throw ExportFailure.noContent
        }
    }

    /// Writes to `folder`, never overwriting: «Nombre 2.srt» if the name exists.
    static func write(_ t: Transcription, kind: ExportKind, options: ExportKindOptions, folder: URL, baseName: String) async throws -> URL {
        let safe = baseName.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        var url = folder.appendingPathComponent(safe).appendingPathExtension(kind.fileExtension)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(safe) \(n)").appendingPathExtension(kind.fileExtension)
            n += 1
        }
        guard FileManager.default.isWritableFile(atPath: folder.path) else {
            throw ExportFailure.writeFailed(TXL.f("export.error.permission", "No se pudo guardar en %@. No hay permiso de escritura en esa carpeta.", folder.lastPathComponent))
        }
        if kind == .project {
            let target = url
            try await Task.detached { try ProjectPackage.save(transcription: t, to: target) }.value
            return url
        }
        let data = try await data(for: t, kind: kind, options: options)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw ExportFailure.writeFailed(TXL.f("export.error.permission", "No se pudo guardar en %@. No hay permiso de escritura en esa carpeta.", folder.lastPathComponent))
        }
        return url
    }
}

/// Destination folders: Downloads plus recently used ones (spec 6.16 «recientes + Otra…»).
enum ExportFolders {
    static var downloads: URL { FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0] }

    static var recents: [URL] {
        (UserDefaults.standard.stringArray(forKey: "export.recentFolders") ?? [])
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func remember(_ url: URL) {
        var list = (UserDefaults.standard.stringArray(forKey: "export.recentFolders") ?? []).filter { $0 != url.path }
        list.insert(url.path, at: 0)
        UserDefaults.standard.set(Array(list.prefix(5)), forKey: "export.recentFolders")
    }

    static var defaultFolder: URL { recents.first ?? downloads }

    static func displayName(_ url: URL) -> String {
        url == downloads ? TXL.t("export.folder.downloads", "Descargas") : FileManager.default.displayName(atPath: url.path)
    }

    static func choose() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = TXL.t("export.folder.choose", "Elegir")
        return panel.runModal() == .OK ? panel.url : nil
    }
}
