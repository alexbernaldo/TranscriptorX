# AudioEngine - Procesamiento de Audio Avanzado

Módulo de procesamiento de audio profesional para TranscriptorNative.
Proporciona reducción de ruido y aislamiento de voz de alta calidad.

## Componentes

### 1. DeepFilterNet (Reducción de Ruido)
- **Tecnología**: DeepFilterNet v3 (Rust)
- **Rendimiento**: ~0.2x tiempo real (1 min audio → 10 seg procesamiento)
- **Calidad**: Estado del arte, mejor que RNNoise
- **Wrapper**: `DeepFilterBridge.swift`

### 2. HTDemucs (Aislamiento de Voz)
- **Tecnología**: Hybrid Transformer Demucs (CoreML)
- **Aceleración**: Neural Engine (M1/M2/M3/M4)
- **Calidad**: Separación quirúrgica de voz
- **Wrapper**: `DemucsProcessor.swift`

### 3. AudioEngineManager (API Unificada)
- Coordina ambos procesadores
- Maneja fallbacks automáticamente
- Progreso unificado para UI

## Uso en Código

```swift
// Inicializar
try await AudioEngineManager.shared.initialize()

// Verificar disponibilidad
let available = AudioEngineManager.shared.availableProcessors
print("DeepFilter: \(available.deepFilter)")
print("HTDemucs: \(available.demucs)")

// Procesar audio
let processedURL = try await AudioEngineManager.shared.processAudio(
    input: audioURL,
    options: AudioEngineManager.ProcessingOptions(
        reduceNoise: true,
        isolateVoice: true
    )
) { progress, status in
    print("\(Int(progress * 100))%: \(status)")
}
```

## Compilación de Dependencias

### DeepFilterNet (Rust → dylib)

```bash
# 1. Instalar Rust
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
source ~/.cargo/env

# 2. Clonar DeepFilterNet
git clone https://github.com/Rikorose/DeepFilterNet.git
cd DeepFilterNet

# 3. Compilar la librería con C API
cd libDF
cargo build --release --features capi

# 4. El dylib está en:
# target/release/libdeep_filter_ladspa.dylib

# 5. Renombrar y copiar:
cp target/release/libdeep_filter_ladspa.dylib \
   /path/to/TranscriptorNative/AudioEngine/lib/libdeepfilter.dylib

# 6. Descargar modelo (si no está incluido):
# El modelo df_v3_48kHz.onnx (~5MB) se descarga automáticamente
# o puedes obtenerlo de: https://github.com/Rikorose/DeepFilterNet/releases
```

### HTDemucs (PyTorch → CoreML)

```bash
# 1. Crear entorno virtual
python3 -m venv demucs_env
source demucs_env/bin/activate

# 2. Instalar dependencias
pip install torch torchaudio coremltools demucs

# 3. Crear script de conversión (convert_demucs.py):
```

```python
# convert_demucs.py
import torch
import coremltools as ct
from demucs.pretrained import get_model

# Cargar modelo
model = get_model('htdemucs')
model.eval()

# Trace con input dummy (batch, channels, samples)
# 10 segundos a 44.1kHz stereo
dummy_input = torch.randn(1, 2, 441000)

with torch.no_grad():
    traced = torch.jit.trace(model, dummy_input)

# Convertir a CoreML
mlmodel = ct.convert(
    traced,
    inputs=[ct.TensorType(name="audio", shape=dummy_input.shape)],
    outputs=[ct.TensorType(name="vocals")],
    compute_precision=ct.precision.FLOAT16,  # Neural Engine optimizado
    compute_units=ct.ComputeUnit.ALL
)

# Guardar - esto crea un directorio .mlpackage
mlmodel.save("htdemucs_vocals.mlpackage")

print("✅ Modelo convertido. Ahora compila con xcrun:")
print("xcrun coremlcompiler compile htdemucs_vocals.mlpackage .")
```

```bash
# 4. Ejecutar conversión
python convert_demucs.py

# 5. Compilar para Neural Engine
xcrun coremlcompiler compile htdemucs_vocals.mlpackage .

# 6. Copiar a proyecto
cp -r htdemucs_vocals.mlmodelc \
   /path/to/TranscriptorNative/AudioEngine/Models/
```

## Estructura de Archivos

```
AudioEngine/
├── README.md                     # Este archivo
├── lib/
│   └── libdeepfilter.dylib       # Compilar desde Rust
├── Models/
│   └── htdemucs_vocals.mlmodelc/ # Convertir desde PyTorch
├── DeepFilterBridge.swift        # Wrapper Swift para Rust
├── DemucsProcessor.swift         # Wrapper Swift para CoreML
└── AudioEngineManager.swift      # API unificada
```

## Integración con Xcode

1. **Agregar archivos Swift al target**:
   - DeepFilterBridge.swift
   - DemucsProcessor.swift
   - AudioEngineManager.swift

2. **Agregar libdeepfilter.dylib**:
   - Arrastrar a "Frameworks, Libraries, and Embedded Content"
   - Marcar como "Embed & Sign"

3. **Agregar htdemucs_vocals.mlmodelc**:
   - Arrastrar a Resources
   - Asegurar que está en "Copy Bundle Resources"

4. **Entitlements**:
   - Ya tienes los necesarios (Audio Input, User Selected File)

## Notas de Rendimiento

| Procesador | Audio 1 min | Apple Silicon |
|------------|-------------|---------------|
| DeepFilter | ~10 seg     | M1: 8s, M2: 6s |
| HTDemucs   | ~20 seg     | Neural Engine |
| Combinado  | ~30 seg     | Parallelizable |

## Fallbacks

Si los procesadores no están disponibles:
- El toggle en UI se muestra como "Próximamente"
- El audio pasa sin modificar al siguiente paso
- No hay error, solo warning en logs
