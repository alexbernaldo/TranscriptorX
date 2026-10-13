import XCTest
import AVFoundation
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

/// Prueba con red real (solo con TX_NET_TEST=1): descarga En vivo y transcribe en streaming un audio en español.
final class NemotronEndToEndTests: XCTestCase {
    func testDownloadAndLiveSessionSpanish() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["TX_NET_TEST"] == "1", "needs network")
        let wav = try XCTUnwrap(env["TX_NET_WAV"])
        FluidNetworkGate.lockDown()
        let id = NemotronStreamingEngine.multilingualId
        try await TranscriptionService.shared.downloadModel(id) { _ in }
        XCTAssertTrue(ModelStorageService.shared.isDownloaded(id))
        let engine = NemotronStreamingEngine.shared
        try await engine.startLiveSession(modelId: id, language: "es", chunkMs: ModelEngineSettings.nemotronChunkMs(for: id))
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: wav))
        var last = ""
        while file.framePosition < file.length {
            let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8000)!
            try file.read(into: buf, frameCount: 8000)
            last = try await engine.feed(buf)
        }
        let final = await engine.endLiveSession()
        try? "partial=\(last)\nfinal=\(final)".write(toFile: env["TX_NET_OUT"] ?? "/dev/null", atomically: true, encoding: .utf8)
        XCTAssertFalse(final.isEmpty)
    }
}
