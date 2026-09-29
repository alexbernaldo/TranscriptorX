# UX Copy Styleguide

## Objetivo
Asegurar consistencia de lenguaje en UI para mejorar claridad, foco de tarea y calidad percibida del producto.

## Idioma base
- La interfaz visible al usuario usa **español** como lengua primaria.
- Se permiten nombres propios o marcas técnicas sin traducir (por ejemplo: Whisper, CoreML, DeepFilterNet).
- Para términos técnicos, usar formato: **término en español + sigla**.
  - Ejemplo: "Detección de actividad de voz (VAD)".

## Reglas de redacción
- Usar frases cortas y accionables.
- Preferir voz activa.
- Evitar mezcla ES/EN en la misma pantalla o sección.
- Evitar mayúsculas sostenidas salvo etiquetas de sección existentes del sistema de diseño.
- Evitar tecnicismos cuando haya alternativa clara para usuario final.

## Capitalización (sentence case)
- Usar mayúscula inicial solo en la primera palabra y nombres propios.
- Evitar Title Case en botones, labels y encabezados de UI.
  - Correcto: "Grabar audio", "Pegar enlace", "Abrir configuración".
  - Evitar: "Grabar Audio", "Pegar Enlace", "Abrir Configuración".

## Convenciones de microcopy
- Botones de acción principal: verbo en infinitivo o imperativo claro.
  - "Transcribir", "Guardar", "Reintentar", "Abrir configuración".
- Botones secundarios: mantener brevedad.
  - "Cancelar", "Cerrar", "Ver todo".
- Estados y progreso:
  - "Procesando audio...", "Preparando resultado...", "Transcripción completada".
- Errores:
  - Mensaje + causa resumida + siguiente acción.
  - Ejemplo: "No se pudo descargar el audio. Intenta de nuevo."

## Convenciones por plataforma (macOS)
- En `accessibilityHint` y ayudas, usar "haz clic" en lugar de "toca" o "pulsa".
  - Correcto: "Haz clic para seleccionar esta fuente".
  - Evitar: "Toca para seleccionar".

## Idiomas listados (selectores)
- Mostrar nombres de idioma en español para coherencia de capa:
  - Español, Inglés, Francés, Alemán, Italiano, Portugués, Japonés, Chino.
- Opción automática:
  - "Detección automática".

## Accesibilidad de copy
- `accessibilityLabel` y `accessibilityHint` deben seguir la misma convención de idioma.
- Incluir contexto útil, no redundante.
  - Bien: "Cancelar trabajo".
  - Evitar: "Botón cancelar trabajo".

## Lista de verificación rápida en PR
- [ ] ¿Hay mezcla ES/EN en labels visibles de la misma vista?
- [ ] ¿Los términos técnicos están contextualizados?
- [ ] ¿Cada mensaje de error sugiere acción siguiente?
- [ ] ¿Botones usan verbos claros y consistentes?
- [ ] ¿`accessibilityLabel` mantiene el mismo tono/idioma que la UI?
