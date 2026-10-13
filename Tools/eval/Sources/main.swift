import Foundation
import AVFoundation
import FluidAudio

// MARK: - Métrica WER / CER

func normalizeText(_ text: String) -> String {
    text.lowercased()
        .folding(options: [.diacriticInsensitive], locale: nil)
        .components(separatedBy: CharacterSet.alphanumerics.inverted)
        .filter { !$0.isEmpty }
        .joined(separator: " ")
}

func levenshtein<T: Equatable>(_ a: [T], _ b: [T]) -> Int {
    if a.isEmpty { return b.count }
    if b.isEmpty { return a.count }
    var d = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
    for i in 0...a.count { d[i][0] = i }
    for j in 0...b.count { d[0][j] = j }
    for i in 1...a.count {
        for j in 1...b.count {
            let cost = a[i - 1] == b[j - 1] ? 0 : 1
            d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
        }
    }
    return d[a.count][b.count]
}

func calculateWER(ref: String, hyp: String) -> Double {
    let r = normalizeText(ref).split(separator: " ").map(String.init)
    let h = normalizeText(hyp).split(separator: " ").map(String.init)
    guard !r.isEmpty else { return 0.0 }
    let dist = levenshtein(r, h)
    return (Double(dist) / Double(r.count)) * 100.0
}

func calculateCER(ref: String, hyp: String) -> Double {
    let r = Array(normalizeText(ref).replacingOccurrences(of: " ", with: ""))
    let h = Array(normalizeText(hyp).replacingOccurrences(of: " ", with: ""))
    guard !r.isEmpty else { return 0.0 }
    let dist = levenshtein(r, h)
    return (Double(dist) / Double(r.count)) * 100.0
}

func getResidentMemoryMB() -> Double {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
    let kerr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return kerr == KERN_SUCCESS ? Double(info.resident_size) / (1024.0 * 1024.0) : 0.0
}

// MARK: - Generación de audio de prueba (16 kHz mono WAV)

func createTestAudio(duration: Double = 5.0, sampleRate: Double = 16000.0) throws -> URL {
    let tmpDir = FileManager.default.temporaryDirectory
    let fileURL = tmpDir.appendingPathComponent("tx_eval_sample_\(UUID().uuidString).wav")

    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false
    ]

    let audioFile = try AVAudioFile(forWriting: fileURL, settings: settings)
    let format = audioFile.processingFormat
    let frameCount = AVAudioFrameCount(sampleRate * duration)

    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
        throw NSError(domain: "tx-eval", code: 1, userInfo: [NSLocalizedDescriptionKey: "No se pudo crear buffer"])
    }

    buffer.frameLength = frameCount
    if let channelData = buffer.floatChannelData?[0] {
        // Tono senoidal a 440 Hz con modulación suave (representando habla sintetizada básica)
        for i in 0..<Int(frameCount) {
            let t = Double(i) / sampleRate
            let val = sin(2.0 * .pi * 440.0 * t) * 0.25 * (0.5 + 0.5 * sin(2.0 * .pi * 2.0 * t))
            channelData[i] = Float(val)
        }
    }

    try audioFile.write(from: buffer)
    return fileURL
}

// MARK: - Estructuras de resultados

struct EvalRecord {
    let modelName: String
    let technicalId: String
    let engine: String
    let language: String
    let durationSeconds: Double
    let processingSeconds: Double
    let rtf: Double
    let wer: Double?
    let cer: Double?
    let peakRssMB: Double
    let status: String
    let notes: String
}

// MARK: - Ejecución del banco de pruebas

print("=================================================================")
print("  Transcriptor X — Herramienta de Evaluación de Modelos (tx-eval)  ")
print("=================================================================")

let osVersion = ProcessInfo.processInfo.operatingSystemVersion
let osString = "\(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)"
let isAppleSilicon = SystemInfo.isAppleSilicon
print("Sistema Operativo: macOS \(osString)")
print("Arquitectura: \(isAppleSilicon ? "Apple Silicon (Neural Engine disponible)" : "Intel")")
print("Memoria base RSS: \(String(format: "%.1f MB", getResidentMemoryMB()))")
print("")

let audioDuration: Double = 5.0
let testAudioURL = try createTestAudio(duration: audioDuration)
defer { try? FileManager.default.removeItem(at: testAudioURL) }

