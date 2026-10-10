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
        var allWords: [TranscriptionSegment.WordTimestamp] = []
    }

    /// User-facing export options (style, grouping, timestamp/speaker rendering, avid fps).
    struct ExportOptions: Equatable {
        var style: ExportStyle = .segments
        var grouping: ExportGroupingPreference = .none
        var showTimestamps = true
        var showEndTimestamp = false
        var useMilliseconds = false
        var showSpeakerNames = true
        var favoritesOnly = false
        var maxCharactersPerLine: Int? = nil
        var fps: Int = 25   // solo avid
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
        fileName: String?,
        options: ExportOptions = ExportOptions()
    ) -> ExportDocument {
        let title = transcription?.title
            ?? fileName?.replacingOccurrences(of: "\\.[^.]+$", with: "", options: .regularExpression)
            ?? "Transcripción"

        var segments: [ExportSegment] = (result?.segments ?? transcription?.segments ?? [])
            .filter { !$0.isDeleted }
            .map { seg in
                ExportSegment(
                    startTime: seg.startTime,
                    endTime: seg.endTime,
                    text: seg.text,
                    speaker: seg.speaker,
                    isFavorite: seg.isFavorite,
                    allWords: seg.words ?? []
                )
            }
        if options.favoritesOnly {
            segments = segments.filter { $0.isFavorite }
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

// MARK: - Styled text rendering

extension ExportDocument {

    /// Apply the grouping preference (none / people / sentences / words) to the segment list.
    private func groupedSegments(grouping: ExportGroupingPreference) -> [ExportSegment] {
        switch grouping {
        case .none:
            return segments

        case .people:
            guard segments.contains(where: { $0.speaker != nil }) else { return segments }
            var result: [ExportSegment] = []
            for seg in segments {
                if let i = result.indices.last, seg.speaker != nil, result[i].speaker == seg.speaker {
                    result[i] = ExportSegment(
                        startTime: result[i].startTime,
                        endTime: seg.endTime,
                        text: result[i].text + " " + seg.text,
                        speaker: seg.speaker,
                        isFavorite: result[i].isFavorite && seg.isFavorite,
                        allWords: result[i].allWords + seg.allWords
                    )
                } else {
                    result.append(seg)
                }
            }
            return result

        case .sentences:
            var result: [ExportSegment] = []
            for seg in segments {
                var pieces: [(text: String, start: String.Index, end: String.Index)] = []
                seg.text.enumerateSubstrings(in: seg.text.startIndex..<seg.text.endIndex,
                                             options: .bySentences) { sub, range, _, _ in
                    if let sub = sub {
                        pieces.append((sub, range.lowerBound, range.upperBound))
                    }
                }
                guard pieces.count > 1 else { result.append(seg); continue }
                let total = Double(seg.text.count)
                let span = seg.endTime - seg.startTime
                var cursor = seg.startTime
                for (j, p) in pieces.enumerated() {
                    let pieceLen = Double(seg.text.distance(from: p.start, to: p.end))
                    let pieceEnd = (j == pieces.count - 1)
                        ? seg.endTime
                        : min(cursor + span * pieceLen / total, seg.endTime)
                    result.append(ExportSegment(
                        startTime: cursor,
                        endTime: pieceEnd,
                        text: p.text.trimmingCharacters(in: .whitespaces),
                        speaker: seg.speaker,
                        isFavorite: seg.isFavorite,
                        allWords: seg.allWords
                    ))
                    cursor = pieceEnd
                }
            }
            return result

        case .words:
            // Sin datos de palabra → degradar a .none (la VM avisa con toast una sola vez)
            guard segments.contains(where: { !$0.allWords.isEmpty }) else { return segments }
            var result: [ExportSegment] = []
            for seg in segments {
                for w in seg.allWords {
                    result.append(ExportSegment(
                        startTime: w.start,
                        endTime: w.end,
                        text: w.text.trimmingCharacters(in: .whitespaces),
                        speaker: seg.speaker,
                        isFavorite: seg.isFavorite
                    ))
                }
            }
            return result
        }
    }

    private func exportTime(_ t: TimeInterval, options: ExportOptions) -> String {
        let total = max(0, t)
        let h = Int(total) / 3600
        let m = (Int(total) % 3600) / 60
        let s = Int(total) % 60
        guard options.useMilliseconds else {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        let ms = Int((total - floor(total)) * 1000)
        return String(format: "%d:%02d:%02d,%03d", h, m, s, ms)
    }

    private func wrap(_ text: String, every limit: Int?) -> [String] {
        guard let limit = limit, limit > 0 else { return [text] }
        var lines: [String] = []
        var current = ""
        for word in text.split(separator: " ") {
            if current.isEmpty {
                current = String(word)
            } else if current.count + 1 + word.count <= limit {
                current += " " + word
            } else {
                lines.append(current)
                current = String(word)
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }

    private func segmentLine(_ seg: ExportSegment, options: ExportOptions) -> String {
        var parts: [String] = []
        if options.showTimestamps {
            if options.showEndTimestamp {
                parts.append("[\(exportTime(seg.startTime, options: options)) - \(exportTime(seg.endTime, options: options))]")
            } else {
                parts.append("[\(exportTime(seg.startTime, options: options))]")
            }
        }
        if options.showSpeakerNames, let sp = seg.speaker {
            parts.append("[Speaker \(sp + 1)]")
        }
        parts.append(seg.text)
        return wrap(parts.joined(separator: " "), every: options.maxCharactersPerLine)
            .joined(separator: "\n")
    }

    private func subtitleBlock(_ seg: ExportSegment, options: ExportOptions) -> String {
        var blocks: [String] = []
        if options.showTimestamps {
            blocks.append("\(exportTime(seg.startTime, options: options)) --> \(exportTime(seg.endTime, options: options))")
        }
        blocks.append(wrap(seg.text, every: options.maxCharactersPerLine).joined(separator: "\n"))
        return blocks.joined(separator: "\n")
    }

    /// Line-oriented rendering honouring style + grouping (txt/md/srt fallback/whisper).
    func styledText(options: ExportOptions) -> String {
        guard !segments.isEmpty else { return plainText }
        let segs = groupedSegments(grouping: options.grouping)
        switch options.style {
        case .fullTranscript:
            return segs.map { $0.text }.joined(separator: " ")
        case .segments:
            return segs.map { segmentLine($0, options: options) }.joined(separator: "\n")
        case .subtitles:
            return segs.map { subtitleBlock($0, options: options) }.joined(separator: "\n\n")
        case .whisper:
            let items: [[String: Any]] = segs.map {
                ["start": $0.startTime, "end": $0.endTime, "text": $0.text]
            }
            let data = (try? JSONSerialization.data(
                withJSONObject: items, options: [.prettyPrinted, .sortedKeys])) ?? Data()
            return String(data: data, encoding: .utf8) ?? ""
        }
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
