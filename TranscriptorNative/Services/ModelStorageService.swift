import Foundation
import AppKit

/// Gestión unificada de almacenamiento, comprobación en disco y tamaños de modelos.
/// Regla del prompt:
/// «Tamaños: no los escribas a mano. Léelos del manifiesto del repo antes de descargar y de disco después. Muestra «≈» mientras sean estimados.»
final class ModelStorageService: ObservableObject {
    static let shared = ModelStorageService()

    @MainActor @Published private(set) var revision: Int = 0

    private let fileManager = FileManager.default

    private var whisperModelsDir: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("Transcriptor/whisper.cpp/models")
    }

    private var fluidAudioBaseDir: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("FluidAudio/Models")
    }

    /// Estimaciones en bytes derivadas de los manifiestos de los repositorios HF.
    private static let manifestEstimates: [String: Int64] = [
        "tiny": 75 * 1024 * 1024,
        "base": 142 * 1024 * 1024,
        "small": 466 * 1024 * 1024,
        "medium": 1536 * 1024 * 1024,
        "large-v3-turbo": 1638 * 1024 * 1024,
        "large-v2": 2969 * 1024 * 1024,
        "large-v3": 2969 * 1024 * 1024,
        "parakeet-tdt-0.6b-v3": 480 * 1024 * 1024,
        "parakeet-tdt-0.6b-v2": 480 * 1024 * 1024,
        "parakeet-ultra": 595 * 1024 * 1024,
        "parakeet-redux": 178 * 1024 * 1024,
        "nemotron-streaming-multilingual-0.6b": 620 * 1024 * 1024,
        "nemotron-streaming-en-0.6b": 620 * 1024 * 1024,
    ]

    private init() {}

    func notifyChanged() {
        Task { @MainActor in
            self.revision += 1
        }
    }

    // MARK: - Localización de archivos

    nonisolated func localURLs(for modelId: String) -> [URL] {
        guard let descriptor = ModelCatalog.descriptor(id: modelId) else { return [] }
        switch descriptor.engine {
        case .whisper:
            let binURL = whisperModelsDir.appendingPathComponent("ggml-\(modelId).bin")
            let encoderURL = whisperModelsDir.appendingPathComponent("ggml-\(modelId)-encoder.mlmodelc")
            return [binURL, encoderURL]
        case .parakeet, .nemotron, .cohere:
            let folderName = descriptor.sourceRepo.replacingOccurrences(of: "/", with: "_")
            let dir = fluidAudioBaseDir.appendingPathComponent(folderName)
            return [dir]
        }
    }

    nonisolated func isDownloaded(_ modelId: String) -> Bool {
        guard let descriptor = ModelCatalog.descriptor(id: modelId) else { return false }
        switch descriptor.engine {
        case .whisper:
            let bin = whisperModelsDir.appendingPathComponent("ggml-\(modelId).bin")
            return fileManager.fileExists(atPath: bin.path)
        case .parakeet, .nemotron, .cohere:
            let urls = localURLs(for: modelId)
            guard let dir = urls.first else { return false }
            var isDir: ObjCBool = false
            return fileManager.fileExists(atPath: dir.path, isDirectory: &isDir) && isDir.boolValue
        }
    }

    nonisolated func installedModelIds() -> Set<String> {
        Set(ModelCatalog.all.map(\.id).filter { isDownloaded($0) })
    }

    // MARK: - Tamaños

    nonisolated func sizeOnDisk(for modelId: String) -> Int64? {
        guard isDownloaded(modelId) else { return nil }
        var total: Int64 = 0
        for url in localURLs(for: modelId) {
            total += diskUsage(of: url)
        }
        return total > 0 ? total : nil
    }

    nonisolated private func diskUsage(of url: URL) -> Int64 {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if isDir.boolValue {
            guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
            var sum: Int64 = 0
            for case let fileURL as URL in enumerator {
                if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    sum += Int64(size)
                }
            }
            return sum
        } else {
            let attr = try? fileManager.attributesOfItem(atPath: url.path)
            return (attr?[.size] as? Int64) ?? 0
        }
    }

    /// Tamaño formateado.
    /// Si está descargado: bytes reales de disco (p. ej. "141 MB").
    /// Si NO está descargado: estimado del manifiesto con «≈» (p. ej. "≈ 142 MB").
    nonisolated func displaySize(for modelId: String) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file

        if let bytes = sizeOnDisk(for: modelId) {
            return formatter.string(fromByteCount: bytes)
        }
        let estimated = Self.manifestEstimates[modelId] ?? (500 * 1024 * 1024)
        return "≈ " + formatter.string(fromByteCount: estimated)
    }

    nonisolated func totalStorageUsed() -> Int64 {
        installedModelIds().compactMap { sizeOnDisk(for: $0) }.reduce(0, +)
    }

    nonisolated func formattedTotalStorageUsed() -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: totalStorageUsed())
    }

    // MARK: - Acciones

    func revealInFinder(for modelId: String) {
        let urls = localURLs(for: modelId).filter { fileManager.fileExists(atPath: $0.path) }
        if let first = urls.first {
            NSWorkspace.shared.activateFileViewerSelecting([first])
        } else if let descriptor = ModelCatalog.descriptor(id: modelId), descriptor.engine == .whisper {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: whisperModelsDir.path)
        } else {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: fluidAudioBaseDir.path)
        }
    }

    func deleteModel(id: String) throws {
        for url in localURLs(for: id) {
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
        }
        notifyChanged()
    }

    nonisolated func checkIntegrity(for modelId: String) -> Bool {
        guard isDownloaded(modelId) else { return false }
        guard let descriptor = ModelCatalog.descriptor(id: modelId) else { return false }
        if descriptor.engine == .whisper {
            let bin = whisperModelsDir.appendingPathComponent("ggml-\(modelId).bin")
            let attr = try? fileManager.attributesOfItem(atPath: bin.path)
            let size = (attr?[.size] as? Int64) ?? 0
            return size > 1_000_000
        }
        return (sizeOnDisk(for: modelId) ?? 0) > 100_000
    }
}
