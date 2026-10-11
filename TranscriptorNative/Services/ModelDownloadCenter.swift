import Foundation

/// Serialises whisper model downloads (the engine supports one URLSession download at a time),
/// publishes real byte progress and lets the queue know when a waited-for model arrives.
@MainActor
final class ModelDownloadCenter: ObservableObject {
    static let shared = ModelDownloadCenter()

    enum State: Equatable {
        case downloading(received: Int64, total: Int64)
        case pending
        case failed(String)
    }

    @Published private(set) var states: [String: State] = [:]
    /// Bumped whenever a model finishes downloading, so lists re-read disk state.
    @Published private(set) var revision = 0

    private var queue: [String] = []
    private var running: String?
    private var cancelRequested: Set<String> = []

    private let service = TranscriptionService.shared

    func isDownloaded(_ modelId: String) -> Bool {
        service.isModelDownloaded(modelId)
    }

    func state(for modelId: String) -> State? { states[modelId] }

    /// Starts (or queues) a download. No-op if already downloaded or in flight.
    func download(_ modelId: String) {
        guard !isDownloaded(modelId) else { return }
        if running == modelId || queue.contains(modelId) { return }
        states[modelId] = .pending
        queue.append(modelId)
        pump()
    }

    func cancel(_ modelId: String) {
        if running == modelId {
            cancelRequested.insert(modelId)
            service.cancelActiveDownload()
        } else {
            queue.removeAll { $0 == modelId }
            states[modelId] = nil
        }
    }

    private func pump() {
        guard running == nil, !queue.isEmpty else { return }
        let modelId = queue.removeFirst()
        running = modelId
        states[modelId] = .downloading(received: 0, total: 0)
        service.downloadBytesProgress = { [weak self] received, total in
            Task { @MainActor in self?.states[modelId] = .downloading(received: received, total: total) }
        }
        Task {
            do {
                try await service.downloadModel(modelId) { _ in }
                states[modelId] = nil
                revision += 1
                AppLogger.shared.log("Model downloaded: \(modelId)", category: .model)
                JobManager.shared.modelBecameAvailable(modelId)
            } catch is CancellationError {
                states[modelId] = nil
                cancelRequested.remove(modelId)
                JobManager.shared.modelDownloadCancelled(modelId)
            } catch {
                if cancelRequested.remove(modelId) != nil {
                    states[modelId] = nil
                    JobManager.shared.modelDownloadCancelled(modelId)
                } else {
                    states[modelId] = .failed(error.localizedDescription)
                    AppLogger.shared.logError(error, context: "Model download \(modelId)", category: .model)
                }
            }
            service.downloadBytesProgress = nil
            running = nil
            pump()
        }
    }
}
