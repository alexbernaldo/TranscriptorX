import Foundation
import AVFoundation

/// Gestor unificado para procesamiento avanzado de audio
/// Coordina DeepFilterNet (reducción de ruido) y HTDemucs (aislamiento de voz)
///
/// Pipeline de procesamiento:
/// 1. DeepFilter: Reduce ruido de fondo (opcional)
/// 2. HTDemucs: Aísla la voz humana (opcional)
/// 3. Resultado: Audio limpio listo para transcripción
///
final class AudioEngineManager {
    
    // Singleton
    static let shared = AudioEngineManager()
    
    // Procesadores
    private let deepFilter = DeepFilterBridge.shared
    private let demucs = DemucsProcessor.shared
    
    // Estado
    private(set) var isInitialized = false
    
    // Configuración de procesamiento
    struct ProcessingOptions {
        var reduceNoise: Bool = false      // DeepFilterNet
        var isolateVoice: Bool = false     // HTDemucs
        var attenuation: Float = 0.7       // 0.0-1.0, cuánto ruido eliminar
        
        static let `default` = ProcessingOptions()
        
        static let noiseReduction = ProcessingOptions(reduceNoise: true)
        static let voiceIsolation = ProcessingOptions(isolateVoice: true)
        static let full = ProcessingOptions(reduceNoise: true, isolateVoice: true)
    }
    
    // MARK: - Initialization
    
    private init() {}
    
    /// Verifica qué procesadores están disponibles
    var availableProcessors: AvailableProcessors {
        AvailableProcessors(
            deepFilter: deepFilter.isAvailable,
            demucs: demucs.isAvailable
        )
    }
    
    struct AvailableProcessors {
        let deepFilter: Bool
        let demucs: Bool
        
        var any: Bool { deepFilter || demucs }
        var all: Bool { deepFilter && demucs }
        
        var description: String {
            var available: [String] = []
            if deepFilter { available.append("DeepFilter") }
            if demucs { available.append("HTDemucs") }
            return available.isEmpty ? "Ninguno" : available.joined(separator: ", ")
        }
    }
    
    /// Inicializa los procesadores disponibles
    func initialize() async throws {
        guard !isInitialized else { return }
        
        print("🎛️ AudioEngine: Inicializando procesadores de audio...")
        
        // Cargar DeepFilter si está disponible
        if deepFilter.isAvailable {
            try deepFilter.load()
            print("  ✅ DeepFilterNet v3 listo")
        } else {
            print("  ⚠️ DeepFilterNet no disponible (libdeepfilter.dylib no encontrada)")
        }
        
        // Cargar HTDemucs si está disponible
        if demucs.isAvailable {
            try await demucs.load()
            print("  ✅ HTDemucs listo (Neural Engine)")
        } else {
            print("  ⚠️ HTDemucs no disponible (modelo CoreML no encontrado)")
        }
        
        isInitialized = true
        print("🎛️ AudioEngine: Inicialización completada - Disponibles: \(availableProcessors.description)")
    }
    
    // MARK: - Processing
    
    /// Procesa audio aplicando los filtros configurados
    /// - Parameters:
    ///   - inputURL: Audio de entrada
    ///   - options: Opciones de procesamiento
    ///   - onProgress: Callback de progreso (0.0 - 1.0)
    /// - Returns: URL del audio procesado
    func processAudio(
        input inputURL: URL,
        options: ProcessingOptions = .default,
        onProgress: ((Double, String) -> Void)? = nil
    ) async throws -> URL {
        // Si no hay procesamiento, retornar original
        guard options.reduceNoise || options.isolateVoice else {
            return inputURL
        }
        
        // Crear directorio temporal para intermedios
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioEngine-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        var currentURL = inputURL
        var totalSteps = (options.reduceNoise ? 1 : 0) + (options.isolateVoice ? 1 : 0)
        var currentStep = 0
        
        // Paso 1: DeepFilter (reducción de ruido)
        if options.reduceNoise {
            onProgress?(Double(currentStep) / Double(totalSteps), "Reduciendo ruido...")
            
            if deepFilter.isAvailable {
                let denoised = tempDir.appendingPathComponent("denoised.wav")
                deepFilter.attenuation = options.attenuation
                currentURL = try deepFilter.processFile(input: currentURL, output: denoised)
                print("  🔇 Ruido reducido: \(inputURL.lastPathComponent)")
            } else {
                print("  ⚠️ DeepFilter no disponible, saltando reducción de ruido")
            }
            
            currentStep += 1
        }
        
        // Paso 2: HTDemucs (aislamiento de voz)
        if options.isolateVoice {
            onProgress?(Double(currentStep) / Double(totalSteps), "Aislando voz...")
            
            if demucs.isAvailable {
                let vocals = tempDir.appendingPathComponent("vocals.wav")
                currentURL = try await demucs.isolateVocals(input: currentURL, output: vocals) { progress in
                    let overall = (Double(currentStep) + progress) / Double(totalSteps)
                    onProgress?(overall, "Aislando voz... \(Int(progress * 100))%")
                }
                print("  🎤 Voz aislada: \(inputURL.lastPathComponent)")
            } else {
                print("  ⚠️ HTDemucs no disponible, saltando aislamiento de voz")
            }
            
            currentStep += 1
        }
        
        onProgress?(1.0, "Procesamiento completado")
        
        return currentURL
    }
    
    /// Procesa audio con configuración simplificada
    func processForTranscription(
        _ url: URL,
        reduceNoise: Bool,
        isolateVoice: Bool,
        onProgress: ((Double, String) -> Void)? = nil
    ) async throws -> URL {
        let options = ProcessingOptions(
            reduceNoise: reduceNoise,
            isolateVoice: isolateVoice
        )
        return try await processAudio(input: url, options: options, onProgress: onProgress)
    }
    
    // MARK: - Cleanup
    
    /// Limpia recursos
    func cleanup() {
        deepFilter.unload()
        demucs.unload()
        isInitialized = false
        
        // Limpiar archivos temporales
        let tempDir = FileManager.default.temporaryDirectory
        if let contents = try? FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil) {
            for item in contents where item.lastPathComponent.hasPrefix("AudioEngine-") {
                try? FileManager.default.removeItem(at: item)
            }
        }
    }
}

// MARK: - Convenience Extensions

extension AudioEngineManager {
    /// Verifica si el procesamiento avanzado está disponible
    var isAdvancedProcessingAvailable: Bool {
        availableProcessors.any
    }
    
    /// Descripción del estado para UI
    var statusDescription: String {
        if !isInitialized {
            return "No inicializado"
        }
        
        let available = availableProcessors
        if available.all {
            return "Todos los procesadores activos"
        } else if available.deepFilter {
            return "Solo reducción de ruido disponible"
        } else if available.demucs {
            return "Solo aislamiento de voz disponible"
        } else {
            return "Sin procesadores disponibles"
        }
    }
}
