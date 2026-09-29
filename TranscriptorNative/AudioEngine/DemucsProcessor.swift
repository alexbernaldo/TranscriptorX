import Foundation
import AVFoundation

/// Procesador HTDemucs para aislamiento de voz
/// Usa un binario autónomo creado con PyInstaller (no requiere Python instalado)
///
/// El binario demucs-bundled incluye:
/// - Python embebido
/// - PyTorch + torchaudio
/// - HTDemucs modelo
///
final class DemucsProcessor {
    
    // Singleton
    static let shared = DemucsProcessor()
    
    // Estado
    private(set) var isLoaded = false
    
    // Configuración
    var device = "mps"       // cpu, cuda, o mps (para Apple Silicon)
    var shifts = 1           // Número de shifts para predicción
    var overlap: Float = 0.25
    
    // Path al ejecutable demucs-bundled
    private var binaryPath: URL? {
        // 1. Buscar en el bundle de la app (producción)
        if let bundlePath = Bundle.main.resourceURL?.appendingPathComponent("demucs-bundled"),
           FileManager.default.fileExists(atPath: bundlePath.path) {
            return bundlePath
        }
        
        // 2. Buscar en la carpeta de desarrollo
        let srcPath = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .appendingPathComponent("lib/demucs-bundled")
        if FileManager.default.fileExists(atPath: srcPath.path) {
            return srcPath
        }
        
        // 3. Fallback a Application Support
        let supportPath = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Transcriptor/AudioEngine/lib/demucs-bundled")
        if FileManager.default.fileExists(atPath: supportPath.path) {
            return supportPath
        }
        
        return nil
    }
    
    // MARK: - Initialization
    
    private init() {}
    
    /// Check if Demucs binary is available
    var isAvailable: Bool {
        guard let path = binaryPath else { return false }
        return FileManager.default.fileExists(atPath: path.path)
    }
    
    /// Load/verify Demucs binary
    func load() async throws {
        guard !isLoaded else { return }
        
        guard let path = binaryPath else {
            throw DemucsError.binaryNotFound
        }
        
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw DemucsError.binaryNotFound
        }
        
        // Verificar que es ejecutable, hacer ejecutable si no lo es
        if !FileManager.default.isExecutableFile(atPath: path.path) {
            do {
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
            } catch {
                throw DemucsError.notExecutable
            }
        }
        
        // Verificar que funciona
        let process = Process()
        process.executableURL = path
        process.arguments = ["--help"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        
        do {
            try process.run()
            process.waitUntilExit()
            
            guard process.terminationStatus == 0 else {
                throw DemucsError.notWorking
            }
        } catch {
            throw DemucsError.notWorking
        }
        
        // Detectar si MPS está disponible (Apple Silicon)
        #if arch(arm64)
        device = "mps"  // Metal Performance Shaders para Apple Silicon
        #else
        device = "cpu"
        #endif
        
        isLoaded = true
        print("✅ Demucs binary ready: \(path.lastPathComponent) (device: \(device))")
    }
    
    // MARK: - Processing
    
    /// Isolate vocals from audio file
    /// - Parameters:
    ///   - inputURL: Input audio file
    ///   - outputURL: Output path for isolated vocals
    ///   - onProgress: Progress callback
    /// - Returns: URL of the vocals-only audio file
    func isolateVocals(
        input inputURL: URL,
        output outputURL: URL,
        onProgress: ((Double) -> Void)? = nil
    ) async throws -> URL {
        guard isLoaded, let path = binaryPath else {
            throw DemucsError.notLoaded
        }
        
        // Crear directorio de salida temporal
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("demucs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        // Construir argumentos para nuestro binario custom
        // demucs-bundled --input <file> --output <dir> --device mps
        let arguments = [
            "--input", inputURL.path,
            "--output", tempDir.path,
            "--model", "htdemucs",
            "--device", device,
            "--shifts", String(shifts),
            "--overlap", String(format: "%.2f", overlap)
        ]
        
        print("🎤 Demucs: Aislando voz de \(inputURL.lastPathComponent)...")
        onProgress?(0.1)
        
        // Ejecutar demucs-bundled
        let process = Process()
        process.executableURL = path
        process.arguments = arguments
        
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        
        // Simular progreso (Demucs no reporta progreso fácilmente)
        let progressTask = Task {
            var progress = 0.1
            while !Task.isCancelled && progress < 0.9 {
                try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 segundo
                progress += 0.03
                onProgress?(min(progress, 0.9))
            }
        }
        
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            progressTask.cancel()
            throw DemucsError.executionFailed(error.localizedDescription)
        }
        
        progressTask.cancel()
        
        // Verificar resultado
        guard process.terminationStatus == 0 else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            print("❌ Demucs error: \(errorMessage)")
            throw DemucsError.processingFailed(errorMessage)
        }
        
        onProgress?(0.95)
        
        // Buscar el archivo de vocals generado
        // Nuestro script genera: <output_dir>/<input_name>_vocals.wav
        let inputName = inputURL.deletingPathExtension().lastPathComponent
        let vocalsPath = tempDir.appendingPathComponent("\(inputName)_vocals.wav")
        
        guard FileManager.default.fileExists(atPath: vocalsPath.path) else {
            // Listar contenido del directorio para debug
            let contents = try? FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
            print("📂 Contenido de tempDir: \(contents?.map { $0.lastPathComponent } ?? [])")
            throw DemucsError.outputNotFound
        }
        
        // Mover al destino final
        let outputDir = outputURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        try FileManager.default.moveItem(at: vocalsPath, to: outputURL)
        
        // Limpiar directorio temporal
        try? FileManager.default.removeItem(at: tempDir)
        
        onProgress?(1.0)
        print("✅ Demucs: Voz aislada → \(outputURL.lastPathComponent)")
        
        return outputURL
    }
    
    /// Async wrapper for processing
    func processAsync(
        input inputURL: URL,
        output outputURL: URL,
        onProgress: ((Double) -> Void)? = nil
    ) async throws -> URL {
        try await isolateVocals(input: inputURL, output: outputURL, onProgress: onProgress)
    }
    
    /// Cleanup
    func unload() {
        isLoaded = false
    }
}

// MARK: - Errors

enum DemucsError: LocalizedError {
    case binaryNotFound
    case notExecutable
    case notWorking
    case notLoaded
    case executionFailed(String)
    case processingFailed(String)
    case outputNotFound
    
    var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            return "El binario de Demucs no se encontró en la aplicación"
        case .notExecutable:
            return "El binario de Demucs no tiene permisos de ejecución"
        case .notWorking:
            return "Demucs no funciona correctamente"
        case .notLoaded:
            return "Demucs no está cargado. Llama a load() primero"
        case .executionFailed(let error):
            return "Error al ejecutar Demucs: \(error)"
        case .processingFailed(let error):
            return "Procesamiento de Demucs falló: \(error)"
        case .outputNotFound:
            return "Demucs no generó el archivo de salida esperado"
        }
    }
}
