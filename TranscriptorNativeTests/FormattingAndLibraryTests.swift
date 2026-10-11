import XCTest
@testable import TranscriptorNative

final class FormattingTests: XCTestCase {
    func testTimestampSwitchesToHoursForLongDocuments() {
        XCTAssertEqual(TXFormat.timestamp(72, documentDuration: 600), "01:12")
        XCTAssertEqual(TXFormat.timestamp(72, documentDuration: 4000), "0:01:12")
        XCTAssertEqual(TXFormat.timestamp(-3, documentDuration: 10), "00:00")
    }

    func testPreciseAndClock() {
        XCTAssertEqual(TXFormat.precise(72.4), "00:01:12,400")
        XCTAssertEqual(TXFormat.clock(724), "12:04")
        XCTAssertEqual(TXFormat.clock(3724), "1:02:04")
    }

    func testDurations() {
        XCTAssertEqual(TXFormat.shortDuration(38), "38 s")
        XCTAssertEqual(TXFormat.shortDuration(42 * 60), "42 min")
        XCTAssertEqual(TXFormat.shortDuration(3600 + 5 * 60), "1 h 5 min")
        XCTAssertEqual(TXFormat.shortDuration(7200), "2 h")
        XCTAssertEqual(TXFormat.longDuration(42 * 60 + 10), "42 min 10 s")
    }

    /// Regression: a plural format whose extra argument is a string must use `%2$@`
    /// (the count is always the first argument).
    func testPluralFormatReceivesCountFirst() {
        XCTAssertEqual(TXL.n("tests.missing.key", "%d hablante", "%d hablantes", 1), "1 hablante")
        XCTAssertEqual(TXL.n("tests.missing.key", "%d hablante", "%d hablantes", 3), "3 hablantes")
        XCTAssertEqual(TXL.n("tests.missing.key", "%d de %2$@", "%d de %2$@", 2, "Marta"), "2 de Marta")
    }

    func testMissingKeyFallsBackToSpecText() {
        XCTAssertEqual(TXL.t("tests.missing.key", "Texto de la especificación"), "Texto de la especificación")
    }
}

final class LibraryTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Madrid")!
        return c
    }()

    private func item(_ title: String, _ date: Date) -> HistoryItem {
        HistoryItem(Transcription(title: title, text: "", createdAt: date))
    }

    @MainActor
    func testHistoryGroupsTodayYesterdayWeekAndMonths() {
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 10))!
        func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: now)! }
        let items = [item("a", day(-1)), item("b", now), item("c", day(-3)), item("d", day(-40)), item("e", day(-41))]
        let sections = LibraryStore.group(items, now: now, calendar: calendar)
        XCTAssertEqual(sections.map(\.id), ["today", "yesterday", "week", "m2026-9"])
        XCTAssertEqual(sections.map { $0.items.map(\.title) }, [["b"], ["a"], ["c"], ["d", "e"]])
    }

    func testSearchExcerptCountsMatchesInTitleAndText() {
        let text = String(repeating: "relleno ", count: 20) + "la Reunión empieza; otra reunion después"
        let (snippet, ranges, count) = LibraryStore.excerpt(text: text, title: "Reunión semanal", query: "reunion")
        XCTAssertEqual(count, 3)
        XCTAssertTrue(snippet.hasPrefix("…"))
        XCTAssertEqual(ranges.count, 2)
        XCTAssertEqual(snippet[ranges[0]].lowercased(), "reunión")
    }

    func testTrashDaysLeft() {
        let fresh = TrashItem(id: UUID(), title: "x", deletedAt: Date(), retentionDays: 30)
        XCTAssertEqual(fresh.daysLeft, 30)
        let expired = TrashItem(id: UUID(), title: "x", deletedAt: Date().addingTimeInterval(-40 * 86_400), retentionDays: 30)
        XCTAssertEqual(expired.daysLeft, 0)
    }
}

final class ExportOptionsTests: XCTestCase {
    func testOptionsOfferedPerFormat() {
        XCTAssertEqual(ExportKindOptions.available(for: .srt), [.speakerNames, .favoritesOnly])
        XCTAssertEqual(ExportKindOptions.available(for: .avid), [.favoritesOnly, .fps])
        XCTAssertTrue(ExportKindOptions.available(for: .project).isEmpty)
        XCTAssertTrue(ExportKindOptions.available(for: .txt).contains(.style))
    }

