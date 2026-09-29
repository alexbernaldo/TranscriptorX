# Changelog

Todas las novedades relevantes de TranscriptorX se registran en este fichero.

El formato sigue [Keep a Changelog](https://keepachangelog.com/es-ES/1.1.0/) y
el proyecto usa [versionado semántico](https://semver.org/lang/es/).

## [No publicado]

### Añadido

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

[No publicado]: https://github.com/alexbernaldo/TranscriptorX/compare/v2.0...HEAD
[2.0]: https://github.com/alexbernaldo/TranscriptorX/releases/tag/v2.0
