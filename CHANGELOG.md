# Changelog

Todas las novedades relevantes de Transcriptor X se registran en este fichero.

El formato sigue [Keep a Changelog](https://keepachangelog.com/es-ES/1.1.0/) y
el proyecto usa [versionado semántico](https://semver.org/lang/es/).

## [No publicado]

## [4.0] - 2026-10-11

### Añadido

- Dictado inspirado en Handy: atajo configurable con modos Automático, Mantener y Pulsar; Esc o ✕ cancelan, también durante la transcripción; cápsula animada con onda de voz; pegado por portapapeles que lo restaura, escritura directa o solo copiar; envío con Intro o ⌘Intro; micrófono, modelo e idioma propios; palabras personalizadas; quitar muletillas; sonidos y silenciar altavoces.
- «Ocultar del Dock»: la app puede vivir solo en la barra de menús.
- Opciones de Inicio como iconos siempre visibles, con ⓘ que explica cada una, y botón de Ajustes en la barra de herramientas.
- Menú de la barra: dictar, terminar, cancelar y copiar el último dictado.
- Banco de pruebas de identificación de hablantes (`Tools/DiarizationBench`) y modo diagnóstico de turnos.

### Cambiado

- Inicio y Ajustes › Idioma comparten la misma configuración, sincronizada en los dos sentidos.
- Detección automática del idioma por defecto, también en los presets.
- Grabar vive solo en el centro de Inicio (con su selector de fuentes); «+» es un botón simple.
- La app se firma con una identidad estable para que macOS conserve los permisos entre versiones.

### Corregido

- Con «Saltar silencios», los tiempos de palabra quedaban desplazados respecto al audio: los hablantes se asignaban mal (47 % de palabras correctas, ahora 99,8 %) y el resaltado al reproducir se desfasaba.
- El micrófono y el calendario se denegaban en silencio por faltar sus entitlements con hardened runtime.
- Los enlaces internos a Ajustes no abrían la ventana en macOS 14 o posterior.

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
