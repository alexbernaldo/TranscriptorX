import SwiftUI
import UniformTypeIdentifiers

/// Centralized service for file selection (picker + drag&drop).
/// Provides a single source of truth for supported file types and picker configuration.
enum FileInputService {
    
    /// All audio/video types the app supports for transcription
    static let supportedTypes: [UTType] = {
        var types: [UTType] = [
            .audio,
            .movie,
            .mp3,
            .mpeg4Audio,
            .wav,
            .mpeg4Movie,
            .quickTimeMovie,
            .aiff,
        ]
        if let m4a = UTType(filenameExtension: "m4a") {
            types.append(m4a)
        }
        return Array(Set(types))
    }()
    
    /// Human-readable description of supported formats
    static let supportedFormatsDescription = "MP3, WAV, M4A, MP4, MOV, AIFF y más"
    
    /// Show a system file picker for audio/video files.
    /// - Parameters:
    ///   - allowsMultiple: Whether to allow selecting multiple files
    ///   - prompt: Button label in the open panel (default: "Transcribir")
    /// - Returns: Selected URLs, or empty array if cancelled
    static func showFilePicker(
        allowsMultiple: Bool = false,
        prompt: String = "Transcribir"
    ) -> [URL] {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = supportedTypes
        panel.allowsMultipleSelection = allowsMultiple
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "Selecciona un archivo de audio o video para transcribir"
        panel.prompt = prompt
        
        guard panel.runModal() == .OK else { return [] }
        return panel.urls
    }
    
    /// Convenience: show the file picker and return a single URL, or nil if cancelled.
    /// Use this instead of `showFilePicker().first` scattered across views.
    static func pickSingleFile(prompt: String = "Transcribir") -> URL? {
        showFilePicker(allowsMultiple: false, prompt: prompt).first
    }
    
    /// Validate whether a URL has a supported media type
    static func isSupported(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return supportedTypes.contains(where: { type.conforms(to: $0) })
    }
}
