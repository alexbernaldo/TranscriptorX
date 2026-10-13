import XCTest
@testable import TranscriptorNative
import FluidAudio

final class ParakeetEngineTests: XCTestCase {
    func testVersionMapping() {
        XCTAssertEqual(ParakeetEngine.asrModelVersion(for: "parakeet-tdt-0.6b-v3"), .v3)
        XCTAssertEqual(ParakeetEngine.asrModelVersion(for: "parakeet-tdt-0.6b-v2"), .v2)
        XCTAssertEqual(ParakeetEngine.asrModelVersion(for: "parakeet-ultra"), .ultra)
        XCTAssertEqual(ParakeetEngine.asrModelVersion(for: "parakeet-redux"), .redux)

        XCTAssertNil(ParakeetEngine.asrModelVersion(for: "base"))
        XCTAssertNil(ParakeetEngine.asrModelVersion(for: "large-v3-turbo"))
        XCTAssertNil(ParakeetEngine.asrModelVersion(for: "unknown-model"))
    }

    func testPlatformSupport() {
        // .v3, .v2 and .ultra supported on standard macOS
        XCTAssertNoThrow(try ParakeetEngine.checkPlatformSupport(for: .v3))
        XCTAssertNoThrow(try ParakeetEngine.checkPlatformSupport(for: .v2))
        XCTAssertNoThrow(try ParakeetEngine.checkPlatformSupport(for: .ultra))

        // .redux requires macOS 15+
        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        if major < 15 {
            XCTAssertThrowsError(try ParakeetEngine.checkPlatformSupport(for: .redux))
        } else {
            XCTAssertNoThrow(try ParakeetEngine.checkPlatformSupport(for: .redux))
        }
    }

    @MainActor
    func testModelMemoryManagerTrackingAndUnload() async {
        let manager = ModelMemoryManager.shared
        var handlerRan = false

        manager.registerUnloadHandler {
            handlerRan = true
        }

        manager.notifyModelInUse("parakeet-tdt-0.6b-v3")
        XCTAssertEqual(manager.activeModelId, "parakeet-tdt-0.6b-v3")
        XCTAssertNotNil(manager.lastActivity)

        await manager.unloadAll()

        XCTAssertNil(manager.activeModelId)
        XCTAssertNil(manager.lastActivity)
        XCTAssertTrue(handlerRan)
    }
}

/// Privacidad: FluidAudio no puede tocar la red salvo durante una descarga pedida por el usuario.
final class NoImplicitNetworkTests: XCTestCase {
    func testGateKeepsFluidAudioOfflineOutsideUserDownloads() async throws {
        FluidNetworkGate.lockDown()
        XCTAssertTrue(ModelHub.offlineMode)
        await FluidNetworkGate.withUserDownload {
            XCTAssertFalse(ModelHub.offlineMode)
        }
        XCTAssertTrue(ModelHub.offlineMode)
    }

    func testLoadingMissingParakeetModelFailsInsteadOfDownloading() async throws {
        FluidNetworkGate.lockDown()
        try XCTSkipIf(ModelStorageService.shared.isDownloaded("parakeet-redux"), "model present")
        do {
            _ = try await ParakeetEngine.shared.loadManager(for: .redux)
            XCTFail("must not load")
        } catch let e as ParakeetEngine.ParakeetError {
            if case .modelNotFound = e {} else if case .unsupportedPlatform = e {} else { XCTFail("\(e)") }
        }
    }

    func testStorageSeesFluidAudioCacheFolders() {
        XCTAssertEqual(ModelStorageService.shared.localURLs(for: "parakeet-tdt-0.6b-v3"),
                       [AsrModels.defaultCacheDirectory(for: .v3)])
        XCTAssertFalse(ModelStorageService.shared.localURLs(for: "nemotron-streaming-multilingual-0.6b").isEmpty)
    }
}

/// Prueba con red real (solo con TX_NET_TEST=1): descarga Rápido y transcribe un audio en español.
final class ParakeetEndToEndTests: XCTestCase {
    func testDownloadAndTranscribeSpanish() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["TX_NET_TEST"] == "1", "needs network")
        let wav = try XCTUnwrap(env["TX_NET_WAV"])
        FluidNetworkGate.lockDown()
        try await TranscriptionService.shared.downloadModel("parakeet-tdt-0.6b-v3") { _ in }
        XCTAssertTrue(ModelStorageService.shared.isDownloaded("parakeet-tdt-0.6b-v3"))
        var s = TranscriptionSettings.default
        s.language = "es"
        s.selectedModelId = "parakeet-tdt-0.6b-v3"
        let r = try await TranscriptionService.shared.transcribe(
            file: URL(fileURLWithPath: wav), modelId: s.selectedModelId, settings: s, onProgress: { _, _ in })
        print("PARAKEET-RESULT: \(r.plainText)")
        XCTAssertFalse(r.plainText.isEmpty)
    }
}
