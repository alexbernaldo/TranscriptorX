import Foundation

/// Pure document operations used by the editor (no UI, no persistence) so they can be tested.
enum EditorOperations {

    // MARK: Text edit (spec 7.6)

    /// Applies a text edit. Keeps the original text and history; drops word timestamps
    /// when the words changed, so that segment loses word highlighting but keeps its bar.
    static func applyTextEdit(_ segment: TranscriptionSegment, newText: String) -> TranscriptionSegment {
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != segment.text else { return segment }
        var updated = segment.withText(trimmed)
        if let words = segment.words, !wordsMatch(words, text: trimmed) {
            updated.words = nil
        }
        return updated
    }

    static func normalizedWords(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).map { String($0) }
    }

    static func wordsMatch(_ words: [TranscriptionSegment.WordTimestamp], text: String) -> Bool {
        let a = words.map { $0.text.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return a == normalizedWords(text)
    }

    // MARK: Split (spec 7.10)

    struct SplitResult {
        let left: TranscriptionSegment
        let right: TranscriptionSegment
        /// The new start time was estimated by character proportion (shown with «≈»).
        let estimated: Bool
    }

    /// Splits `segment` at a character offset of its text.
    static func split(_ segment: TranscriptionSegment, atCharacterOffset offset: Int) -> SplitResult? {
        let text = segment.text
        guard offset > 0, offset < text.count else { return nil }
        let cut = text.index(text.startIndex, offsetBy: offset)
        let leftText = String(text[..<cut]).trimmingCharacters(in: .whitespacesAndNewlines)
        let rightText = String(text[cut...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !leftText.isEmpty, !rightText.isEmpty else { return nil }

        var splitTime: TimeInterval
        var estimated = true
        var leftWords: [TranscriptionSegment.WordTimestamp]?
        var rightWords: [TranscriptionSegment.WordTimestamp]?

        if let words = segment.words, wordsMatch(words, text: text), !words.isEmpty {
            // First word after the cursor gives the exact time.
            let leftCount = normalizedWords(leftText).count
            if leftCount > 0, leftCount < words.count {
                splitTime = words[leftCount].start
                leftWords = Array(words[..<leftCount])
                rightWords = Array(words[leftCount...])
                estimated = false
            } else {
                splitTime = proportional(segment, offset: offset)
            }
        } else {
            splitTime = proportional(segment, offset: offset)
        }
        let span = segment.endTime - segment.startTime
        let margin = min(0.05, span / 4)
        splitTime = min(max(splitTime, segment.startTime + margin), segment.endTime - margin)

        var left = segment.withText(leftText)
        left.endTime = splitTime
        left.words = leftWords
        let right = TranscriptionSegment(
            startTime: splitTime, endTime: segment.endTime, text: rightText,
            speaker: segment.speaker, isFavorite: segment.isFavorite, words: rightWords
        )
        return SplitResult(left: left, right: right, estimated: estimated)
    }

    /// NSTextView cursor locations are UTF-16 offsets; `split` works in characters.
    static func characterOffset(utf16Offset: Int, in text: String) -> Int {
        let clamped = min(max(utf16Offset, 0), text.utf16.count)
        let index = String.Index(utf16Offset: clamped, in: text)
        return text.distance(from: text.startIndex, to: index)
    }

    private static func proportional(_ s: TranscriptionSegment, offset: Int) -> TimeInterval {
        let ratio = Double(offset) / Double(max(s.text.count, 1))
        return s.startTime + (s.endTime - s.startTime) * ratio
    }

    // MARK: Merge (spec 7.10)

    /// Indices must be consecutive among the visible segments.
    static func areConsecutive(_ ids: Set<UUID>, in visible: [TranscriptionSegment]) -> Bool {
        let positions = visible.indices.filter { ids.contains(visible[$0].id) }
        guard positions.count >= 2 else { return false }
        return positions.last! - positions.first! == positions.count - 1
    }

    static func hasMixedSpeakers(_ ids: Set<UUID>, in visible: [TranscriptionSegment]) -> Bool {
        Set(visible.filter { ids.contains($0.id) }.map { $0.speaker ?? -1 }).count > 1
    }

    /// Start of the first, end of the last, texts joined with a space; speaker of the first.
    static func merge(_ segments: [TranscriptionSegment]) -> TranscriptionSegment? {
        guard let first = segments.first, let last = segments.last, segments.count >= 2 else { return nil }
        let text = segments.map(\.text).joined(separator: " ")
        var merged = first.withText(text)
        merged.endTime = last.endTime
        merged.isFavorite = segments.contains { $0.isFavorite }
        let allWords = segments.compactMap(\.words)
        merged.words = allWords.count == segments.count ? allWords.flatMap { $0 } : nil
        return merged
    }

    // MARK: Times (spec 7.11)

    enum TimeValidation: Equatable {
        case ok
        case startNotBeforeEnd
        case overlapsPrevious(previousEnd: TimeInterval)
        case overlapsNext(nextStart: TimeInterval)
    }

    static func validate(start: TimeInterval, end: TimeInterval,
                         previous: TranscriptionSegment?, next: TranscriptionSegment?) -> TimeValidation {
        guard start < end else { return .startNotBeforeEnd }
        if let previous, start < previous.endTime - 0.0005 { return .overlapsPrevious(previousEnd: previous.endTime) }
        if let next, end > next.startTime + 0.0005 { return .overlapsNext(nextStart: next.startTime) }
        return .ok
    }

    /// Parses «00:01:12,400», «1:12.4», «72.4».
    static func parseTime(_ string: String) -> TimeInterval? {
        let s = string.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let parts = s.split(separator: ":").map(String.init)
        guard !parts.isEmpty, parts.count <= 3 else { return nil }
        var total: Double = 0
        for part in parts {
            guard let v = Double(part), v >= 0 else { return nil }
            total = total * 60 + v
        }
        return total
    }

    // MARK: Find (spec 7.9)

    struct Match: Equatable {
        let segmentId: UUID
        let range: Range<String.Index>
    }

    static func findMatches(_ query: String, in segments: [TranscriptionSegment],
                            caseSensitive: Bool, wholeWord: Bool) -> [Match] {
        guard !query.isEmpty else { return [] }
        var result: [Match] = []
        var options: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive, .diacriticInsensitive]
        options.insert(.literal)
        for segment in segments {
            let text = segment.text
            var searchRange = text.startIndex..<text.endIndex
            while let r = text.range(of: query, options: options, range: searchRange) {
                if !wholeWord || isWholeWord(r, in: text) {
                    result.append(Match(segmentId: segment.id, range: r))
                }
                searchRange = r.upperBound..<text.endIndex
                if r.isEmpty { break }
            }
        }
        return result
    }

    private static func isWholeWord(_ r: Range<String.Index>, in text: String) -> Bool {
        let before = r.lowerBound > text.startIndex ? text[text.index(before: r.lowerBound)] : " "
        let after = r.upperBound < text.endIndex ? text[r.upperBound] : " "
        return !(before.isLetter || before.isNumber) && !(after.isLetter || after.isNumber)
    }

    /// Replaces the given matches (all inside one segment's text), from last to first.
    static func replacing(_ matches: [Match], in text: String, with replacement: String) -> String {
        var result = text
        for m in matches.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            result.replaceSubrange(m.range, with: replacement)
        }
        return result
    }

    // MARK: Speakers (spec 6.11)

    /// Moves every segment of `from` to `into` and compacts indices; returns segments and names.
    static func mergeSpeaker(_ from: Int, into target: Int, segments: [TranscriptionSegment],
                             names: [String: String]) -> ([TranscriptionSegment], [String: String]) {
        var segs = segments
        for i in segs.indices where segs[i].speaker == from { segs[i].speaker = target }
        var order: [Int] = []
        for s in segs.compactMap(\.speaker) where !order.contains(s) { order.append(s) }
        order.sort()
        let remap = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        for i in segs.indices { if let s = segs[i].speaker { segs[i].speaker = remap[s] } }
        var newNames: [String: String] = [:]
        for (key, value) in names {
            guard let old = Int(key), old != from, let new = remap[old] else { continue }
            newNames["\(new)"] = value
        }
        return (segs, newNames)
    }

    // MARK: Playback lookups

    /// Index of the segment containing `time` (binary search on start times).
    static func segmentIndex(at time: TimeInterval, in segments: [TranscriptionSegment]) -> Int? {
        guard !segments.isEmpty else { return nil }
        var lo = 0, hi = segments.count - 1, found = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if segments[mid].startTime <= time { found = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        guard found >= 0 else { return nil }
        return time <= segments[found].endTime + 0.25 ? found : nil
    }

    static func wordIndex(at time: TimeInterval, in words: [TranscriptionSegment.WordTimestamp]) -> Int? {
        var lo = 0, hi = words.count - 1, found = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if words[mid].start <= time { found = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        guard found >= 0, time <= words[found].end + 0.15 else { return nil }
        return found
    }

    /// Character ranges of each word in `text` (aligned with `words` when they match).
    static func wordRanges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var i = text.startIndex
        while i < text.endIndex {
            while i < text.endIndex, text[i].isWhitespace { i = text.index(after: i) }
            let start = i
            while i < text.endIndex, !text[i].isWhitespace { i = text.index(after: i) }
            if start < i { ranges.append(start..<i) }
        }
        return ranges
    }
}
