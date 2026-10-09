import Foundation

struct ArgumentError: Error { let message: String }

func parse(_ args: [String]) throws -> CLIRequest {
    guard let cmd = args.first, let command = CLICommand(rawValue: cmd) else {
        throw ArgumentError(message: """
        Usage:
          tx transcribe <files...> [--language <code>] [--format <txt|srt|vtt|csv|md|json|html>]
             [--output <file>] [--output-dir <dir>] [--model <id>] [--overwrite]
          tx models
          tx version
        """)
    }
    var rest = Array(args.dropFirst())
    var paths: [String] = []
    var req = CLIRequest(command: command, paths: [], language: nil, format: nil,
                         output: nil, outputDir: nil, overwrite: nil, model: nil,
                         saveToHistory: nil)
    while !rest.isEmpty {
        let a = rest.removeFirst()
        switch a {
        case "--language": req.language = rest.removeFirst()
        case "--format": req.format = rest.removeFirst()
        case "--output": req.output = rest.removeFirst()
        case "--output-dir": req.outputDir = rest.removeFirst()
        case "--model": req.model = rest.removeFirst()
        case "--overwrite": req.overwrite = true
        default:
            if a.hasPrefix("--") { throw ArgumentError(message: "Unknown flag: \(a)") }
            paths.append(a)
        }
    }
    if req.output != nil && req.outputDir != nil {
        throw ArgumentError(message: "--output and --output-dir are mutually exclusive.")
    }
    req.paths = paths
    return req
}

func connect() throws -> Int32 {
    let path = NSString(string: "~/Library/Application Support/Transcriptor/cli.sock").expandingTildeInPath
    let notRunning = """
    Transcriptor X is not running. Open the app and try again.
    (Install the tool with: scripts/install_cli.sh)
    """
    guard FileManager.default.fileExists(atPath: path) else {
        throw ArgumentError(message: notRunning)
    }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &addr.sun_path) { buf in
        path.utf8CString.withUnsafeBytes { _ = memcpy(buf.baseAddress!, $0.baseAddress!, min($0.count, buf.count)) }
    }
    let ok = withUnsafePointer(to: &addr) {
        connect(fd, UnsafeRawPointer($0).assumingMemoryBound(to: sockaddr.self),
                socklen_t(MemoryLayout<sockaddr_un>.size))
    }
    guard ok == 0 else { close(fd); throw ArgumentError(message: notRunning) }
    return fd
}

func writeOutput(text: String, req: CLIRequest) throws {
    if let output = req.output {
        let dest = NSString(string: output).expandingTildeInPath
        if FileManager.default.fileExists(atPath: dest) && req.overwrite != true {
            throw ArgumentError(message: "Output file already exists. Pass --overwrite to replace it.")
        }
        try text.write(toFile: dest, atomically: true, encoding: .utf8)
    } else if let dir = req.outputDir {
        let dirPath = NSString(string: dir).expandingTildeInPath
        let base = (req.paths.first.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? "transcript")
        let ext = req.format ?? "txt"
        let dest = (dirPath as NSString).appendingPathComponent("\(base).\(ext)")
        if FileManager.default.fileExists(atPath: dest) && req.overwrite != true {
            throw ArgumentError(message: "Output file already exists. Pass --overwrite to replace it.")
        }
        try text.write(toFile: dest, atomically: true, encoding: .utf8)
    }
}

do {
    let req = try parse(Array(CommandLine.arguments.dropFirst()))
    let fd = try connect()
    var encoded = try JSONEncoder().encode(req); encoded.append(0x0A)
    encoded.withUnsafeBytes { _ = write(fd, $0.baseAddress, encoded.count) }

    var buffer = Data()
    var buf = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = read(fd, &buf, buf.count)
        if n <= 0 { break }
        buffer.append(contentsOf: buf[0..<n])
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[..<nl]; buffer = buffer[buffer.index(after: nl)...]
            guard let event = try? JSONDecoder().decode(CLIServerEvent.self, from: line) else { continue }
            switch event.type {
            case .partial: FileHandle.standardError.write((event.text ?? "").data(using: .utf8)!)
            case .progress: FileHandle.standardError.write("\(event.percent ?? 0)%\n".data(using: .utf8)!)
            case .completed:
                if let text = event.text {
                    try writeOutput(text: text, req: req)
                    print(text)
                }
                if event.payload == "stream-end" { exit(0) }
                if req.output == nil && req.outputDir == nil { exit(0) }
            case .failed, .error:
                FileHandle.standardError.write("tx: \(event.message ?? "failed")\n".data(using: .utf8)!)
                exit(1)
            case .models, .version, .accepted:
                if let p = event.payload { print(p) }
            }
        }
    }
    close(fd)
} catch let e as ArgumentError {
    FileHandle.standardError.write("tx: \(e.message)\n".data(using: .utf8)!); exit(64)
} catch {
    FileHandle.standardError.write("tx: \(error.localizedDescription)\n".data(using: .utf8)!); exit(1)
}
