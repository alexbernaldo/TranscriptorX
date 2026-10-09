import AppIntents
import Foundation

/// Transcribe an audio/video file and return the plain text.
struct TranscribeFileIntent: AppIntent {
    static var title: LocalizedStringResource = "Transcribe file"
    static var description = IntentDescription("Transcribes an audio or video file with your current settings and returns the text.")

    @Parameter(title: "Audio or video file")
    var file: IntentFile

    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let data = file.data
        guard !data.isEmpty else {
            throw $file.needsValueError("Pick an audio or video file.")
        }
        let ext = URL(fileURLWithPath: file.filename).pathExtension
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("intent_\(UUID().uuidString).\(ext.isEmpty ? "m4a" : ext)")
        try data.write(to: tmp)

        guard FileInputService.isSupported(tmp) else {
            throw $file.needsValueError("Unsupported media type.")
        }

        let settings = TranscriptionSettings.default
        let preprocessOptions = AudioPreprocessor.Options(
            isolateVoice: settings.isolateVoice, denoise: settings.deepfilter,
            normalize: settings.normalize, useVAD: settings.useVAD)
        let result = try await TranscriptionService.shared.transcribe(
            file: tmp, modelId: settings.selectedModelId, settings: settings,
            preprocessOptions: preprocessOptions, onProgress: { _, _ in },
            onSegment: { _ in })
        try? FileManager.default.removeItem(at: tmp)
        return .result(value: result.plainText)
    }
}
