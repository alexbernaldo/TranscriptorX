#!/usr/bin/env python3
"""
Script para convertir HTDemucs de PyTorch a CoreML

Uso:
    python3 convert_demucs.py

Resultado:
    - htdemucs_vocals.mlpackage (modelo CoreML)
    
Después de ejecutar, compila con:
    xcrun coremlcompiler compile htdemucs_vocals.mlpackage .
"""

import torch
import coremltools as ct
from demucs.pretrained import get_model
from demucs.apply import apply_model
import numpy as np

def main():
    print("🎵 Cargando modelo HTDemucs...")
    
    # Cargar modelo pre-entrenado
    # htdemucs es el modelo híbrido con transformer
    model = get_model('htdemucs')
    
    # Si es BagOfModels, extraer el primer modelo
    if hasattr(model, 'models'):
        print(f"   - BagOfModels con {len(model.models)} modelos")
        model = model.models[0]
    
    model.cpu()
    model.eval()
    
    print(f"✅ Modelo cargado")
    print(f"   - Sample rate: {model.samplerate}")
    print(f"   - Sources: {model.sources}")  # ['drums', 'bass', 'other', 'vocals']
    
    # Encontrar el índice de vocals
    vocals_idx = model.sources.index('vocals')
    print(f"   - Vocals index: {vocals_idx}")
    
    # Crear wrapper que solo extrae vocals
    class VocalsExtractor(torch.nn.Module):
        def __init__(self, model, vocals_idx):
            super().__init__()
            self.model = model
            self.vocals_idx = vocals_idx
            
        def forward(self, x):
            # x: [batch, channels, samples]
            # Añadir padding si es necesario
            length = x.shape[-1]
            
            # Demucs espera longitud múltiplo de su stride
            segment = self.model.segment * self.model.samplerate
            
            # Aplicar modelo
            with torch.no_grad():
                sources = self.model(x)
                # sources: [batch, sources, channels, samples]
                vocals = sources[:, self.vocals_idx, :, :]
            
            return vocals
    
    # Crear extractor
    extractor = VocalsExtractor(model, vocals_idx)
    extractor.eval()
    
    # Input de ejemplo: 10 segundos de audio estéreo
    duration = 10  # segundos
    sample_rate = model.samplerate  # 44100
    example_input = torch.randn(1, 2, sample_rate * duration)
    
    print(f"\n📐 Input shape: {example_input.shape}")
    print(f"   - Batch: 1")
    print(f"   - Channels: 2 (stereo)")
    print(f"   - Samples: {sample_rate * duration} ({duration}s @ {sample_rate}Hz)")
    
    # Verificar que funciona
    print("\n🧪 Probando modelo...")
    with torch.no_grad():
        test_output = extractor(example_input)
    print(f"✅ Output shape: {test_output.shape}")
    
    # Trazar el modelo
    print("\n⚙️ Tracing modelo con TorchScript...")
    try:
        traced_model = torch.jit.trace(extractor, example_input)
        print("✅ Modelo traceado correctamente")
    except Exception as e:
        print(f"❌ Error al tracear: {e}")
        print("\n⚠️ HTDemucs usa operaciones complejas (FFT, attention)")
        print("   Intentando conversión alternativa...")
        
        # Alternativa: usar script en lugar de trace
        try:
            scripted_model = torch.jit.script(extractor)
            traced_model = scripted_model
            print("✅ Modelo scripteado correctamente")
        except Exception as e2:
            print(f"❌ Error al scriptear: {e2}")
            print("\n💡 Recomendación: Usar el modelo completo de Demucs como CLI")
            return
    
    # Convertir a CoreML
    print("\n🔄 Convirtiendo a CoreML...")
    print("   (Esto puede tardar varios minutos)")
    
    try:
        mlmodel = ct.convert(
            traced_model,
            inputs=[
                ct.TensorType(
                    name="audio",
                    shape=example_input.shape,
                    dtype=np.float32
                )
            ],
            outputs=[
                ct.TensorType(name="vocals")
            ],
            convert_to="mlprogram",
            compute_precision=ct.precision.FLOAT16,  # Optimizado para Neural Engine
            minimum_deployment_target=ct.target.macOS13,
        )
        
        # Guardar
        output_path = "htdemucs_vocals.mlpackage"
        mlmodel.save(output_path)
        print(f"\n✅ Modelo guardado: {output_path}")
        print("\n📋 Siguiente paso:")
        print(f"   xcrun coremlcompiler compile {output_path} .")
        print("   Luego copia htdemucs_vocals.mlmodelc/ a AudioEngine/Models/")
        
    except Exception as e:
        print(f"\n❌ Error en conversión: {e}")
        print("\n💡 HTDemucs es muy complejo para conversión directa.")
        print("   Alternativa: Usar Demucs CLI como subproceso")
        print("   Instalado con: pip install demucs")
        print("   Uso: demucs --two-stems=vocals input.wav")

if __name__ == "__main__":
    main()
