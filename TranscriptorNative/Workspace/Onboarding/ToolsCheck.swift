import Foundation

/// Homebrew, FFmpeg, whisper and yt-dlp (spec 6.1 step 2, Diagnóstico 6.27).
/// Detects and reports versions; the existing installer (`DependencyManager`) stays available.
@MainActor
final class ToolsCheck: ObservableObject {
    static let shared = ToolsCheck()

    enum Tool: String, CaseIterable, Identifiable {
        case homebrew, ffmpeg, whisper, ytdlp
        var id: String { rawValue }

        var name: String {
            switch self {
            case .homebrew: return "Homebrew"
            case .ffmpeg: return "FFmpeg"
            case .whisper: return "whisper"
            case .ytdlp: return "yt-dlp"
            }
        }

        var purpose: String {
            switch self {
            case .homebrew: return TXL.t("tools.homebrew.purpose", "Instala las demás herramientas")
            case .ffmpeg: return TXL.t("tools.ffmpeg.purpose", "Lee y convierte audio y vídeo")
            case .whisper: return TXL.t("tools.whisper.purpose", "Motor de transcripción")
            case .ytdlp: return TXL.t("tools.ytdlp.purpose", "Descarga desde enlaces")
            }
        }

        /// FFmpeg and whisper block continuing; yt-dlp and Homebrew do not.
        var isRequired: Bool { self == .ffmpeg || self == .whisper }

        var installCommand: String {
            switch self {
            case .homebrew:
                return "/bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
            case .ffmpeg: return "brew install ffmpeg"
            case .ytdlp: return "brew install yt-dlp"
            case .whisper:
                let dir = "\"$HOME/Library/Application Support/Transcriptor/whisper.cpp\""
                return "git clone https://github.com/ggerganov/whisper.cpp.git \(dir) && cd \(dir) && cmake -B build -DWHISPER_COREML=1 -DWHISPER_COREML_ALLOW_FALLBACK=1 && cmake --build build --config Release -j"
            }
        }

        /// The app's existing installer covers these (spec 12.1 #18: it installs, not only detects).
        /// Homebrew's own installer is interactive, so for it only the command is offered.
        var canInstallInApp: Bool { self == .ffmpeg || self == .whisper }
    }

    enum Status: Equatable {
        case checking
        case found(version: String?)
        case missing
        case failed(String)
    }

    @Published private(set) var status: [Tool: Status] = [:]
    @Published private(set) var isChecking = false

    func status(_ tool: Tool) -> Status { status[tool] ?? .checking }

    var blockingMissing: Bool {
        Tool.allCases.contains { $0.isRequired && status($0) != .checking && !isFound($0) }
    }
    var onlyLinksMissing: Bool {
        !blockingMissing && !isFound(.ytdlp) && status(.ytdlp) != .checking
    }

    func isFound(_ tool: Tool) -> Bool {
        if case .found = status(tool) { return true }
        return false
    }

    func check() {
        guard !isChecking else { return }
        isChecking = true
        for tool in Tool.allCases { status[tool] = .checking }
        Task {
            await withTaskGroup(of: (Tool, Status).self) { group in
                for tool in Tool.allCases {
                    group.addTask { (tool, await Self.probe(tool)) }
                }
                for await (tool, result) in group { status[tool] = result }
            }
            isChecking = false
        }
    }

    nonisolated private static func probe(_ tool: Tool) async -> Status {
        switch tool {
        case .homebrew:
            return await run(["/opt/homebrew/bin/brew", "/usr/local/bin/brew"], args: ["--version"]) { out in
                out.split(separator: "\n").first.map { String($0).replacingOccurrences(of: "Homebrew ", with: "") }
            }
        case .ffmpeg:
            return await run(["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"], args: ["-version"]) { out in
                let words = out.split(separator: " ")
                return words.count > 2 ? String(words[2]) : nil
            }
        case .ytdlp:
            return await run(["/opt/homebrew/bin/yt-dlp", "/usr/local/bin/yt-dlp"], args: ["--version"]) { out in
                out.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        case .whisper:
            let path = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Transcriptor/whisper.cpp/build/bin/whisper-cli").path
            return FileManager.default.isExecutableFile(atPath: path) ? .found(version: nil) : .missing
        }
    }

    nonisolated private static func run(_ candidates: [String], args: [String], parse: @escaping (String) -> String?) async -> Status {
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return .missing }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: path)
                p.arguments = args
                let out = Pipe()
                p.standardOutput = out
                p.standardError = Pipe()
                do {
                    try p.run()
                    p.waitUntilExit()
                    let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    continuation.resume(returning: p.terminationStatus == 0 ? .found(version: parse(text)) : .failed(text))
                } catch {
                    continuation.resume(returning: .failed(error.localizedDescription))
                }
            }
        }
    }

    /// Plain-text report for «Copiar informe» (nothing is sent anywhere).
    func report() -> String {
        var lines = ["Transcriptor X \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")",
                     "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"]
        for tool in Tool.allCases {
            switch status(tool) {
            case .found(let v): lines.append("\(tool.name): \(v ?? "OK")")
            case .missing: lines.append("\(tool.name): not found")
            case .checking: lines.append("\(tool.name): checking")
            case .failed(let e): lines.append("\(tool.name): error \(e.prefix(120))")
            }
        }
        lines.append("tx: \(CLIInstall.isInstalled ? CLIInstall.path : "not installed")")
        lines.append("Model in memory: \(JobManager.shared.modelInUse ?? "none")")
        return lines.joined(separator: "\n")
    }
}

/// Command line tool status (spec 6.22). `tx` is not embedded in the app bundle; it is
/// installed from the repository with scripts/install_cli.sh.
enum CLIInstall {
    static var path: String { NSHomeDirectory() + "/.local/bin/tx" }
    static var isInstalled: Bool { FileManager.default.isExecutableFile(atPath: path) }
    static let installCommand = "bash scripts/install_cli.sh"
}
