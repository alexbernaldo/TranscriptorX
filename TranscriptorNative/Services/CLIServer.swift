import Foundation

/// Serves the `tx` CLI over a Unix domain socket. The app owns the engine;
/// clients only send requests and receive event streams.
final class CLIServer {
    static let shared = CLIServer()
    static let socketPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Transcriptor/cli.sock").path

    private var listenFD: Int32 = -1
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "tx.cli.server")

    func start() {
        guard listenFD < 0 else { return }
        unlink(Self.socketPath)
        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { return }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            Self.socketPath.utf8CString.withUnsafeBytes { path in
                _ = memcpy(buf.baseAddress!, path.baseAddress!, min(path.count, buf.count))
            }
        }
        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        guard withUnsafePointer(to: &addr, { bind(listenFD, UnsafeRawPointer($0).assumingMemoryBound(to: sockaddr.self), addrLen) }) == 0 else {
            close(listenFD); listenFD = -1; return
        }
        // Only the current user may connect to the CLI socket.
        chmod(Self.socketPath, 0o600)
        _ = listen(listenFD, 5)

        let s = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: queue)
        s.setEventHandler { [weak self] in
            let client = accept(self!.listenFD, nil, nil)
            guard client >= 0 else { return }
            self?.handle(client: client)
        }
        s.resume()
        source = s
        AppLogger.shared.log("CLI server listening on cli.sock", category: .app)
    }

    func stop() {
        source?.cancel(); source = nil
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
        unlink(Self.socketPath)
    }

    // MARK: - Client handling

    private func handle(client: Int32) {
        queue.async { [weak self] in
            guard let self else { close(client); return }
            // Bound how long a silent client can hold the serial worker.
            var tv = timeval(tv_sec: 5, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            guard let data = self.readLine(fd: client),
                  let request = try? JSONDecoder().decode(CLIRequest.self, from: data) else {
                self.send(CLIServerEvent(type: .error, jobId: nil, text: nil, percent: nil,
                                         message: "Malformed request", payload: nil), to: client)
                close(client)
                return
            }
            switch request.command {
            case .transcribe:
                // Keeps the fd open until the progress stream finishes.
                self.dispatchTranscribe(request, client: client)
            default:
                self.dispatch(request, client: client)
            }
        }
    }

    private func readLine(fd: Int32) -> Data? {
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 1024)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { return out.isEmpty ? nil : out }
            out.append(contentsOf: buf[0..<n])
            if out.count > 1_048_576 { return nil }
            if out.contains(0x0A) { return out }
        }
    }

    private func send(_ event: CLIServerEvent, to fd: Int32) {
        var payload = (try? JSONEncoder().encode(event)) ?? Data()
        payload.append(0x0A)
        payload.withUnsafeBytes { _ = write(fd, $0.baseAddress, payload.count) }
    }

    private func dispatch(_ req: CLIRequest, client: Int32) {
        switch req.command {
        case .version:
            let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
            send(CLIServerEvent(type: .version, jobId: nil, text: nil, percent: nil,
                                message: nil, payload: v), to: client)
        case .models:
            let list = ModelInfo.allModels.map { "\($0.id)\t\($0.name)" }.joined(separator: "\n")
            send(CLIServerEvent(type: .models, jobId: nil, text: nil, percent: nil,
                                message: nil, payload: list), to: client)
        case .transcribe:
            break
        }
        close(client)
    }

    private func dispatchTranscribe(_ req: CLIRequest, client: Int32) {
        let urls = req.paths.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            .filter { FileInputService.isSupported($0) }
        guard !urls.isEmpty else {
            send(CLIServerEvent(type: .error, jobId: nil, text: nil, percent: nil,
                                message: "No supported audio or video files found.", payload: nil), to: client)
            close(client)
            return
        }
        var settings = TranscriptionSettings.default
        if let lang = req.language { settings.language = lang }
        if let model = req.model { settings.selectedModelId = model }

        DispatchQueue.main.async { [weak self] in
            guard let self else { close(client); return }
            let ids = JobManager.shared.enqueue(
                files: urls.map { (url: $0, name: $0.lastPathComponent, duration: nil) },
                settings: settings
            )
            self.send(CLIServerEvent(type: .accepted, jobId: ids.first, text: nil, percent: 0,
                                     message: nil, payload: "\(ids.count) job(s) enqueued"), to: client)
            guard let lastId = ids.last else { close(client); return }
            self.stream(lastId: lastId, client: client)
        }
    }

    /// Stream events until the last job leaves the queue (poll 300 ms — v1).
    private func stream(lastId: UUID, client: Int32) {
        DispatchQueue.global().async { [weak self] in
            var finished = false
            while !finished {
                Thread.sleep(forTimeInterval: 0.3)
                let snapshot = DispatchQueue.main.sync { JobManager.shared.jobs }
                guard let job = snapshot.first(where: { $0.id == lastId }) else {
                    self?.send(CLIServerEvent(type: .completed, jobId: lastId, text: nil,
                                              percent: 100, message: nil, payload: nil), to: client)
                    finished = true; break
                }
                if job.status == .completed || job.status == .failed || job.status == .cancelled {
                    if job.status == .completed {
                        let text = job.result?.plainText ?? ""
                        self?.send(CLIServerEvent(type: .completed, jobId: lastId, text: text,
                                                  percent: 100, message: nil, payload: nil), to: client)
                    } else {
                        self?.send(CLIServerEvent(type: .failed, jobId: lastId, text: nil,
                                                  percent: nil, message: job.errorMessage, payload: nil), to: client)
                    }
                    finished = true
                } else {
                    let streaming = job.streamingText
                    if !streaming.isEmpty {
                        self?.send(CLIServerEvent(type: .partial, jobId: lastId, text: streaming,
                                                  percent: job.progress, message: nil, payload: nil), to: client)
                    }
                }
            }
            self?.send(CLIServerEvent(type: .completed, jobId: nil, text: nil, percent: nil,
                                      message: nil, payload: "stream-end"), to: client)
            close(client)
        }
    }
}