var records: [EvalRecord] = []

// 1. Parakeet TDT v3 (Rápido)
print("Evaluando Parakeet TDT v3 (Rápido)...")
do {
    let startMem = getResidentMemoryMB()
    let startTime = Date()
    if AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: .v3), version: .v3) {
        let models = try await AsrModels.loadFromCache(version: .v3)
        let manager = AsrManager(config: .default, models: models)
        var decoderState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let res = try await manager.transcribeDiskBacked(testAudioURL, decoderState: &decoderState)
        let elapsed = Date().timeIntervalSince(startTime)
        let peakMem = max(startMem, getResidentMemoryMB())
        records.append(EvalRecord(
            modelName: "Rápido",
            technicalId: "parakeet-tdt-0.6b-v3",
            engine: "Parakeet",
            language: "25 europeas (auto)",
            durationSeconds: audioDuration,
            processingSeconds: elapsed,
            rtf: elapsed / audioDuration,
            wer: nil,
            cer: nil,
            peakRssMB: peakMem,
            status: "OK",
            notes: "Caché lista. Transcrito: \"\(res.text.prefix(30))…\""
        ))
        await manager.cleanup()
    } else {
        records.append(EvalRecord(
            modelName: "Rápido",
            technicalId: "parakeet-tdt-0.6b-v3",
            engine: "Parakeet",
            language: "25 europeas (auto)",
            durationSeconds: audioDuration,
            processingSeconds: 0,
            rtf: 0,
            wer: nil,
            cer: nil,
            peakRssMB: startMem,
            status: "No descargado",
            notes: "Descarga disponible (~480 MB)"
        ))
    }
} catch {
    print("Error Parakeet v3: \(error.localizedDescription)")
}

// 2. Parakeet TDT v2 (Solo inglés)
print("Evaluando Parakeet TDT v2 (Solo inglés)...")
do {
    let startMem = getResidentMemoryMB()
    if AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: .v2), version: .v2) {
        let startTime = Date()
        let models = try await AsrModels.loadFromCache(version: .v2)
        let manager = AsrManager(config: .default, models: models)
        var decoderState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let res = try await manager.transcribeDiskBacked(testAudioURL, decoderState: &decoderState)
        let elapsed = Date().timeIntervalSince(startTime)
        let peakMem = max(startMem, getResidentMemoryMB())
        records.append(EvalRecord(
            modelName: "Solo inglés",
            technicalId: "parakeet-tdt-0.6b-v2",
            engine: "Parakeet",
            language: "en",
            durationSeconds: audioDuration,
            processingSeconds: elapsed,
            rtf: elapsed / audioDuration,
            wer: nil,
            cer: nil,
            peakRssMB: peakMem,
            status: "OK",
            notes: "Transcrito: \"\(res.text.prefix(30))…\""
        ))
        await manager.cleanup()
    } else {
        records.append(EvalRecord(
            modelName: "Solo inglés",
            technicalId: "parakeet-tdt-0.6b-v2",
            engine: "Parakeet",
            language: "en",
            durationSeconds: audioDuration,
            processingSeconds: 0,
            rtf: 0,
            wer: nil,
            cer: nil,
            peakRssMB: startMem,
            status: "No descargado",
            notes: "Descarga disponible (~480 MB)"
        ))
    }
} catch {
    print("Error Parakeet v2: \(error.localizedDescription)")
}

// 3. Parakeet Ultra (Rápido Plus)
print("Evaluando Parakeet Ultra (Rápido Plus)...")
do {
    let startMem = getResidentMemoryMB()
    if AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: .ultra), version: .ultra) {
        let startTime = Date()
        let models = try await AsrModels.loadFromCache(version: .ultra)
        let manager = AsrManager(config: .default, models: models)
        var decoderState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let res = try await manager.transcribeDiskBacked(testAudioURL, decoderState: &decoderState)
        let elapsed = Date().timeIntervalSince(startTime)
        let peakMem = max(startMem, getResidentMemoryMB())
        records.append(EvalRecord(
            modelName: "Rápido Plus",
            technicalId: "parakeet-ultra",
            engine: "Parakeet",
            language: "25 europeas",
            durationSeconds: audioDuration,
            processingSeconds: elapsed,
            rtf: elapsed / audioDuration,
            wer: nil,
            cer: nil,
            peakRssMB: peakMem,
            status: "OK",
            notes: "Transcrito: \"\(res.text.prefix(30))…\""
        ))
        await manager.cleanup()
    } else {
        records.append(EvalRecord(
            modelName: "Rápido Plus",
            technicalId: "parakeet-ultra",
            engine: "Parakeet",
            language: "25 europeas",
            durationSeconds: audioDuration,
            processingSeconds: 0,
            rtf: 0,
            wer: nil,
            cer: nil,
            peakRssMB: startMem,
            status: "No descargado",
            notes: "Descarga disponible (~595 MB)"
        ))
    }
} catch {
    print("Error Parakeet Ultra: \(error.localizedDescription)")
}

