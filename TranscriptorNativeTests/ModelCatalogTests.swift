import XCTest
import SQLite3
@testable import TranscriptorNative

final class ModelResolverTests: XCTestCase {
    private let all: Set<String> = Set(ModelCatalog.all.map(\.id))

    private func ctx(installed: Set<String>? = nil, os: Int = 15, lang: String? = "es", translate: Bool = false) -> ModelResolverContext {
        ModelResolverContext(installed: installed ?? all, osMajor: os, language: lang, translateToEnglish: translate)
    }

    // MARK: Automático

    func testFilesAutomaticUsesFastForParakeetLanguages() {
        for task in [ModelTask.files, .recording] {
            XCTAssertEqual(ModelResolver.resolve(task: task, assignment: .automatic, in: ctx(lang: "es")).model?.id, ModelResolver.fast)
        }
    }

    func testFilesAutomaticFallsBackToTurboForOtherLanguages() {
        XCTAssertEqual(ModelResolver.resolve(task: .files, assignment: .automatic, in: ctx(lang: "ja")).model?.id, ModelResolver.turbo)
    }

    func testUnknownLanguageIsTreatedAsParakeetAutoDetect() {
        XCTAssertEqual(ModelResolver.resolve(task: .files, assignment: .automatic, in: ctx(lang: "auto")).model?.id, ModelResolver.fast)
        XCTAssertEqual(ModelResolver.resolve(task: .files, assignment: .automatic, in: ctx(lang: nil)).model?.id, ModelResolver.fast)
    }

    func testTranslateForcesWhisper() {
        let r = ModelResolver.resolve(task: .files, assignment: .automatic, in: ctx(lang: "es", translate: true))
        XCTAssertEqual(r.model?.engine, .whisper)
    }

    func testLiveAutomaticUsesNemotronMultilingualWithinItsEightLanguages() {
        XCTAssertEqual(ModelResolver.resolve(task: .liveCaptions, assignment: .automatic, in: ctx(lang: "es")).model?.id, ModelResolver.live)
    }

    func testLiveAutomaticHasNoModelOutsideEightLanguages() {
        let r = ModelResolver.resolve(task: .liveCaptions, assignment: .automatic, in: ctx(lang: "ru"))
        XCTAssertNil(r.model)
        XCTAssertEqual(r.notice, .noLiveModel(language: "ru"))
    }

    func testDictationChainFastThenTurboThenFilesModel() {
        XCTAssertEqual(ModelResolver.resolve(task: .dictation, assignment: .automatic, in: ctx()).model?.id, ModelResolver.fast)
        let noFast = all.subtracting([ModelResolver.fast])
        XCTAssertEqual(ModelResolver.resolve(task: .dictation, assignment: .automatic, in: ctx(installed: noFast)).model?.id, ModelResolver.turbo)
        let onlySmall: Set<String> = ["small"]
        let r = ModelResolver.resolve(task: .dictation, assignment: .automatic, filesAssignment: .model("small"), in: ctx(installed: onlySmall))
        XCTAssertEqual(r.model?.id, "small")
        XCTAssertEqual(r.needsDownload?.id, ModelResolver.fast)
    }

    // MARK: Explícito

    func testExplicitCompatibleInstalledWins() {
        let r = ModelResolver.resolve(task: .files, assignment: .model("medium"), in: ctx())
        XCTAssertEqual(r.model?.id, "medium"); XCTAssertNil(r.notice)
    }

    func testExplicitIncompatibleLanguageFallsBackWithNotice() {
        let r = ModelResolver.resolve(task: .files, assignment: .model(ModelResolver.fast), in: ctx(lang: "ja"))
        XCTAssertEqual(r.model?.id, ModelResolver.turbo)
        XCTAssertEqual(r.notice, .incompatible(requested: ModelResolver.fast, used: ModelResolver.turbo, reason: .language))
    }

    func testEnglishOnlyModelBlocksOtherLanguages() {
        let v2 = ModelCatalog.descriptor(id: "parakeet-tdt-0.6b-v2")!
        XCTAssertEqual(ModelResolver.incompatibility(of: v2, task: .files, in: ctx(lang: "es")), .language)
        XCTAssertNil(ModelResolver.incompatibility(of: v2, task: .files, in: ctx(lang: "en")))
    }

    func testNotDownloadedIsNeverSilent() {
        let installed: Set<String> = ["base"]
        let r = ModelResolver.resolve(task: .files, assignment: .model("large-v3"), in: ctx(installed: installed))
        XCTAssertEqual(r.needsDownload?.id, "large-v3")
        XCTAssertEqual(r.model?.id, "base")
        XCTAssertEqual(r.notice, .notDownloaded(requested: "large-v3", used: "base"))
    }

    func testNoModelsInstalledOffersDownload() {
        let r = ModelResolver.resolve(task: .files, assignment: .automatic, in: ctx(installed: []))
        XCTAssertNil(r.model); XCTAssertEqual(r.needsDownload?.id, ModelResolver.fast)
    }

    func testLiveTaskRejectsBatchModelsAndBatchTasksRejectStreaming() {
        let turbo = ModelCatalog.descriptor(id: "large-v3-turbo")!
        let live = ModelCatalog.descriptor(id: ModelResolver.live)!
        XCTAssertEqual(ModelResolver.incompatibility(of: turbo, task: .liveCaptions, in: ctx()), .notRealtime)
        XCTAssertEqual(ModelResolver.incompatibility(of: live, task: .files, in: ctx()), .notRealtime)
    }

