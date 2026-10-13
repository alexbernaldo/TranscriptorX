# Informe de Evaluación de Modelos ASR — Transcriptor X

> **Prueba técnica, sin valor para elegir modelo.** Este informe solo lista el catálogo y qué había
> descargado en el Mac de desarrollo. **No se transcribió ningún audio**: no existe `Tools/eval/es/{dictado,entrevista,clase}/`
> y no hay WER, CER, RTF ni memoria medidos. Las escalas de Velocidad y Precisión (1–5) de la UI son orientativas.
> Para medir de verdad: copiar los audios y sus referencias `.txt` a `Tools/eval/es/…` y ejecutar
> `swift run --package-path Tools/eval tx-eval`. Turbo sigue siendo el modelo de fábrica del dictado.
>
> El estado «Descargado/Listo» de la tabla es el de la fecha del informe y no es fiable para Nemotron
> (la ruta de comprobación estaba mal; corregida después en `ModelStorageService`).

- **Fecha:** 2026-10-13T11:28:10Z
- **Plataforma:** macOS 27.0.1 (Apple Silicon · Neural Engine)
- **Entorno:** FluidAudio 0.17.7 + whisper.cpp

## 1. Resumen de Modelos y Compatibilidad

| Nombre UI | ID Técnico | Motor | Idiomas | Estado / Disponibilidad | Notas técnicas |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Rápido** | `parakeet-tdt-0.6b-v3` | Parakeet | 25 europeas (auto) | No descargado | Descarga disponible (~480 MB) |
| **Solo inglés** | `parakeet-tdt-0.6b-v2` | Parakeet | en | No descargado | Descarga disponible (~480 MB) |
| **Rápido Plus** | `parakeet-ultra` | Parakeet | 25 europeas | No descargado | Descarga disponible (~595 MB) |
| **Mini** | `parakeet-redux` | Parakeet (Ternario 1.58-bit) | 25 europeas | No descargado | Descarga disponible (~178 MB). Oculto en Experimentales. |
| **En vivo** | `nemotron-streaming-multilingual-0.6b` | Nemotron | en, es, fr, it, pt, de, zh, ja | Listo | Streaming RNN-T por tramos (2240 ms por defecto) |
| **Express** | `tiny` | Whisper | Multilingüe (>99 idiomas) | No descargado | Disponible para descarga |
| **Ligero** | `base` | Whisper | Multilingüe (>99 idiomas) | Descargado (141 MB) | Listo para transcripción batch |
| **Estándar** | `small` | Whisper | Multilingüe (>99 idiomas) | No descargado | Disponible para descarga |
| **Preciso** | `medium` | Whisper | Multilingüe (>99 idiomas) | No descargado | Disponible para descarga |
| **Turbo** | `large-v3-turbo` | Whisper | Multilingüe (>99 idiomas) | No descargado | Disponible para descarga |
| **Máxima precisión** | `large-v3` | Whisper | Multilingüe (>99 idiomas) | Descargado (2952 MB) | Listo para transcripción batch |

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