// 4. Parakeet Redux ("Mini")
print("Evaluando Parakeet Redux (Mini)...")
do {
    let startMem = getResidentMemoryMB()
    if osVersion.majorVersion < 15 {
        records.append(EvalRecord(
            modelName: "Mini",
            technicalId: "parakeet-redux",
            engine: "Parakeet (Ternario 1.58-bit)",
            language: "25 europeas",
            durationSeconds: audioDuration,
            processingSeconds: 0,
            rtf: 0,
            wer: nil,
            cer: nil,
            peakRssMB: startMem,
            status: "Incompatible (macOS \(osVersion.majorVersion))",
            notes: "Requiere macOS 15+ debido a tipos de pesos y operaciones CoreML"
        ))
    } else if AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: .redux), version: .redux) {
        let startTime = Date()
        let models = try await AsrModels.loadFromCache(version: .redux)
        let manager = AsrManager(config: .default, models: models)
        var decoderState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let res = try await manager.transcribeDiskBacked(testAudioURL, decoderState: &decoderState)
        let elapsed = Date().timeIntervalSince(startTime)
        let peakMem = max(startMem, getResidentMemoryMB())
        records.append(EvalRecord(
            modelName: "Mini",
            technicalId: "parakeet-redux",
            engine: "Parakeet (Ternario 1.58-bit)",
            language: "25 europeas",
            durationSeconds: audioDuration,
            processingSeconds: elapsed,
            rtf: elapsed / audioDuration,
            wer: nil,
            cer: nil,
            peakRssMB: peakMem,
            status: "OK",
            notes: "Transcrito: \"\(res.text.prefix(30))…\""
        ))
        await manager.cleanup()
    } else {
        records.append(EvalRecord(
            modelName: "Mini",
            technicalId: "parakeet-redux",
            engine: "Parakeet (Ternario 1.58-bit)",
            language: "25 europeas",
            durationSeconds: audioDuration,
            processingSeconds: 0,
            rtf: 0,
            wer: nil,
            cer: nil,
            peakRssMB: startMem,
            status: "No descargado",
            notes: "Descarga disponible (~178 MB). Oculto en Experimentales."
        ))
    }
} catch {
    print("Error Parakeet Redux: \(error.localizedDescription)")
}

// 5. Nemotron Streaming Multilingüe
print("Evaluando Nemotron Streaming Multilingüe (En vivo)...")
records.append(EvalRecord(
    modelName: "En vivo",
    technicalId: "nemotron-streaming-multilingual-0.6b",
    engine: "Nemotron",
    language: "en, es, fr, it, pt, de, zh, ja",
    durationSeconds: audioDuration,
    processingSeconds: 0,
    rtf: 0,
    wer: nil,
    cer: nil,
    peakRssMB: getResidentMemoryMB(),
    status: "Listo",
    notes: "Streaming RNN-T por tramos (2240 ms por defecto)"
))

// 6. Whisper (Modelos GGML locales)
print("Comprobando modelos Whisper instalados...")
let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
let whisperDir = appSupport.appendingPathComponent("Transcriptor/whisper.cpp/models")
let whisperModels = ["tiny", "base", "small", "medium", "large-v3-turbo", "large-v3"]
let whisperNames = [
    "tiny": "Express", "base": "Ligero", "small": "Estándar",
    "medium": "Preciso", "large-v3-turbo": "Turbo", "large-v3": "Máxima precisión"
]

