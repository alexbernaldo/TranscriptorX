import Foundation

// MARK: - Export Document (Intermediate Representation)

/// A normalized, format-agnostic representation of a transcription export.
/// All export generators consume this model, decoupling content construction from serialization.
struct ExportDocument {
    let title: String
    let createdAt: Date
    let duration: TimeInterval
    let language: String
    let modelName: String
    let hasSpeakers: Bool
    let hasTimestamps: Bool
    let segments: [ExportSegment]
    let plainText: String

    struct ExportSegment {
        let startTime: TimeInterval
        let endTime: TimeInterval
        let text: String
        let speaker: Int?
        let isFavorite: Bool
    }

    /// Whether there is any content worth exporting
    var isEmpty: Bool {
        segments.isEmpty && plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Total number of unique speakers (0 if no diarization)
    var speakerCount: Int {
        Set(segments.compactMap { $0.speaker }).count
    }

    // MARK: - Factory

    /// Build an ExportDocument from the current app state
    static func from(
        transcription: Transcription?,
        result: TranscriptionResult?,
        settings: TranscriptionSettings,
        fileName: String?
    ) -> ExportDocument {
        let title = transcription?.title
            ?? fileName?.replacingOccurrences(of: "\\.[^.]+$", with: "", options: .regularExpression)
            ?? "Transcripción"

        let segments: [ExportSegment] = (result?.segments ?? transcription?.segments ?? [])
            .filter { !$0.isDeleted }
            .map { seg in
                ExportSegment(
                    startTime: seg.startTime,
                    endTime: seg.endTime,
                    text: seg.text,
                    speaker: seg.speaker,
                    isFavorite: seg.isFavorite
                )
            }

        let plainText: String
        if segments.isEmpty {
            // Plain-text transcription: use stored plainText, not segment join (which would be "")
            plainText = result?.plainText
                ?? transcription?.text
                ?? ""
        } else {
            plainText = segments.map { $0.text }.joined(separator: " ")
        }

        let hasSpeakers = segments.contains { $0.speaker != nil }
        let hasTimestamps = !segments.isEmpty

        let modelName = ModelInfo.allModels.first { $0.id == settings.selectedModelId }?.technicalName
            ?? settings.selectedModelId

        return ExportDocument(
            title: title,
            createdAt: transcription?.createdAt ?? Date(),
            duration: transcription?.duration ?? 0,
            language: settings.language,
            modelName: modelName,
            hasSpeakers: hasSpeakers,
            hasTimestamps: hasTimestamps,
            segments: segments,
            plainText: plainText
        )
    }
}

// MARK: - Helpers

extension ExportDocument.ExportSegment {
    var durationSeconds: TimeInterval {
        endTime - startTime
    }

    func formattedTime(_ seconds: TimeInterval) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        let s = Int(seconds) % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    var formattedStartTime: String { formattedTime(startTime) }
    var formattedEndTime: String { formattedTime(endTime) }
    var formattedDuration: String { formattedTime(durationSeconds) }
}
