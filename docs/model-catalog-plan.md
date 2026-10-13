# Plan: nuevo sistema de modelos (fase 1 · inventario)

Rama: `feature/model-catalog` (creada desde `feature/tx-planes`, HEAD `cc67847`).

## 1. Lo que hay en el código real

| Tema | Realidad verificada |
|---|---|
| Catálogo Whisper | `TranscriptionService.availableModels` (`Services/TranscriptionService.swift:100-164`, 7 modelos, `filename` + `downloadURL` HF). Hay **otra** tabla con nombres/calidad en `ModelInfo.allModels` (`Models/Models.swift`, ~L291-362) y una tercera vista, `ModelCapabilities.catalogue` (`Workspace/Home/QuickSettingsModel.swift`). Tres fuentes de verdad. |
| Defecto | `TranscriptionSettings.selectedModelId = "base"` (`Models.swift:368`). |
| Presets | `Models.swift:417-451`: lecture→large-v3, podcast→medium, interview→large-v3-turbo. Coincide. |
| Dictado | `DictationSupport.swift:94-99`: `dictation.model` (`useDefault`) → `settings.selectedModelId`. Coincide. |
| `isEnglishOnly` | `QuickSettingsModel.swift:224`. **Sí se usa** (QuickSettingsView, TranslationTab, AppDelegate:219, DictationSupport:99), pero siempre devuelve `false` (ningún modelo `.en`). |
| Motor whisper | **Proceso externo** `whisper-cli` (`Process`, `TranscriptionService.swift:21, 760, 852`), segmentos leídos de stdout. No hay contexto whisper en proceso. |
| Silero VAD | Vía `--vad --vad-model` de `whisper-cli` (coincide). |
| Diarización | `Services/SpeakerDiarizationService.swift`, FluidAudio `OfflineDiarizerManager`, ya independiente del motor (`diarize(file:)` → `[SpeakerTurn]`, asignación en `SpeakerAssignment.swift`). Con Parakeet no hará falta cambiar el cableado. Tiene `unload()`. |
| Persistencia | `TranscriptionDatabase.swift`: tabla `transcriptions(id, payload JSON, title, created_at, duration, is_favorite, language, deleted_at)`; sin `user_version` ni sistema de migraciones. |
| CLI/Intents | `CLI/tx/main.swift` + `Services/CLIServer.swift:122` (`req.model` → `selectedModelId`); `App/Intents/TranscribeFileIntent.swift:34`. |
| Descargas | `Services/ModelDownloadCenter.swift` (solo URLs HF de ggml). |
| Ajustes | `Workspace/Settings/SettingsView.swift`: `ModelTable` (L300), selector de dictado (L639-730). |

## 2. Discrepancias con el prompt (bloqueantes marcadas con ⛔)

1. ⛔ **No existe el «gestor elástico»** de memoria (descarga tras 5 min / 60 s en segundo plano). Solo hay un monitor de presión de memoria (`AppDelegate.swift:154`) y `SpeakerDiarizationService.unload()`. Whisper vive en un subproceso que muere al terminar. Hay que **crear** el gestor, no «meter modelos en él».
2. ⛔ **No existe modo en vivo con whisper.cpp.** `RecordingController.swift:9` dice: «no live text while recording». Los subtítulos en vivo son una función **nueva**, y «mantén el modo en vivo de whisper.cpp como alternativa» no tiene sustrato. Sin Nemotron no habría subtítulos en vivo para idiomas fuera de sus 8.
3. ⛔ **Nombres ya en uso con otro significado.** Hoy «Rápido» = `base`, «Preciso» = `small`/`medium` según tabla («Equilibrado» = small, «Profesional» = turbo, «Máxima Calidad» = large-v3). El prompt reasigna «Rápido» a Parakeet y «Preciso» a medium. Los usuarios con `base` verían cambiar el significado del nombre.
4. **FluidAudio resuelto = 0.17.7** (`Package.resolved`), no 0.12.4. Los fuentes no están en ningún checkout local (el DerivedData del proyecto solo tiene Sparkle); hay que resolver paquetes para leer la API real antes de codificar (`StreamingNemotron*`, `AsrModels`, Ultra, Cohere).
5. `docs/macwhisper-analysis.md` está sin versionar (untracked) en la rama de partida.
6. Estoy en `feature/tx-planes` con trabajo previo; la nueva rama parte de ahí.
7. Tamaños: la UI actual usa cadenas fijas (`size: "1.6 GB"`). El prompt exige leerlos de manifiesto/disco: hay que quitar esas cadenas.
8. No existe un test target con `ModelResolver`; `TranscriptorNativeTests/` tiene 3 ficheros XCTest.

## 3. Plan (archivos a tocar)

- **F2 Abstracción**: nuevos `Models/ModelCatalog.swift` (ModelDescriptor, ModelCatalog, tabla orientativa Velocidad/Precisión), `Services/Engines/TranscriptionEngine.swift`, `WhisperCLIEngine` (envuelve el actual sin cambios), `Services/ModelResolver.swift`, `Models/ModelAssignment.swift`. Migraciones: `TranscriptionDatabase` (PRAGMA user_version + `ALTER TABLE ... ADD COLUMN model_id, engine` idempotente), claves nuevas en `UserDefaults`. Tests: resolver, migración, filtros.
- **F3 UI (solo Whisper)**: `QuickSettingsView/Model`, `RecordPopover`, `SettingsView` (Modelos), `SidebarView` pie, `JobView/JobPresentation`, `DocumentView` cabecera, `InspectorView`, `DictationOverlay`, menú de barra, banners, presets.
- **F4 Parakeet**: `ParakeetEngine`, descarga/carga desde disco, gestor de memoria, sugerencia de dictado.
- **F5 Nemotron + subtítulos en vivo** (pantalla nueva).
- **F7 CLI/Intents/URL, licencias, Localizable.xcstrings**.
- **Eval**: `Tools/eval/` (script + estructura `es/{dictado,entrevista,clase}`).

## 4. Preguntas para el usuario antes de seguir
Ver informe en el chat (puntos 1-3 de la sección 2).

## 5. Estado de cierre (sesión de verificación)

- «Automático» ya no se guarda como ID: `ModelSelection.prepare` lo resuelve al crear el trabajo, el dictado y los Atajos.
- Red: `FluidNetworkGate` mantiene `ModelHub.offlineMode` activo; solo «Descargar» (y la primera descarga del modelo de hablantes) lo abre.
  Sparkle conserva su comprobación semanal automática (decisión anterior, ajena a los modelos): revisar si choca con «nada de red sin acción del usuario».
- Texto en vivo: `LiveTranscription` (Nemotron) alimenta la vista En vivo, el panel flotante y los subtítulos.
- Pendiente de tu parte: probar con modelos descargados (Parakeet y Nemotron en español), audios para `Tools/eval/es/…` y una copia de tu base de datos real.
