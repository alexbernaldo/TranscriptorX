import XCTest
@testable import TranscriptorNative

final class SpeakerAssignmentTests: XCTestCase {
    typealias Word = TranscriptionSegment.WordTimestamp

    private func turn(_ s: Double, _ e: Double, _ l: String) -> SpeakerTurn { SpeakerTurn(start: s, end: e, label: l) }

    func testWholeSegmentsTakeTheLargestOverlapAndAreNumberedByAppearance() {
        let segs = [
            TranscriptionSegment(startTime: 0, endTime: 4, text: "Hola"),
            TranscriptionSegment(startTime: 4, endTime: 8, text: "Qué tal"),
            TranscriptionSegment(startTime: 8, endTime: 12, text: "Bien"),
        ]
        let turns = [turn(0, 4.2, "S7"), turn(4.2, 8, "S2"), turn(8, 12, "S7")]
        let out = SpeakerAssignment.assign(segs, turns: turns)
        XCTAssertEqual(out.map(\.speaker), [0, 1, 0])
        XCTAssertEqual(out.map(\.id), segs.map(\.id))
    }

    func testSegmentIsSplitWhereTheSpeakerChanges() {
        let words = [
            Word(start: 0.0, end: 0.4, text: "Muchas"), Word(start: 0.5, end: 0.9, text: "gracias"),
            Word(start: 1.0, end: 1.3, text: "Marta."), Word(start: 2.0, end: 2.3, text: "Bueno,"),
            Word(start: 2.4, end: 2.8, text: "yo"), Word(start: 2.9, end: 3.4, text: "creo"),
        ]
        let seg = TranscriptionSegment(startTime: 0, endTime: 3.5, text: "Muchas gracias Marta. Bueno, yo creo", words: words)
        let out = SpeakerAssignment.assign([seg], turns: [turn(0, 1.6, "A"), turn(1.8, 3.6, "B")])
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out.map(\.text), ["Muchas gracias Marta.", "Bueno, yo creo"])
        XCTAssertEqual(out.map(\.speaker), [0, 1])
        XCTAssertEqual(out[0].id, seg.id)
        XCTAssertEqual(out[0].startTime, 0)
        XCTAssertEqual(out[0].endTime, 1.3, accuracy: 0.001)
        XCTAssertEqual(out[1].startTime, 2.0, accuracy: 0.001)
        XCTAssertEqual(out[1].endTime, 3.5)
        XCTAssertEqual(out[1].words?.count, 3)
    }

    func testSingleMisalignedWordDoesNotCreateASegment() {
        let words = (0..<5).map { Word(start: Double($0), end: Double($0) + 0.8, text: "w\($0)") }
        let seg = TranscriptionSegment(startTime: 0, endTime: 5, text: "w0 w1 w2 w3 w4", words: words)
        // Word 2 falls in B's turn: absorbed by A.
        let out = SpeakerAssignment.assign([seg], turns: [turn(0, 2, "A"), turn(2, 2.9, "B"), turn(2.9, 5, "A")])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].speaker, 0)
    }

    func testSilenceTakesTheNearestTurnWithinOneSecond() {
        XCTAssertEqual(SpeakerAssignment.label(for: 5.2, 5.4, in: [turn(0, 5, "A"), turn(8, 9, "B")]), "A")
        XCTAssertNil(SpeakerAssignment.label(for: 6.5, 6.6, in: [turn(0, 5, "A"), turn(8, 9, "B")]))
    }

    func testNoTurnsLeavesSegmentsUntouched() {
        let seg = TranscriptionSegment(startTime: 0, endTime: 1, text: "Hola", speaker: 3)
        XCTAssertEqual(SpeakerAssignment.assign([seg], turns: []).first?.speaker, 3)
    }
}

/// whisper-cli `--vad` logs (real lines from the Zoom test recording, trimmed).
final class WhisperVADTimeMapTests: XCTestCase {
    private let log = """
    whisper_vad: detected 3 speech segments
    whisper_vad: vad_segment_info: orig_start: 27.71, orig_end: 34.27, vad_start: 0.00, vad_end: 6.66
    whisper_vad: vad_segment_info: orig_start: 85.52, orig_end: 98.10, vad_start: 6.76, vad_end: 19.44
    whisper_vad: vad_segment_info: orig_start: 100.00, orig_end: 110.00, vad_start: 19.54, vad_end: 29.54
    """

    func testParsesEveryVADSegment() throws {
        let map = try XCTUnwrap(WhisperVADTimeMap(log: log))
        XCTAssertEqual(map.points.count, 6)
        XCTAssertEqual(map.points.first, .init(processed: 0, original: 27.71))
    }

    func testMapsTokenTimesBackToTheOriginalAudio() throws {
        let map = try XCTUnwrap(WhisperVADTimeMap(log: log))
        // «Hi» was token time 0.00 but is said at 27.71 in the recording.
        XCTAssertEqual(map.original(0), 27.71, accuracy: 0.001)
        // Inside the second stretch: linear between its edges.
        XCTAssertEqual(map.original(6.76 + (19.44 - 6.76) / 2), 85.52 + (98.10 - 85.52) / 2, accuracy: 0.001)
        // In the 0.1 s of silence whisper inserts, it runs across the removed gap.
        XCTAssertGreaterThan(map.original(6.70), 34.27)
        XCTAssertLessThan(map.original(6.70), 85.52)
        // Clamped outside, like whisper.cpp.
        XCTAssertEqual(map.original(-1), 27.71, accuracy: 0.001)
        XCTAssertEqual(map.original(40), 110, accuracy: 0.001)
    }

    func testWordsKeepTheirTextWhenMapped() throws {
        let map = try XCTUnwrap(WhisperVADTimeMap(log: log))
        let word = map.original(of: .init(start: 0, end: 0.8, text: " Hi"))
        XCTAssertEqual(word.text, " Hi")
        XCTAssertEqual(word.start, 27.71, accuracy: 0.001)
        XCTAssertGreaterThan(word.end, word.start)
    }

    func testNoMapWithoutVADLines() {
        XCTAssertNil(WhisperVADTimeMap(log: "whisper_print_progress: progress = 50%"))
    }
}
