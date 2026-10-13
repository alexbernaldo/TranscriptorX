import XCTest
@testable import TranscriptorNative
import FluidAudio

final class NemotronStreamingEngineTests: XCTestCase {
    func testPlatformSupport() {
        if SystemInfo.isAppleSilicon {
            XCTAssertNoThrow(try NemotronStreamingEngine.checkPlatformSupport())
        }
    }

    func testNemotronLanguages() {
        let expected: Set<String> = ["en", "es", "fr", "it", "pt", "de", "zh", "ja"]
        XCTAssertEqual(ModelCatalog.languagesNemotronMultilingual, expected)

        // Verificamos que español está soportado
        XCTAssertTrue(ModelCatalog.languagesNemotronMultilingual.contains("es"))
        // Verificamos que otros idiomas quedan fuera de los 8
        XCTAssertFalse(ModelCatalog.languagesNemotronMultilingual.contains("ko"))
        XCTAssertFalse(ModelCatalog.languagesNemotronMultilingual.contains("ru"))
    }

    func testLiveCaptionAvailabilityRules() {
        // En español o auto: disponible
        let esAvailable = ModelCatalog.languagesNemotronMultilingual.contains("es")
        XCTAssertTrue(esAvailable)

        // En ruso o coreano: no disponible
        let ruAvailable = ModelCatalog.languagesNemotronMultilingual.contains("ru")
        XCTAssertFalse(ruAvailable)
    }

    @MainActor
    func testNemotronMemoryUnloadHandler() async {
        let manager = ModelMemoryManager.shared
        manager.notifyModelInUse("nemotron-streaming-multilingual-0.6b")
        XCTAssertEqual(manager.activeModelId, "nemotron-streaming-multilingual-0.6b")

        await manager.unloadAll()
        XCTAssertNil(manager.activeModelId)
    }
}

final class NemotronNoImplicitDownloadTests: XCTestCase {
    func testLiveSessionWithoutModelFailsWithoutNetwork() async throws {
        FluidNetworkGate.lockDown()
        try XCTSkipIf(NemotronStreamingEngine.installedVariant(modelId: NemotronStreamingEngine.multilingualId, chunkMs: 1120) != nil)
        do {
            try await NemotronStreamingEngine.shared.startLiveSession(
                modelId: NemotronStreamingEngine.multilingualId, language: "es", chunkMs: 1120)
            XCTFail("must not load")
        } catch let e as NemotronStreamingEngine.NemotronError {
            guard case .modelNotFound = e else { return XCTFail("\(e)") }
        }
    }

    func testEnglishModelHasNo4480Tier() {
        XCTAssertFalse(NemotronStreamingEngine.supportedChunks(modelId: NemotronStreamingEngine.englishId).contains(4480))
        XCTAssertTrue(NemotronStreamingEngine.supportedChunks(modelId: NemotronStreamingEngine.multilingualId).contains(4480))
    }
}
