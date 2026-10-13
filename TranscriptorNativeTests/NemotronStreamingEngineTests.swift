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
