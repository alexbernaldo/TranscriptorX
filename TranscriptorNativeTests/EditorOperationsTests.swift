import XCTest
@testable import TranscriptorNative

final class EditorOperationsTests: XCTestCase {
    typealias Word = TranscriptionSegment.WordTimestamp

    private func segment(_ text: String, _ start: TimeInterval, _ end: TimeInterval,
                         speaker: Int? = nil, words: [Word]? = nil) -> TranscriptionSegment {
        TranscriptionSegment(startTime: start, endTime: end, text: text, speaker: speaker, words: words)
    }

    private let words: [Word] = [
        Word(start: 0.0, end: 0.4, text: "Hola"),
        Word(start: 0.5, end: 0.9, text: "a"),
        Word(start: 1.0, end: 1.6, text: "todos"),
    ]

    // MARK: Text edit

    func testEditKeepsWordsWhenWordsUnchanged() {
        let s = segment("Hola a todos", 0, 2, words: words)
        let edited = EditorOperations.applyTextEdit(s, newText: "  Hola a todos ")
        XCTAssertEqual(edited.text, "Hola a todos")
        XCTAssertEqual(edited.words, words)
    }

    func testEditDropsWordTimestampsWhenWordsChange() {
        let s = segment("Hola a todos", 0, 2, words: words)
        let edited = EditorOperations.applyTextEdit(s, newText: "Hola a todas")
        XCTAssertEqual(edited.text, "Hola a todas")
        XCTAssertNil(edited.words)
        XCTAssertEqual(edited.originalText, "Hola a todos")
        XCTAssertEqual(edited.startTime, 0)
        XCTAssertEqual(edited.endTime, 2)
    }

    // MARK: Split

    func testSplitUsesWordTimeWhenAvailable() throws {
        let s = segment("Hola a todos", 0, 2, speaker: 1, words: words)
        let r = try XCTUnwrap(EditorOperations.split(s, atCharacterOffset: 6))
        XCTAssertFalse(r.estimated)
        XCTAssertEqual(r.left.text, "Hola a")
        XCTAssertEqual(r.right.text, "todos")
        XCTAssertEqual(r.left.endTime, 1.0)
        XCTAssertEqual(r.right.startTime, 1.0)
        XCTAssertEqual(r.right.endTime, 2)
        XCTAssertEqual(r.right.speaker, 1)
        XCTAssertEqual(r.left.words?.count, 2)
        XCTAssertEqual(r.right.words?.count, 1)
    }

    func testSplitEstimatesProportionallyWithoutWords() throws {
        let s = segment("abcdefghij", 10, 20)
        let r = try XCTUnwrap(EditorOperations.split(s, atCharacterOffset: 5))
        XCTAssertTrue(r.estimated)
        XCTAssertEqual(r.left.endTime, 15, accuracy: 0.001)
        XCTAssertEqual(r.right.startTime, 15, accuracy: 0.001)
        XCTAssertNil(r.right.words)
    }

    func testCursorOffsetConvertsUTF16ToCharacters() {
        let text = "Buenos días 👋 a todos"
        // NSTextView location after the emoji: 14 UTF-16 units, 13 characters.
        XCTAssertEqual(EditorOperations.characterOffset(utf16Offset: 14, in: text), 13)
        XCTAssertEqual(EditorOperations.characterOffset(utf16Offset: 999, in: text), text.count)
        XCTAssertEqual(EditorOperations.characterOffset(utf16Offset: -1, in: text), 0)
    }

    func testSplitRejectsEdges() {
        let s = segment("Hola", 0, 1)
        XCTAssertNil(EditorOperations.split(s, atCharacterOffset: 0))
        XCTAssertNil(EditorOperations.split(s, atCharacterOffset: 4))
        XCTAssertNil(EditorOperations.split(segment("Hola ", 0, 1), atCharacterOffset: 4))
    }

    // MARK: Merge

    func testMergeJoinsTextAndKeepsFirstSpeaker() throws {
        let a = segment("Uno", 0, 1, speaker: 0)
        var b = segment("dos", 1, 3, speaker: 1)
        b.isFavorite = true
        let m = try XCTUnwrap(EditorOperations.merge([a, b]))
        XCTAssertEqual(m.text, "Uno dos")
        XCTAssertEqual(m.startTime, 0)
        XCTAssertEqual(m.endTime, 3)
        XCTAssertEqual(m.speaker, 0)
        XCTAssertTrue(m.isFavorite)
        XCTAssertEqual(m.id, a.id)
        XCTAssertNil(EditorOperations.merge([a]))
    }

    func testMergeKeepsWordsOnlyWhenAllSegmentsHaveThem() throws {
        let a = segment("Hola", 0, 0.4, words: [words[0]])
        let b = segment("a todos", 0.5, 1.6, words: Array(words[1...]))
        XCTAssertEqual(try XCTUnwrap(EditorOperations.merge([a, b])).words, words)
        let c = segment("sin palabras", 2, 3)
        XCTAssertNil(try XCTUnwrap(EditorOperations.merge([b, c])).words)
    }

