---
name: Reportar un fallo
about: Algo no funciona como debería
title: "[bug] "
labels: bug
assignees: ''
---

## Qué falla

Una descripción clara de lo que ocurre.

## Pasos para reproducirlo

1.
2.
3.

## Qué debería ocurrir

Lo que esperabas que pasara.

## Qué ocurre en realidad

Lo que pasa, incluyendo el texto exacto del error si lo hay.

## Entorno

| | |
|---|---|
| Versión de TranscriptorX | <!-- p. ej. 2.0 — en Preferencias de la app --> |
| macOS | <!-- p. ej. 15.2 (24C101) --> |
| Arquitectura | <!-- salida de `uname -m`: arm64 o x86_64 --> |
| Modelo de Whisper | <!-- p. ej. large-v3-turbo, si ya lo habías descargado --> |

## Logs

Pega aquí la salida relevante. La app escribe sus registros en el log del
sistema; puedes ver los de la aplicación con:

```bash
log show --predicate 'subsystem == "TranscriptorX"' --last 1h
```

## Nota sobre la firma

Si instalaste la aplicación desde el `.dmg` publicado, recuerda que va sin
firmar: hay que abrirla con clic derecho → *Abrir* o quitar la cuarentena con
`xattr -dr com.apple.quarantine /ruta/a/TranscriptorX.app`.
