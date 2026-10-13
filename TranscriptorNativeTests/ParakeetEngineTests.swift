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