    func testConsecutiveAndMixedSpeakers() {
        let segs = [segment("a", 0, 1, speaker: 0), segment("b", 1, 2, speaker: 0), segment("c", 2, 3, speaker: 1)]
        XCTAssertTrue(EditorOperations.areConsecutive([segs[0].id, segs[1].id], in: segs))
        XCTAssertFalse(EditorOperations.areConsecutive([segs[0].id, segs[2].id], in: segs))
        XCTAssertFalse(EditorOperations.areConsecutive([segs[0].id], in: segs))
        XCTAssertFalse(EditorOperations.hasMixedSpeakers([segs[0].id, segs[1].id], in: segs))
        XCTAssertTrue(EditorOperations.hasMixedSpeakers([segs[1].id, segs[2].id], in: segs))
    }

    // MARK: Times

    func testValidateTimes() {
        let prev = segment("p", 0, 5)
        let next = segment("n", 10, 12)
        XCTAssertEqual(EditorOperations.validate(start: 5, end: 10, previous: prev, next: next), .ok)
        XCTAssertEqual(EditorOperations.validate(start: 6, end: 6, previous: prev, next: next), .startNotBeforeEnd)
        XCTAssertEqual(EditorOperations.validate(start: 4, end: 8, previous: prev, next: next), .overlapsPrevious(previousEnd: 5))
        XCTAssertEqual(EditorOperations.validate(start: 6, end: 11, previous: prev, next: next), .overlapsNext(nextStart: 10))
    }

    func testParseTime() throws {
        XCTAssertEqual(try XCTUnwrap(EditorOperations.parseTime("00:01:12,400")), 72.4, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(EditorOperations.parseTime("1:12.4")), 72.4, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(EditorOperations.parseTime(" 72.4 ")), 72.4, accuracy: 0.0001)
        XCTAssertNil(EditorOperations.parseTime("abc"))
        XCTAssertNil(EditorOperations.parseTime("1:2:3:4"))
        XCTAssertNil(EditorOperations.parseTime("-3"))
    }

    // MARK: Find and replace

    func testFindIsCaseAndDiacriticInsensitiveByDefault() {
        let segs = [segment("Canción y cancion", 0, 1), segment("CANCIÓN", 1, 2)]
        XCTAssertEqual(EditorOperations.findMatches("cancion", in: segs, caseSensitive: false, wholeWord: false).count, 3)
        XCTAssertEqual(EditorOperations.findMatches("cancion", in: segs, caseSensitive: true, wholeWord: false).count, 1)
    }

    func testFindWholeWord() {
        let segs = [segment("el elefante y el", 0, 1)]
        XCTAssertEqual(EditorOperations.findMatches("el", in: segs, caseSensitive: false, wholeWord: false).count, 3)
        XCTAssertEqual(EditorOperations.findMatches("el", in: segs, caseSensitive: false, wholeWord: true).count, 2)
        XCTAssertTrue(EditorOperations.findMatches("", in: segs, caseSensitive: false, wholeWord: false).isEmpty)
    }

    func testReplaceAllInsideOneSegment() {
        let s = segment("uno dos uno", 0, 1)
        let matches = EditorOperations.findMatches("uno", in: [s], caseSensitive: false, wholeWord: true)
        XCTAssertEqual(EditorOperations.replacing(matches, in: s.text, with: "tres"), "tres dos tres")
    }

    // MARK: Speakers

    func testMergeSpeakerCompactsIndicesAndNames() {
        let segs = [segment("a", 0, 1, speaker: 0), segment("b", 1, 2, speaker: 1), segment("c", 2, 3, speaker: 2)]
        let (merged, names) = EditorOperations.mergeSpeaker(1, into: 0, segments: segs,
                                                           names: ["0": "Marta", "1": "Luis", "2": "Ana"])
        XCTAssertEqual(merged.map(\.speaker), [0, 0, 1])
        XCTAssertEqual(names, ["0": "Marta", "1": "Ana"])
    }

    // MARK: Playback lookups

    func testSegmentAndWordLookup() {
        let segs = [segment("a", 0, 2), segment("b", 3, 5), segment("c", 10, 12)]
        XCTAssertEqual(EditorOperations.segmentIndex(at: 1, in: segs), 0)
        XCTAssertEqual(EditorOperations.segmentIndex(at: 4, in: segs), 1)
        XCTAssertNil(EditorOperations.segmentIndex(at: 7, in: segs))
        XCTAssertNil(EditorOperations.segmentIndex(at: 1, in: []))
        XCTAssertEqual(EditorOperations.wordIndex(at: 0.6, in: words), 1)
        XCTAssertEqual(EditorOperations.wordIndex(at: 0.95, in: words), 1)
        XCTAssertNil(EditorOperations.wordIndex(at: 3, in: words))
    }

    func testWordRanges() {
        let text = "  Hola   a todos "
        XCTAssertEqual(EditorOperations.wordRanges(in: text).map { String(text[$0]) }, ["Hola", "a", "todos"])
    }
}
