import CoreML
import Foundation
import FluidAudio

/// «Identificar hablantes»: on-device speaker diarization with FluidAudio's offline
/// pipeline (pyannote community-1 segmentation, WeSpeaker embeddings, VBx clustering,
/// Core ML). Same approach as MacWhisper's SpeakerKit, with open models.
///
/// The models (Hugging Face `FluidInference/speaker-diarization-coreml`, pinned
/// revision) are downloaded the first time a transcription asks for speakers and are
/// kept next to the whisper models. Nothing else leaves the Mac.
actor SpeakerDiarizationService {
    static let shared = SpeakerDiarizationService()

    enum Progress: Sendable {
        case downloadingModels(fraction: Double?)
        case analysing(fraction: Double?)
    }

    enum DiarizationError: LocalizedError {
        case modelsUnavailable(String)
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .modelsUnavailable(let detail): return "Speaker models unavailable: \(detail)"
            case .failed(let detail): return "Speaker detection failed: \(detail)"
            }
        }
    }

    private var manager: OfflineDiarizerManager?

    /// `~/Library/Application Support/Transcriptor/diarization`.
    nonisolated static var modelsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Transcriptor", isDirectory: true)
            .appendingPathComponent("diarization", isDirectory: true)
    }

    /// The compiled models are on disk (Settings shows «Descargado»).
    nonisolated static var areModelsDownloaded: Bool {
        let repo = modelsDirectory.appendingPathComponent(Repo.diarizer.folderName, isDirectory: true)
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: repo.path)) ?? []
        return contents.contains { $0.hasSuffix(".mlmodelc") }
    }

    /// Speaker turns for `file` (any format AVFoundation reads; resampled to 16 kHz).
    func diarize(file: URL, progress: @escaping @Sendable (Progress) -> Void) async throws -> [SpeakerTurn] {
        let manager = try await preparedManager(progress: progress)
        progress(.analysing(fraction: 0))
        let result: DiarizationResult
        do {
            result = try await manager.process(file) { done, total in
                progress(.analysing(fraction: total > 0 ? Double(done) / Double(total) : nil))
            }
        } catch {
            throw DiarizationError.failed(error.localizedDescription)
        }
        return result.segments.map {
            SpeakerTurn(start: TimeInterval($0.startTimeSeconds),
                        end: TimeInterval($0.endTimeSeconds),
                        label: $0.speakerId)
        }
    }

    private func preparedManager(progress: @escaping @Sendable (Progress) -> Void) async throws -> OfflineDiarizerManager {
        if let manager { return manager }
        let directory = Self.modelsDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !Self.areModelsDownloaded { progress(.downloadingModels(fraction: 0)) }
        let models: OfflineDiarizerModels
        do {
            models = try await OfflineDiarizerModels.load(from: directory, configuration: nil) { update in
                switch update.phase {
                case .listing, .downloading:
                    progress(.downloadingModels(fraction: update.fractionCompleted))
                case .compiling:
                    progress(.downloadingModels(fraction: nil))
                }
            }
        } catch {
            throw DiarizationError.modelsUnavailable(error.localizedDescription)
        }
        let manager = OfflineDiarizerManager(config: .default)
        manager.initialize(models: models)
        self.manager = manager
        return manager
    }

    /// Frees the Core ML models (memory pressure or when the queue is idle).
    func unload() {
        manager = nil
    }

    // MARK: Diagnostics

    /// Turned on with `defaults write <bundle id> diagnostics.speakerTurns -bool YES`.
    nonisolated static var diagnosticsEnabled: Bool {
        UserDefaults.standard.bool(forKey: "diagnostics.speakerTurns")
    }

    /// `~/Library/Application Support/Transcriptor/diagnostics`.
    nonisolated static var diagnosticsDirectory: URL {
        modelsDirectory.deletingLastPathComponent().appendingPathComponent("diagnostics", isDirectory: true)
    }

    /// Writes the raw turns, before they are assigned to the text, as
    /// `start<TAB>end<TAB>speaker` so the detector can be judged on its own.
    nonisolated static func exportDiagnostics(turns: [SpeakerTurn], source: URL) {
        guard diagnosticsEnabled else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "\(source.deletingPathExtension().lastPathComponent)-\(formatter.string(from: Date()))-turns.tsv"
        var tsv = "start\tend\tspeaker\n"
        for turn in turns {
            tsv += String(format: "%.3f\t%.3f\t%@\n", turn.start, turn.end, turn.label)
        }
        do {
            try FileManager.default.createDirectory(at: diagnosticsDirectory, withIntermediateDirectories: true)
            try tsv.write(to: diagnosticsDirectory.appendingPathComponent(name), atomically: true, encoding: .utf8)
        } catch {
            AppLogger.shared.log("Could not write speaker diagnostics: \(error.localizedDescription)", level: .error, category: .transcription)
        }
    }
}
