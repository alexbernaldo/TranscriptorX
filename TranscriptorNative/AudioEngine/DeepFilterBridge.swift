import Foundation
import AVFoundation

/// Bridge para DeepFilterNet (CLI Binary)
/// Reducción de ruido estado del arte
///
/// Usa el binario deep-filter compilado desde Rust
/// Incluido en la app bundle para uso offline
///
final class DeepFilterBridge {
    
    // Singleton
    static let shared = DeepFilterBridge()
    
    // Estado
    private(set) var isLoaded = false
    
    // Configuración
    var attenuation: Float = 0.0  // 0 = full attenuation (default)
    
    // Path al binario
    private var binaryPath: URL? {
        // Check bundle first
        if let bundlePath = Bundle.main.path(forResource: "deep-filter", ofType: nil) {
            return URL(fileURLWithPath: bundlePath)
        }
        
        // Check AudioEngine/lib folder during development
        let devPath = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("AudioEngine/lib/deep-filter")
        if FileManager.default.fileExists(atPath: devPath.path) {
            return devPath
        }
        
        // Check source folder for development
        let srcPath = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .appendingPathComponent("lib/deep-filter")
        if FileManager.default.fileExists(atPath: srcPath.path) {
            return srcPath
        }
        
        // Fallback to Application Support
        let supportPath = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Transcriptor/AudioEngine/lib/deep-filter")
        if FileManager.default.fileExists(atPath: supportPath.path) {
            return supportPath
        }
        
        return nil
    }
    
    // MARK: - Initialization
    
    private init() {}
    
    /// Check if DeepFilter binary is available
    var isAvailable: Bool {
        guard let path = binaryPath else { return false }
        return FileManager.default.fileExists(atPath: path.path)
    }
    
    /// Load/verify the DeepFilter binary
    func load() throws {
        guard !isLoaded else { return }
        
        guard let path = binaryPath else {
            throw DeepFilterError.binaryNotFound
        }
        
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw DeepFilterError.binaryNotFound
        }
        
        // Verify it's executable, try to make it executable if not
        if !FileManager.default.isExecutableFile(atPath: path.path) {
            do {
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
            } catch {
                throw DeepFilterError.notExecutable
            }
        }
        
        isLoaded = true
        print("✅ DeepFilterNet binary ready: \(path.lastPathComponent)")
    }
    
    // MARK: - Processing
    
    /// Process audio file to reduce noise
    /// - Parameters:
    ///   - inputURL: Input audio file
    ///   - outputURL: Output path for denoised audio
    /// - Returns: URL of the denoised audio file
    func processFile(input inputURL: URL, output outputURL: URL) throws -> URL {
        guard isLoaded, let binaryPath = binaryPath else {
            throw DeepFilterError.notLoaded
        }
        
        // Create output directory if needed
        let outputDir = outputURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        
        // Build command
        // deep-filter [OPTIONS] <INPUT> -o <OUTPUT>
        var arguments = [
            inputURL.path,
            "-o", outputDir.path
        ]
        
        // Add attenuation limit if not default (in dB, typically 6-100)
        if attenuation > 0 {
            // Convert 0.0-1.0 scale to dB (e.g., 0.7 -> 40dB)
            let attenuationDB = Int(attenuation * 60)
            arguments.append(contentsOf: ["--atten-lim-db", String(attenuationDB)])
        }
        
        // Run the process
        let process = Process()
        process.executableURL = binaryPath
        process.arguments = arguments
        process.currentDirectoryURL = outputDir
        
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        
        print("🔇 DeepFilter: Processing \(inputURL.lastPathComponent)...")
        
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw DeepFilterError.executionFailed(error.localizedDescription)
        }
        
        // Check exit status
        guard process.terminationStatus == 0 else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw DeepFilterError.processingFailed(errorMessage)
        }
        
        // The output file will be named: inputname_DeepFilterNet3.wav
        // Check both the output directory and the input directory (deep-filter may write to either)
        let outputFileName = inputURL.deletingPathExtension().lastPathComponent + "_DeepFilterNet3.wav"
        let expectedOutput = outputDir.appendingPathComponent(outputFileName)
        let fallbackOutput = inputURL.deletingLastPathComponent().appendingPathComponent(outputFileName)
        
        let actualOutput: URL
        if FileManager.default.fileExists(atPath: expectedOutput.path) {
            actualOutput = expectedOutput
        } else if FileManager.default.fileExists(atPath: fallbackOutput.path) {
            actualOutput = fallbackOutput
        } else {
            print("DEBUG DeepFilter: Expected output not found at \(expectedOutput.path) or \(fallbackOutput.path)")
            throw DeepFilterError.outputNotCreated
        }
        
        // Rename to requested output name if different
        if actualOutput != outputURL {
            if FileManager.default.fileExists(atPath: outputURL.path) {
                try FileManager.default.removeItem(at: outputURL)
            }
            try FileManager.default.moveItem(at: actualOutput, to: outputURL)
        }
        
        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            throw DeepFilterError.outputNotCreated
        }
        
        print("✅ DeepFilter: Output saved to \(outputURL.lastPathComponent)")
        return outputURL
    }
    
    /// Process audio data asynchronously
    func processFileAsync(input inputURL: URL, output outputURL: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try self.processFile(input: inputURL, output: outputURL)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    /// Cleanup
    func unload() {
        isLoaded = false
    }
}

// MARK: - Errors

enum DeepFilterError: LocalizedError {
    case binaryNotFound
    case notExecutable
    case notLoaded
    case executionFailed(String)
    case processingFailed(String)
    case outputNotCreated
    
    var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            return "DeepFilter binary not found. Include deep-filter in app bundle."
        case .notExecutable:
            return "DeepFilter binary is not executable"
        case .notLoaded:
            return "DeepFilter not loaded. Call load() first"
        case .executionFailed(let error):
            return "Failed to execute DeepFilter: \(error)"
        case .processingFailed(let error):
            return "DeepFilter processing failed: \(error)"
        case .outputNotCreated:
            return "DeepFilter did not create output file"
        }
    }
}