    func testOldOSIsDisabledNotHidden() {
        let m = ModelCatalog.descriptor(id: "large-v3")!
        XCTAssertNil(ModelResolver.incompatibility(of: m, task: .files, in: ctx(os: 14)))
        var bumped = m
        bumped = ModelDescriptor(id: m.id, engine: m.engine, nameKey: m.nameKey, nameDefault: m.nameDefault,
                                 subtitleKey: m.subtitleKey, subtitleDefault: m.subtitleDefault, group: m.group,
                                 languages: m.languages, capabilities: { var c = m.capabilities; c.minOSMajor = 15; return c }(),
                                 sourceRepo: m.sourceRepo, license: m.license, attribution: nil, scales: m.scales,
                                 capabilityBadgeKey: nil, capabilityBadgeDefault: nil)
        XCTAssertEqual(ModelResolver.incompatibility(of: bumped, task: .files, in: ctx(os: 14)), .needsOS(15))
        XCTAssertTrue(ModelCatalog.visible(showExperimental: false).contains { $0.id == m.id })
    }
}

final class ModelCatalogTests: XCTestCase {
    func testIDsAreUniqueAndPersistentLegacyIDsExist() {
        let ids = ModelCatalog.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        for legacy in ["tiny", "base", "small", "medium", "large-v3-turbo", "large-v2", "large-v3"] {
            XCTAssertNotNil(ModelCatalog.descriptor(id: legacy), legacy)
        }
    }

    func testLookupByNameIsCaseAndAccentInsensitive() {
        XCTAssertEqual(ModelCatalog.descriptor(matching: "turbo")?.id, "large-v3-turbo")
        XCTAssertEqual(ModelCatalog.descriptor(matching: "MÁXIMA PRECISION")?.id, "large-v3")
        XCTAssertEqual(ModelCatalog.descriptor(matching: "Large-V3-Turbo")?.id, "large-v3-turbo")
        XCTAssertNil(ModelCatalog.descriptor(matching: "nope"))
    }

    func testExperimentalHiddenUnlessEnabled() {
        XCTAssertTrue(ModelCatalog.visible(showExperimental: false).allSatisfy { $0.group != .experimental })
    }

    func testLiveTaskListsOnlyStreamingModels() {
        let live = ModelCatalog.eligible(for: .liveCaptions, showExperimental: true)
        XCTAssertFalse(live.isEmpty)
        XCTAssertTrue(live.allSatisfy(\.supportsStreaming))
        XCTAssertTrue(ModelCatalog.eligible(for: .files, showExperimental: true).allSatisfy { !$0.supportsStreaming })
    }

    func testRecommendedComeFirstAndScalesInRange() {
        XCTAssertEqual(ModelCatalog.visible(showExperimental: false).first?.group, .recommended)
        for m in ModelCatalog.all {
            XCTAssertTrue((1...5).contains(m.scales.speed) && (1...5).contains(m.scales.accuracy), m.id)
        }
    }

    func testAssignmentStorageRoundTrip() {
        XCTAssertEqual(ModelAssignment(storage: nil), .automatic)
        XCTAssertEqual(ModelAssignment(storage: "auto"), .automatic)
        XCTAssertEqual(ModelAssignment(storage: ModelAssignment.model("base").storage), .model("base"))
    }
}

final class TranscriptionSchemaTests: XCTestCase {
    private func openOldDatabase() -> OpaquePointer {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(":memory:", &db), SQLITE_OK)
        sqlite3_exec(db, """
        CREATE TABLE transcriptions (
            id TEXT PRIMARY KEY, payload TEXT NOT NULL, title TEXT NOT NULL,
            created_at REAL NOT NULL, duration REAL NOT NULL,
            is_favorite INTEGER NOT NULL, language TEXT NOT NULL, deleted_at REAL);
        INSERT INTO transcriptions VALUES ('1','{}','Viejo',0,1,0,'es',NULL);
        """, nil, nil, nil)
        return db!
    }

    func testMigrationAddsColumnsKeepsRowsAndIsIdempotent() {
        let db = openOldDatabase(); defer { sqlite3_close(db) }
        XCTAssertTrue(TranscriptionSchema.migrate(db))
        XCTAssertTrue(TranscriptionSchema.migrate(db))   // segunda vez: no falla ni duplica
        let cols = TranscriptionSchema.columns(of: "transcriptions", in: db)
        XCTAssertTrue(cols.contains("model_id") && cols.contains("engine"))
        XCTAssertEqual(TranscriptionSchema.userVersion(in: db), TranscriptionSchema.currentVersion)
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT title, model_id FROM transcriptions;", -1, &stmt, nil)
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)
        XCTAssertEqual(String(cString: sqlite3_column_text(stmt, 0)), "Viejo")
        XCTAssertEqual(sqlite3_column_type(stmt, 1), SQLITE_NULL)   // «Desconocido»
        sqlite3_finalize(stmt)
    }

    func testLegacyPayloadWithoutModelFieldsStillDecodes() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","title":"t","text":"x","language":"es","duration":1,"createdAt":"2025-01-01T00:00:00Z","isFavorite":false}"#
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        let t = try d.decode(Transcription.self, from: Data(json.utf8))
        XCTAssertNil(t.modelId); XCTAssertNil(t.engine)
    }
}
