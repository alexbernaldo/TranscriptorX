# Changelog

Todas las novedades relevantes de Transcriptor X se registran en este fichero.

El formato sigue [Keep a Changelog](https://keepachangelog.com/es-ES/1.1.0/) y
el proyecto usa [versionado semántico](https://semver.org/lang/es/).

## [No publicado]

## [4.1.0] - 2026-10-18

### Added

- Model catalogue: models are downloaded on demand from Settings, and a picker chooses which model each job, recording or dictation uses. Each entry shows its name, task and whether it is in use.
- Parakeet engine alongside Whisper, with speaker identification and a memory manager that keeps long recordings from filling RAM.
- Nemotron Streaming for live transcription: the Live view and a floating panel show the text as you speak.
- Live subtitles for system audio recording, available as soon as it starts.
- New CLI with `--plain` output, a `model=` link parameter and license handling; the shortcuts run the same functions through App Intents.
- `tx-eval` evaluation tool and its report under `docs/`.
- Dictation picks the model itself, shows download progress and gains a model selector.

### Changed

- Automatic now resolves the model for jobs, recordings, dictation and shortcuts, and it is the factory default. Nothing is downloaded implicitly.
- A missing model is downloaded when a function needs it, and "Manage models…" is removed from where it only duplicated Settings.
- The Record button always opens its options first.
- The Dock icon follows the window: with "Hide from Dock" on, the icon is shown while a window is open.

### Fixed

- An empty audio file is reported as such instead of failing quietly.
- FFmpeg runs quietly and its errors are reported without banner noise.

## [4.0.2] - 2026-10-12

### Fixed

- Closing the window no longer quits the app when "Keep running when the window closes" is on and a utility that quits windowless apps (such as Swift Quit) is installed. Those quit requests are ignored and logged; ⌘Q, Quit, the Dock, other apps, logging out and updates still quit as usual.

## [4.0.1] - 2026-10-12

### Changed

- Record is a single button: the first time it asks for the source; afterwards it is changed in Settings › Recording or with right-click › "Recording Sources…".

### Fixed

- The app tells the quits you ask for (⌘Q, Quit, the Dock, another app, logging out, updates) apart from the ones it sends itself while living in the menu bar, and logs which app asked for each quit.

## [4.0] - 2026-10-11

### Added

- Dictation inspired by Handy: configurable shortcut with Automatic, Hold and Press modes; Esc or ✕ cancel, even while transcribing; animated capsule that follows your voice; paste through the clipboard and restore it, type directly or copy only; send with Return or ⌘Return; its own microphone, model and language; custom words; filler-word removal; sounds and speaker muting.
- "Hide from Dock": the app can live only in the menu bar.
- Home options as always-visible icons, each with an ⓘ that explains it, and a Settings button in the toolbar.
- Menu bar: dictate, finish, cancel and copy the last dictation.
- Speaker identification benchmark (`Tools/DiarizationBench`) and a raw-turns diagnostic mode.

### Changed

- Home and Settings › Language share one configuration, synced both ways.
- Automatic language detection by default, presets included.
- Record lives only in the centre of Home; "+" is a plain button.
- The app is signed with a stable identity so macOS keeps its permissions across versions.

### Fixed

- With "Skip silences", word timestamps were shifted from the audio: speakers were assigned wrongly (47% of words right, now 99.8%) and playback highlighting drifted.
- Microphone and calendar access were silently denied because their hardened-runtime entitlements were missing.
- Internal links to Settings did not open the window on macOS 14 and later.

## [3.0] - 2026-10-11

Rediseño completo de la interfaz según `Transcriptor-X-especificacion-diseno.md`.

### Cambiado

- Requiere **macOS 14 (Sonoma)** o posterior (antes macOS 13), por la diarización.
- La aplicación se llama **Transcriptor X** en el Dock, el menú, Finder y el DMG
  (antes TranscriptorNative / TranscriptorX). El identificador de paquete y la
  carpeta de datos no cambian, así que el historial se conserva.
- Ventana única con historial y cola en la misma lista, área de trabajo e
  inspector (Hablantes, IA, Traducción, Detalles); apariencia oscura por defecto.
- Editor por segmentos con modos Lectura y Edición, dividir en el cursor por
  tiempo de palabra, unir, ajustar tiempos, buscar y reemplazar y deshacer.
- Ajustes en once secciones, asistente de primer arranque en cuatro pasos y menú
  de barra nativo.
- Ningún permiso se pide al arrancar: micrófono, calendario y accesibilidad solo
  cuando se usan.

### Añadido

- **Identificar hablantes** que funciona con cualquier modelo e idioma: diarización
  local con FluidAudio (pyannote community-1, WeSpeaker y VBx en Core ML), el mismo
  enfoque que usa MacWhisper. Los segmentos se dividen por palabra donde cambia
  el hablante. El modelo (~21 MB) se descarga de Hugging Face la primera vez.
- Prioridad en la cola, espera de modelo, reencolar tras cancelar y trabajos de
  enlace dentro de la cola.
- Chat local con la transcripción (dura la sesión) y selector de proveedor de IA.
- Icono nuevo (Icon Composer) e icono de documento `.transcriptor`.
- Target de pruebas unitarias `TranscriptorNativeTests`.
- `scripts/make_background.swift`: dibuja el fondo del DMG con SF Symbols y la
  tipografía del sistema (flecha nítida a 2x y texto de instalación en español
  e inglés).
- `scripts/build_dmg.py`: empaquetado del DMG "drag to install" con fondo,
  tamaño de ventana y posición de los iconos aplicados por el propio Finder,
  de la misma forma que create-dmg e install4j.

## [2.0] - 2026-09-29

Primera publicación pública del proyecto.

### Añadido

- Transcripción de audio grabado con el micrófono o capturado del audio del
  sistema.
- Importación de ficheros de audio locales para transcribir.
- Transcripción a partir de una URL (YouTube), sin intervención manual.
- Motor de audio local: separación de voces con **Demucs** y reducción de ruido
  con **DeepFilterNet**, empaquetados dentro de la aplicación.
- Integración con **whisper.cpp** y modelos GGML descargados en el primer uso.
- Gestión de modelos, cola de trabajos y recuperación de sesiones interrumpidas.
- Exportación de las transcripciones a distintos formatos.
- Interfaz en español e inglés a partir de un único catálogo de localización
  (`Localizable.xcstrings`).
- Imagen de disco de instalación (`.dmg`) y binarios del motor de audio
  publicados como assets del Release.
- `scripts/fetch_binaries.sh` para obtener los binarios del motor de audio al
  clonar el repositorio.
- `scripts/check_localization.py`, comprobación de que toda clave usada en el
  código existe en el catálogo y tiene versión española e inglesa.

### Cambiado

- Identificador de paquete: `io.github.alexbernaldo.transcriptorx`.
- La licencia del proyecto pasa a ser **PolyForm Noncommercial 1.0.0**: uso
  personal libre, uso comercial prohibido.
- Avisos de licencia de terceros añadidos (`THIRD_PARTY_NOTICES.md` y `licenses/`).

### Notas

- La aplicación se distribuye sin firmar. En otros Mac, ábrela con clic derecho
  → *Abrir*, o ejecuta `xattr -dr com.apple.quarantine /ruta/a/TranscriptorX.app`.
- Compilada para Apple Silicon (`arm64`), requiere macOS 13 o superior.

[No publicado]: https://github.com/alexbernaldo/TranscriptorX/compare/v3.0...HEAD
[3.0]: https://github.com/alexbernaldo/TranscriptorX/releases/tag/v3.0
[2.0]: https://github.com/alexbernaldo/TranscriptorX/releases/tag/v2.0
