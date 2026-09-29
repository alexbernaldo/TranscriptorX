# Information Architecture

## Principio
Estructura orientada a tareas: **Configurar → Procesar → Revisar → Gestionar**.

## Capas de navegación
- **Global**
  - Home / Master
  - Configuración
  - Historial / Favoritos
  - Cola de trabajos
- **Contextual (según estado)**
  - Setup (si faltan dependencias)
  - Progreso de transcripción
  - Resultado de transcripción

## Mapa de entidades
- **TranscriptionJob**: unidad de trabajo en cola.
- **Transcription**: resultado persistido con metadata.
- **Settings**: preferencias globales (idioma, modelo, audio).
- **ModelInfo**: catálogo de modelos y capacidades.

## Arquitectura de UI (Atomic Design)
- **Atoms**
  - Botones de icono/cierre
  - Tags y badges
  - Inputs simples
- **Molecules**
  - Rows de configuración (toggle/slider)
  - Toast item
  - Search row
- **Organisms**
  - Drawers (historial/favoritos)
  - Paneles (cola, grabación)
  - Bloques de progreso/transición
- **Templates**
  - Escenas completas (Master, Transcript, Settings)

## Reglas de copy
- Mantener una lengua primaria por capa (UI en español actualmente).
- Términos técnicos pueden ir con sigla: "Detección de actividad de voz (VAD)".
- Evitar mezcla ES/EN en labels vecinos si no aporta claridad funcional.