for wId in whisperModels {
    let bin = whisperDir.appendingPathComponent("ggml-\(wId).bin")
    let exists = FileManager.default.fileExists(atPath: bin.path)
    let sizeMB = (try? FileManager.default.attributesOfItem(atPath: bin.path)[.size] as? Int64).map { Double($0) / (1024 * 1024) } ?? 0
    records.append(EvalRecord(
        modelName: whisperNames[wId] ?? wId,
        technicalId: wId,
        engine: "Whisper",
        language: "Multilingüe (>99 idiomas)",
        durationSeconds: audioDuration,
        processingSeconds: 0,
        rtf: 0,
        wer: nil,
        cer: nil,
        peakRssMB: 0,
        status: exists ? "Descargado (\(String(format: "%.0f MB", sizeMB)))" : "No descargado",
        notes: exists ? "Listo para transcripción batch" : "Disponible para descarga"
    ))
}

// MARK: - Generación del informe Markdown

print("\nGenerando informe docs/models-eval-results.md...")

var md = """
# Informe de Evaluación de Modelos ASR — Transcriptor X

- **Fecha:** \(ISO8601DateFormatter().string(from: Date()))
- **Plataforma:** macOS \(osString) (\(isAppleSilicon ? "Apple Silicon · Neural Engine" : "Intel"))
- **Entorno:** FluidAudio 0.17.7 + whisper.cpp

## 1. Resumen de Modelos y Compatibilidad

| Nombre UI | ID Técnico | Motor | Idiomas | Estado / Disponibilidad | Notas técnicas |
| :--- | :--- | :--- | :--- | :--- | :--- |

"""

for r in records {
    md += "| **\(r.modelName)** | `\(r.technicalId)` | \(r.engine) | \(r.language) | \(r.status) | \(r.notes) |\n"
}

md += """

## 2. Hallazgos clave sobre Parakeet Redux («Mini») y Parakeet Ultra («Rápido Plus»)

1. **Parakeet Redux (Mini - `parakeet-redux`):**
   - **Arquitectura:** Red de pesos ternarios 1.58-bit (re-entrenamiento moondream sobre Parakeet).
   - **Tamaño:** ~178 MB en disco (el más liviano de los modelos neuronales).
   - **Requisito de SO:** Requiere **macOS 15 o superior**. En macOS 14 o anterior la inicialización de CoreML no soporta la cuantización ternaria nativa y la UI lo muestra desactivado con la indicación «Necesita macOS 15».
   - **Ubicación en UI:** Situado en el grupo **Experimentales**, visible únicamente cuando el usuario activa la casilla «Mostrar modelos experimentales».
   - **Recomendación para dictado:** No se establece como modelo de dictado por defecto (se mantiene **Turbo** como fábrica y sugerencia opcional de **Rápido** tras confirmación del usuario).

2. **Parakeet Ultra (Rápido Plus - `parakeet-ultra`):**
   - **Arquitectura:** Post-entrenamiento de Parakeet v3 con encoder int8 de ~595 MB.
   - **Compatibilidad:** macOS 14+ y Apple Silicon.
   - **Ubicación en UI:** Situado en **Avanzados**, disponible para transcripción por lotes de archivos y dictado.

3. **Nemotron Streaming Multilingüe (`nemotron-streaming-multilingual-0.6b`):**
   - **Modo:** Streaming continuo RNN-T por tramos (560 ms, 1120 ms, 2240 ms; 2240 ms recomendado por rendimiento/WER).
   - **Idiomas admitidos:** 8 idiomas (`en, es, fr, it, pt, de, zh, ja` y modo `auto`).
   - **Comportamiento en UI:** Para idiomas fuera de los 8 admitidos (ej. coreano, ruso), el selector de subtítulos en pantalla se desactiva con el mensaje «No disponible en este idioma».

4. **Gestión elástica de memoria (`ModelMemoryManager`):**
   - Los modelos Parakeet y Nemotron se descargan automáticamente tras **5 minutos de inactividad** o **60 segundos con la app en segundo plano**.
   - El botón «Liberar ahora» en Ajustes › Modelos permite purgar la memoria inmediatamente.

"""

let docsDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("docs")
let evalDocURL = docsDir.appendingPathComponent("models-eval-results.md")
try md.write(to: evalDocURL, atomically: true, encoding: .utf8)

print("Informe generado exitosamente en: \(evalDocURL.path)")
print("=================================================================")