    func testOptionsRoundTripThroughCodable() throws {
        var o = ExportKindOptions()
        o.fps = 30
        o.favoritesOnly = true
        let decoded = try JSONDecoder().decode(ExportKindOptions.self, from: JSONEncoder().encode(o))
        XCTAssertEqual(decoded, o)
    }
}

final class JobEqualityTests: XCTestCase {
    /// Views take `job` as input; equality must change when the visible state changes.
    func testStatusChangeMakesJobsDifferent() {
        let job = TranscriptionJob(fileURL: URL(fileURLWithPath: "/tmp/a.m4a"), fileName: "a.m4a",
                                   settings: QuickSettingsModel.defaultSettings())
        var processing = job
        processing.markProcessing()
        XCTAssertNotEqual(job, processing)
        var progressed = processing
        progressed.updateProgress(40, message: "")
        XCTAssertNotEqual(processing, progressed)
        XCTAssertEqual(job, job)
    }
}

final class DisplayPathTests: XCTestCase {
    func testHomeIsAbbreviatedOnlyAsPrefix() {
        XCTAssertEqual(TXFormat.displayPath("/Users/ana/Media/a.m4a", home: "/Users/ana"), "~/Media/a.m4a")
        XCTAssertEqual(TXFormat.displayPath("/Users/ana", home: "/Users/ana/"), "~")
        XCTAssertEqual(TXFormat.displayPath("/private/var/h/Media/a.m4a", home: "/var/h"), "/private/var/h/Media/a.m4a")
        XCTAssertEqual(TXFormat.displayPath("/Users/anabel/a.m4a", home: "/Users/ana"), "/Users/anabel/a.m4a")
    }
}

final class DictationTextTests: XCTestCase {
    func testRemovesHesitationsThatAreNeverWords() {
        XCTAssertEqual(DictationText.clean("Uhm, I think, uh, we should go", language: "auto", removeFillers: true),
                       "I think, we should go")
    }

    func testLanguageGatedFillersNeedTheLanguage() {
        // «eh» is only removed when the dictation is known to be Spanish or English.
        XCTAssertEqual(DictationText.clean("Eh, bueno, vamos", language: "es", removeFillers: true), "Bueno, vamos")
        XCTAssertEqual(DictationText.clean("Eh, bueno, vamos", language: "auto", removeFillers: true), "Eh, bueno, vamos")
    }

    func testFillerAtTheEndKeepsTheFullStop() {
        XCTAssertEqual(DictationText.clean("Lo dijo, eh.", language: "es", removeFillers: true), "Lo dijo.")
    }

    func testStuttersCollapseFromThreeRepeats() {
        XCTAssertEqual(DictationText.clean("I I I think so", language: "en", removeFillers: true), "I think so")
        XCTAssertEqual(DictationText.clean("muy muy bien", language: "es", removeFillers: true), "muy muy bien")
    }

    func testNonSpeechAnnotationsAreAlwaysRemoved() {
        XCTAssertEqual(DictationText.clean("[BLANK_AUDIO] Hola (música) mundo", language: "es", removeFillers: false), "Hola mundo")
    }

    func testNothingIsRemovedWhenTurnedOff() {
        XCTAssertEqual(DictationText.clean("uh vale", language: "es", removeFillers: false), "uh vale")
    }
}

final class DictationShortcutTests: XCTestCase {
    func testDisplayName() {
        XCTAssertTrue(DictationShortcut.standard.displayName.hasPrefix("⌃⌥ "))
        XCTAssertEqual(DictationShortcut(keyCode: 96, modifiers: 0).displayName, "F5")
    }

    func testPlainLettersCannotBeGlobalShortcuts() throws {
        let plain = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                    windowNumber: 0, context: nil, characters: "d",
                                                    charactersIgnoringModifiers: "d", isARepeat: false, keyCode: 2))
        XCTAssertNil(DictationShortcut(event: plain))
        let shifted = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.shift], timestamp: 0,
                                                      windowNumber: 0, context: nil, characters: "D",
                                                      charactersIgnoringModifiers: "d", isARepeat: false, keyCode: 2))
        XCTAssertNil(DictationShortcut(event: shifted))
        let command = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0,
                                                      windowNumber: 0, context: nil, characters: "d",
                                                      charactersIgnoringModifiers: "d", isARepeat: false, keyCode: 2))
        XCTAssertEqual(DictationShortcut(event: command)?.displayName, "⇧⌘ D")
    }
}
