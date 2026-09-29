# UX Copy Audit (Views)

Fecha: 2026-02-18
Ámbito: `TranscriptorNative/Views/**/*.swift`

## Resumen
- Se revisaron textos visibles y `accessibilityLabel`/`accessibilityHint`.
- Se aplicó una corrección adicional de capitalización:
  - `"Empezar a Grabar"` → `"Empezar a grabar"` en `RecordingFloatingPanel.swift`.
- Estado general: **consistente con español + sentence case**, con excepciones justificadas.

## Convención macOS (accesibilidad)
- Revisado: uso de "haz clic" frente a "toca/pulsa".
- Estado: **alineado** en hints principales.

## Excepciones justificadas (no cambiar)
- Nombres propios/marca técnica:
  - `Neural Engine`, `CoreML`, `Whisper`, `DeepFilterNet`, `Demucs`, `TranscriptorX`.
- Idiomas mostrados en su idioma nativo en pickers:
  - `Français`, `Deutsch`, `Italiano`, `Português`, `日本語`, `中文`.
- Etiquetas de sección en mayúsculas heredadas del diseño:
  - Ejemplo: `"FUENTE DE AUDIO"`, `"DETECCIÓN DE VOZ"`, `"FORMATO DE SALIDA"`.

## Candidatos opcionales (estilo, no errores)
- `"Plataformas soportadas"` (válido; alternativa: `"Plataformas compatibles"`).
- `"Ver logs"` / `"Logs técnicos"` (válido; alternativa más neutral: `"Ver registro"` / `"Registro técnico"`).

## Verificación
- Build: `BUILD SUCCEEDED` después de la pasada.
