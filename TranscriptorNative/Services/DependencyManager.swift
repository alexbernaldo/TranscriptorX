import Foundation
import Combine

/// Manages system dependencies verification and installation
@MainActor
class DependencyManager: ObservableObject {
    
    // MARK: - Published Properties
    
    @Published var dependencies: [Dependency] = []
    @Published var isChecking = false
    @Published var isInstalling = false
    @Published var currentInstallStep = ""
    @Published var installProgress: Double = 0
    @Published var installLogs: [String] = []
    @Published var isReady = false
    
    var missingDependencies: [Dependency] {
        dependencies.filter { !$0.isInstalled }
    }
    
    private func updateReadyState() {
        let Ready = dependencies.allSatisfy { $0.isInstalled } && !dependencies.isEmpty
        print("DEBUG: updateReadyState: \(Ready)")
        if !Ready {
            let missing = dependencies.filter { !$0.isInstalled }.map { $0.name }
            print("DEBUG: Missing: \(missing)")
        }
        
        // Ensure UI update on main thread
        Task { @MainActor in
            self.isReady = Ready
        }
    }
    
    // MARK: - Dependency Model
    
    struct Dependency: Identifiable {
        let id: String
        let name: String
        let description: String
        let checkCommand: String
        let installCommands: [String]
        var isInstalled: Bool = false
        var isInstalling: Bool = false
    }
    
    // MARK: - App Data Directory
    
    private var appSupportDir: URL {
        let paths = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        let appDir = paths[0].appendingPathComponent("Transcriptor")
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        return appDir
    }
    
    private var whisperCppDir: URL {
        appSupportDir.appendingPathComponent("whisper.cpp")
    }
    
    private var venvDir: URL {
        appSupportDir.appendingPathComponent("whisper-env")
    }

    private var isSpanishUI: Bool {
        UserDefaults.standard.string(forKey: "app_ui_language") == "es"
    }

    private func localized(_ spanish: String, _ english: String) -> String {
        isSpanishUI ? spanish : english
    }
    
    // MARK: - Initialization
    
    init() {
        setupDependencies()
    }
    
    private func setupDependencies() {
        dependencies = [
            Dependency(
                id: "homebrew",
                name: "Homebrew",
                description: "Gestor de paquetes para macOS",
                checkCommand: "which brew",
                installCommands: [
                    "/bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
                ]
            ),
            Dependency(
                id: "ffmpeg",
                name: "FFmpeg",
                description: "Procesamiento de audio/video",
                checkCommand: "which ffmpeg",
                installCommands: ["brew install ffmpeg"]
            ),
            Dependency(
                id: "whisper-cpp",
                name: "whisper.cpp",
                description: "Motor de transcripción nativo con CoreML",
                checkCommand: "test -f \"\(whisperCppDir.path)/build/bin/whisper-cli\"",
                installCommands: [
                    "rm -rf \"\(whisperCppDir.path)\"",
                    "git clone https://github.com/ggerganov/whisper.cpp.git \"\(whisperCppDir.path)\"",
                    // Build with CoreML support for Neural Engine acceleration
                    "cd \"\(whisperCppDir.path)\" && cmake -B build -DWHISPER_COREML=1",
                    "cd \"\(whisperCppDir.path)\" && cmake --build build --config Release -j"
                ]
            )
        ]
    }
    
    // MARK: - Check Dependencies
    
    func checkAll() async {
        print("DEBUG: Checking all dependencies...")
        isChecking = true
        
        for i in dependencies.indices {
            let result = await checkDependency(dependencies[i])
            dependencies[i].isInstalled = result
            print("DEBUG: Dependency \(dependencies[i].name) installed: \(result)")
        }
        
        isChecking = false
        updateReadyState()
    }
    
    private func checkDependency(_ dep: Dependency) async -> Bool {
        let result = await runCommand(dep.checkCommand)
        if result.exitCode != 0 {
            print("DEBUG: Check failed for \(dep.name). Error: \(result.error)")
            // If checking python env, print output too as it might contain Python tracebacks
            if dep.id == "venv" {
                print("DEBUG: Python env check output: \(result.output)")
            }
        }
        return result.exitCode == 0
    }
    
    // MARK: - Install Dependencies
    
    func installMissing() async {
        isInstalling = true
        installProgress = 0
        installLogs = []
        
        // Re-check first to get fresh status
        await checkAll()
        
        let missing = missingDependencies
        
        // If nothing to install, we're done
        if missing.isEmpty {
            log(localized("✅ Todas las dependencias ya están instaladas", "✅ All dependencies are already installed"))
            currentInstallStep = localized("¡Todo listo!", "All set!")
            installProgress = 1.0
            isInstalling = false
            updateReadyState()
            return
        }
        
        let totalSteps = missing.reduce(0) { $0 + $1.installCommands.count }
        var completedSteps = 0
        
        let installingText = localized("📦 Instalando %d dependencias...", "📦 Installing %d dependencies...")
        log(String(format: installingText, missing.count))
        
        for i in dependencies.indices {
            guard !dependencies[i].isInstalled else { continue }
            
            dependencies[i].isInstalling = true
            currentInstallStep = localized("Instalando \(dependencies[i].name)...", "Installing \(dependencies[i].name)...")
            
            for command in dependencies[i].installCommands {
                log("→ \(command)")
                let result = await runCommand(command)
                
                if !result.output.isEmpty {
                    log(result.output)
                }
                
                if result.exitCode != 0 {
                    log(localized("❌ Error: \(result.error)", "❌ Error: \(result.error)"))
                    dependencies[i].isInstalling = false
                    isInstalling = false
                    return
                }
                
                completedSteps += 1
                installProgress = Double(completedSteps) / Double(totalSteps)
            }
            
            // Verify installation actually succeeded
            log(localized("Verificando instalación de \(dependencies[i].name)...", "Verifying installation of \(dependencies[i].name)..."))
            let verifyResult = await checkDependency(dependencies[i])
            dependencies[i].isInstalled = verifyResult
            dependencies[i].isInstalling = false
            
            if verifyResult {
                log(localized("✅ \(dependencies[i].name) instalado y verificado", "✅ \(dependencies[i].name) installed and verified"))
            } else {
                log(localized("❌ Falló la verificación de \(dependencies[i].name)", "❌ Verification failed for \(dependencies[i].name)"))
                log(localized("⚠️ El archivo esperado no se encontró: \(dependencies[i].checkCommand)", "⚠️ Expected file not found: \(dependencies[i].checkCommand)"))
            }
            
            updateReadyState()
        }
        
        currentInstallStep = localized("¡Instalación completada!", "Installation completed!")
        isInstalling = false
        updateReadyState()
    }
    
    // MARK: - Helpers
    
    private func log(_ message: String) {
        installLogs.append(message)
    }
    
    private func runCommand(_ command: String) async -> (exitCode: Int32, output: String, error: String) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let outputPipe = Pipe()
                let errorPipe = Pipe()
                
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-c", command]
                process.standardOutput = outputPipe
                process.standardError = errorPipe
                process.environment = ProcessInfo.processInfo.environment
                
                // Add homebrew and system paths to PATH
                var env = process.environment ?? [:]
                env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")
                process.environment = env
                
                do {
                    try process.run()
                    process.waitUntilExit()
                    
                    let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    
                    let output = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let error = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    
                    continuation.resume(returning: (process.terminationStatus, output, error))
                } catch {
                    continuation.resume(returning: (1, "", error.localizedDescription))
                }
            }
        }
    }
}
