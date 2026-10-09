import Foundation

/// Watches folders for new audio/video files and enqueues them for transcription.
final class WatchedFoldersManager: ObservableObject {
    static let shared = WatchedFoldersManager()
    @Published private(set) var folders: [URL] = []
    @Published private(set) var autoExport = false

    private let foldersKey = "watchedFolders"
    private let autoExportKey = "watchedFolderAutoExport"
    private var sourceMap: [URL: DispatchSourceFileSystemObject] = [:]
    private var knownFiles: Set<String> = []
    private let queue = DispatchQueue(label: "tx.watchedfolders")

    private init() {
        if let raw = UserDefaults.standard.stringArray(forKey: foldersKey) {
            folders = raw.map { URL(fileURLWithPath: $0) }
        }
        autoExport = UserDefaults.standard.bool(forKey: autoExportKey)
        folders.forEach(startWatching)
    }

    func add(_ url: URL) {
        guard !folders.contains(url) else { return }
        folders.append(url)
        persist()
        startWatching(url)
    }

    func remove(_ url: URL) {
        folders.removeAll { $0 == url }
        persist()
        queue.async { [weak self] in
            guard let self else { return }
            self.sourceMap[url]?.cancel()
            self.sourceMap[url] = nil
        }
    }

    func setAutoExport(_ on: Bool) {
        autoExport = on
        UserDefaults.standard.set(on, forKey: autoExportKey)
    }

    private func persist() {
        UserDefaults.standard.set(folders.map(\.path), forKey: foldersKey)
    }

    private func startWatching(_ dir: URL) {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.sourceMap[dir] == nil else { return }
            let fd = open(dir.path, O_EVTONLY)
            guard fd >= 0 else { return }
            let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: self.queue)
            src.setEventHandler { [weak self] in self?.scan(dir) }
            src.setCancelHandler { close(fd) }
            src.resume()
            self.sourceMap[dir] = src
            self.seed(dir)
        }
    }

    /// Registers files already present in the folder so only NEW arrivals are enqueued.
    private func seed(_ dir: URL) {
        let contents = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for file in contents where FileInputService.isSupported(file) {
            knownFiles.insert(file.path)
        }
    }

    private func scan(_ dir: URL) {
        let contents = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for file in contents where FileInputService.isSupported(file) {
            let path = file.path
            if !knownFiles.contains(path) {
                knownFiles.insert(path)
                if FileManager.default.fileExists(atPath: path) {
                    DispatchQueue.main.async {
                        JobManager.shared.enqueue(
                            fileURL: file,
                            fileName: file.lastPathComponent,
                            settings: TranscriptionSettings.default
                        )
                    }
                }
            }
        }
    }
}
