import Foundation

/// A stretch of audio where one speaker talks, as returned by the diarizer.
struct SpeakerTurn: Equatable {
    let start: TimeInterval
    let end: TimeInterval
    /// Diarizer label («S1», «SPEAKER_00»…). Only used to tell speakers apart.
    let label: String
}

/// Merges diarization turns into whisper segments (pure, no models; tested).
///
/// The diarizer and whisper cut the audio independently, so a whisper segment can
/// contain a speaker change («…gracias. Bueno, yo creo que…»). When the segment has
/// word timestamps that match its text, every word gets the speaker that overlaps it
/// most and the segment is split where the speaker changes. Without usable words the
/// whole segment takes the speaker with the largest overlap.
enum SpeakerAssignment {

    /// Words shorter than this run are absorbed by their neighbours, so a single
    /// misaligned word does not create a one-word segment.
    static let minimumRunWords = 2

    static func assign(_ segments: [TranscriptionSegment], turns: [SpeakerTurn]) -> [TranscriptionSegment] {
        let turns = turns.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        guard !turns.isEmpty else { return segments }

        var labelled: [(segment: TranscriptionSegment, label: String?)] = []
        for segment in segments {
            if segment.isDeleted {
                labelled.append((segment, nil))
                continue
            }
            if let words = segment.words, !words.isEmpty,
               EditorOperations.wordsMatch(words, text: segment.text) {
                labelled.append(contentsOf: split(segment, words: words, turns: turns))
            } else {
                labelled.append((segment, label(for: segment.startTime, segment.endTime, in: turns)))
            }
        }

        // Speakers are numbered in order of first appearance (0 is whoever talks first).
        var order: [String: Int] = [:]
        for case let (_, label?) in labelled where order[label] == nil {
            order[label] = order.count
        }
        return labelled.map { item in
            var segment = item.segment
            segment.speaker = item.label.flatMap { order[$0] }
            return segment
        }
    }

    // MARK: Words

    private static func split(_ segment: TranscriptionSegment,
                              words: [TranscriptionSegment.WordTimestamp],
                              turns: [SpeakerTurn]) -> [(TranscriptionSegment, String?)] {
        var labels: [String?] = words.map { label(for: $0.start, $0.end, in: turns) }
        // Words without any speech turn take the previous (or next) known speaker.
        var previous: String?
        for i in labels.indices {
            if let current = labels[i] { previous = current } else { labels[i] = previous }
        }
        let firstKnown: String? = labels.first(where: { $0 != nil }) ?? nil
        for i in labels.indices where labels[i] == nil { labels[i] = firstKnown }
        let runs = smoothedRuns(labels)
        guard runs.count > 1 else { return [(segment, runs.first?.label)] }

        var result: [(TranscriptionSegment, String?)] = []
        for (index, run) in runs.enumerated() {
            let runWords = Array(words[run.range])
            let text = runWords.map { $0.text.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            let start = index == 0 ? segment.startTime : runWords.first!.start
            let end = index == runs.count - 1 ? segment.endTime : runWords.last!.end
            let piece = TranscriptionSegment(
                id: index == 0 ? segment.id : UUID(),
                startTime: start,
                endTime: max(end, start),
                text: text,
                speaker: nil,
                isFavorite: segment.isFavorite,
                words: runWords
            )
            result.append((piece, run.label))
        }
        return result
    }

    struct Run: Equatable {
        var label: String?
        var range: Range<Int>
    }

    /// Consecutive equal labels grouped into runs; runs shorter than `minimumRunWords`
    /// join the longer neighbour (unless the segment is that short).
    static func smoothedRuns(_ labels: [String?]) -> [Run] {
        var runs: [Run] = []
        for (i, label) in labels.enumerated() {
            if let last = runs.last, last.label == label {
                runs[runs.count - 1].range = last.range.lowerBound..<(i + 1)
            } else {
                runs.append(Run(label: label, range: i..<(i + 1)))
            }
        }
        var changed = true
        while changed && runs.count > 1 {
            changed = false
            guard let shortIndex = runs.indices.first(where: { runs[$0].range.count < minimumRunWords }) else { break }
            let previous = shortIndex > 0 ? shortIndex - 1 : nil
            let next = shortIndex < runs.count - 1 ? shortIndex + 1 : nil
            let target: Int
            switch (previous, next) {
            case let (p?, n?): target = runs[p].range.count >= runs[n].range.count ? p : n
            case let (p?, nil): target = p
            case let (nil, n?): target = n
            case (nil, nil): return runs
            }
            let lower = min(runs[target].range.lowerBound, runs[shortIndex].range.lowerBound)
            let upper = max(runs[target].range.upperBound, runs[shortIndex].range.upperBound)
            runs[target].range = lower..<upper
            runs.remove(at: shortIndex)
            // Neighbours that now share a label become one run.
            var merged: [Run] = []
            for run in runs {
                if let last = merged.last, last.label == run.label {
                    merged[merged.count - 1].range = last.range.lowerBound..<run.range.upperBound
                } else {
                    merged.append(run)
                }
            }
            runs = merged
            changed = true
        }
        return runs
    }

    // MARK: Overlap

    /// Speaker with the largest overlap with `start…end`; if none overlaps, the
    /// nearest turn within one second (whisper and the diarizer disagree slightly at
    /// the edges of speech).
    static func label(for start: TimeInterval, _ end: TimeInterval, in turns: [SpeakerTurn]) -> String? {
        var totals: [String: TimeInterval] = [:]
        for turn in turns where turn.end > start && turn.start < end {
            totals[turn.label, default: 0] += min(end, turn.end) - max(start, turn.start)
        }
        if let best = totals.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }) {
            return best.key
        }
        let middle = (start + end) / 2
        let nearest = turns.min { distance(middle, $0) < distance(middle, $1) }
        if let nearest, distance(middle, nearest) <= 1.0 { return nearest.label }
        return nil
    }

    private static func distance(_ time: TimeInterval, _ turn: SpeakerTurn) -> TimeInterval {
        if time < turn.start { return turn.start - time }
        if time > turn.end { return time - turn.end }
        return 0
    }
}
