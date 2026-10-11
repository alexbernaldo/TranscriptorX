# Rediseño Transcriptor X: registro de implementación

Estado: **implementación completa e integrada; verificación parcial** (detalle en §4 y §9).
Fuente de diseño: `Transcriptor-X-especificacion-diseno.md` (1232 líneas, leída completa).
Rama: `feature/tx-planes`. Nada se ha confirmado (commit) ni publicado.

Leyenda de estado:
- **VERIFICADO**: comprobado ejecutando la app (capturas, interacción real, tests) en esta sesión.
- **IMPLEMENTADO**: el código existe, compila y está conectado, pero no se ha ejercitado de punta a punta.
- **PENDIENTE**: falta trabajo o comprobación; se indica la causa.
- **BLOQUEADO**: no se puede comprobar sin autorización, hardware o un servicio externo; se indica la causa exacta.

## 1. Cómo compilar y probar

```sh
# App (Debug, sin firma)
xcodebuild -project TranscriptorNative.xcodeproj -scheme TranscriptorNative \
  -configuration Debug CODE_SIGNING_ALLOWED=NO build

# Tests unitarios (target nuevo TranscriptorNativeTests, alojado en la app)
xcodebuild -project TranscriptorNative.xcodeproj -scheme TranscriptorNativeTests \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test

# Catálogo de textos
python3 scripts/check_localization.py
```

Resultado final de esta sesión:
- Build: **BUILD SUCCEEDED**, 3 warnings. Los tres son anteriores al rediseño: `AudioEngineManager.swift:114`, `DeepFilterBridge.swift:184` y `DictationManager.swift:87`. La línea base tenía 8.
- Tests: **TEST SUCCEEDED, 29 de 29**.
- Localización: «Localization audit passed», 800 claves `TXL` con valores es/en.
- Info.plist del producto: contiene `SUFeedURL`, `CFBundleIconName = AppIcon`, el esquema `transcriptorx`, y `TranscriptorDocument` como icono del tipo y del documento.

Bajo XCTest la app no arranca: `AppLauncher` en `App/TranscriptorApp.swift` detecta `XCTestConfigurationFilePath`. Así no se abre la base de datos, no se recupera nada y no se crean ventanas, y los tests nunca tocan los datos del usuario.

## 2. Arquitectura entregada

### Sistema de diseño (`TranscriptorNative/DesignSystem/`)

| Archivo | Contenido |
|---|---|
| `Tokens.swift` | Paletas oscura y clara con variantes de Aumentar contraste; colores AppKit; 6 hablantes con forma propia y variante oscura en modo claro; tipografía; espaciado; radios; tamaños; ventana (1280×820 inicial, 720×520 mínimo); movimiento (§9.5). |
| `CruceMark.swift` | Geometría exacta del símbolo en rejilla de 32 unidades, versión reducida, progreso de trazado para la apertura e imágenes de la barra de menús (reposo, cola activa, reunión). |
| `TXComponents.swift` | Botones, etiquetas y fichas, progreso (determinado, indeterminado, en espera), medidor, marca de hablante, cabecera de grupo, estado vacío, campo y separador. |
| `Localization.swift` | `TXL` (es/en con texto de la spec como respaldo) y `TXFormat` (tiempos, fechas, bytes, rutas). |
| `KeyHandling.swift` | Monitor de teclado compatible con macOS 13, `txOnChange` y `txCustomFocusRing`. |
| `FlowLayout.swift` | Disposición en flujo para fichas y etiquetas. |

### Capa de estado y ventana (`TranscriptorNative/Workspace/`)

| Carpeta | Contenido |
|---|---|
| `State/` | `LibraryStore` (carga asíncrona, grupos por fecha, búsqueda FTS con fragmento, papelera, migración), `WorkspaceState` (rutas, selección, inspector por documento, banners, avisos, fichas de importación, sheets), `WindowSupport`, `PlaybackController`. |
| `Editor/` | `EditorOperations` (lógica pura y probada), `DocumentEditor` (Lectura/Edición, deshacer por instantáneas, guardado en segundo plano), `SegmentTextView` (NSTextView por segmento con resaltado de palabra), `DocumentView`, `SegmentRow`, `PlayerBar` y `FindBar`. |
| `Window/` | `MainWindowView` (split view con inspector propio), `MainToolbar`, `AppCommands` (menús y atajos), `OpeningAnimation`, `MenuBarMenu`. |
| `Sidebar/`, `Home/`, `Jobs/`, `Link/`, `Recording/`, `Trash/`, `Inspector/`, `Export/`, `Onboarding/`, `Settings/`, `Chrome/` | Una carpeta por superficie de §6. |

### Servicios adaptados (capacidades existentes conservadas)

- `JobManager` reescrito: prioridad, enlaces en cola, espera de modelo, recuperación y eventos de fin.
- `ModelDownloadCenter` (nuevo).
- `TranscriptionService` (fases reales `onPhase` y bytes) y `URLTranscriptionService` (corregido el defecto previo de stdout/stderr).
- `RecoveryManager`, `TranscriptionDatabase`, `TranscriptionStorage`, `AISummaryService`, `SystemAudioRecorder` (ya no pide permisos al arrancar), `DictationManager`, `MeetingWatcherService` (Calendario solo al activar la opción) y `TranslationService`.

### Retirado (git rm)
- Vistas antiguas (`ContentView`, `MasterView`, `TranscriptViewer`, `JobQueuePanel`, `PreferencesSheet` y otras), salvo `Views/Components/DictationOverlay.swift`, que se ha reescrito.
- `ResponsiveMetrics`, `LiveCaptionOverlayController` y `ModelManager`. Este último simulaba cargas y nunca se invocaba.

### Recursos
- `Resources/AppIcon.icon/`: documento de Icon Composer validado con `ictool`, con renditions Default, Dark, Clear y Tinted.
- PNG del `AppIcon.appiconset` regenerados.
- `TranscriptorDocument.icns`.
- Generador: `scripts/make_brand_assets.swift`.

### Proyecto
- Target **TranscriptorNativeTests**: bundle de tests unitarios con `TEST_HOST` en la app y `BUNDLE_LOADER`. Contiene:
  - `TranscriptorNativeTests/EditorOperationsTests.swift`;
  - `TranscriptorNativeTests/FormattingAndLibraryTests.swift`.
- Fase «Register .transcriptor type»: declara `$(TARGET_BUILD_DIR)/$(INFOPLIST_PATH)` como entrada (ver §8.2).
- Sin cambios en deployment target (13.0), firma, entitlements, dependencias (solo Sparkle, ya existente) ni formato de almacenamiento.

## 3. Validación de los 22 supuestos (§12.1) contra el código

| # | Supuesto | Realidad | Referencia |
|---|---|---|---|
| 1 | ⌃⌥R graba, ⌃⌥D alterna dictado | **No.** Hay un único atajo de dictado (pulsar y volver a pulsar); ⌃⌥Espacio, ⌃⌥D y ⌃⌥R son alternativas de ese atajo | `DictationManager.currentCombo`, `toggleDictation` |
| 2 | Valores de los presets | Clase: en, large-v3, VAD, diarización, prompt. Podcast: es, medium, VAD 0.5. Entrevista: es, large-v3-turbo | `TranscriptionSettings.lecture/.podcast/.interview` |
| 3 | Pasada final tras grabar | **No hay texto en vivo durante la grabación.** Se graba un archivo que después se transcribe | `RecordingController` |
| 4 | Micrófono y sistema a la vez | **No.** Una sola fuente | `SystemAudioRecorder.selectedSource` |
| 5 | Cancelar y reencolar | Cancelar ya existía; reencolar se ha añadido | `JobManager.requeue` |
| 6 | Progreso del motor | whisper-cli `-pp` da porcentaje real; yt-dlp da porcentaje y tamaño | `TranscriptionService`, `parseYtDlpProgress` |
| 7 | tinydiarize | `-tdrz` solo funciona con modelos `tdrz`; **ningún modelo del catálogo lo es** | `TranscriptionService.availableModels` |
| 8 | Opciones de exportación | Difieren de 6.16 (estilos, agrupación, fin, milisegundos, fps). **Existe PDF**, que la spec omite | `ExportEngine.ExportKindOptions` |
| 9 | Subtítulos de YouTube y cookies | Dos métodos (subtítulos o audio), con alternativa Innertube. No hay ajuste de cookies | `URLTranscriptionService` |
| 10 | IA: persistencia y detener | Se guardan título, resumen y etiquetas. No había chat, selector de proveedor ni forma de detener; se han añadido (chat solo de sesión) | `AISummaryService`, `AIController` |
| 11 | Traducción | Texto completo en `fullTextTranslations`; Translation del sistema en macOS 15+, LLM local de respaldo | `TranslationService`, `TranslationTab` |
| 12 | División y palabras | Antes se dividía en proporción al tiempo y no se invalidaban las palabras. Ahora se divide por el tiempo de palabra cuando existe (estimado con «≈» si no) y se invalidan al editar | `EditorOperations.split/applyTextEdit` |
| 13 | Persistencia de la edición | Antes se guardaba en cada cambio en el hilo principal; ahora en segundo plano y con banner si falla | `DocumentEditor.save` |
| 14 | Velocidad de reproducción | De 0,5× a 2× | `PlaybackController` |
| 15 | Eliminación definitiva | **Existe**; se conserva | `TranscriptionStorage.deleteForever` |
| 16 | Proyecto duplicado | Upsert con el mismo id: sustituye la entrada | `AppDelegate.application(_:open:)` |
| 17 | Descarga de modelos | Desde Hugging Face | `ModelDownloadCenter` |
| 18 | Instalar dependencias | La app las instala (brew y compilación de whisper.cpp) | `DependencyManager`, `ToolsCheck` |
| 19 | `tx` | Necesita la app abierta (socket Unix). Se instala con `scripts/install_cli.sh` | `CLI/tx/main.swift`, `CLIServer` |
| 20 | Dictado sin poder pegar | No empieza sin permiso de Accesibilidad, así que no se pierde texto | `DictationManager` |
| 21 | Destino del SRT automático | Junto al original; interruptor global | `JobManager.saveJobToHistory` |
| 22 | Metadatos y alcance | Se guardan idioma, duración, fecha y origen. **No se guarda el modelo.** Buscar y reemplazar actúa sobre el documento | `Transcription` |

## 4. Matriz de requisitos

### 4.1 Identidad, sistema de diseño y ventana

| Requisito | Estado | Evidencia |
|---|---|---|
| Símbolo Cruce (§2.1), versiones reducida y mono | VERIFICADO | Capturas de Inicio, Asistente y Diagnóstico; `CruceMark.swift` |
| Icono de app (§2.2) y renditions | VERIFICADO | `ictool` sobre `AppIcon.icon`; Dock y alertas muestran el icono |
| Icono de documento (§2.3) | IMPLEMENTADO | `TranscriptorDocument.icns` y claves en Info.plist verificadas; no comprobado en Finder |
| Símbolo de barra de menús (§2.4): reposo, cola activa, reunión | IMPLEMENTADO | `CruceRenderer.menuBarImage`; menú abierto vía AX, sin captura del icono por estado |
| Paleta oscura y clara (§3.1) | VERIFICADO | Capturas en oscuro y claro de Inicio, documento, inspector y Ajustes |
| Aumentar contraste (§3.1) | PENDIENTE | Variantes en `NSColor.tx(...)`; requiere activar el ajuste del sistema (no se cambian ajustes de accesibilidad del usuario) |
| Tipografía, espaciado, radios (§3.2–3.4) | VERIFICADO | Capturas; tokens centralizados |
| Ventana 1280×820 inicial, 720×520 mínimo (§4.4) | VERIFICADO | `winall`: 1280×820 y 720×520 |
| Inspector propio de 300 pt; se pliega por debajo de 1040 pt | VERIFICADO | Capturas a 1280 y 960 pt |
| Altura reducida (cabecera compacta y reproductor de 44 pt) | VERIFICADO | Captura a 960×560 |
| Apariencia oscura por defecto | VERIFICADO | Primer arranque y Ajustes › Comportamiento |
| Restauración (documento, segmento, posición, pestaña) (§4.5) | VERIFICADO | Reabrir la app QA restauró el documento y la posición |

### 4.2 Superficies de §6

| § | Superficie | Estado | Evidencia o causa |
|---|---|---|---|
| 6.1 | Asistente en 4 pasos | VERIFICADO | Pasos 1–4 con home vacío: whisper ausente bloquea, «Comprobar de nuevo» lo encuentra, tabla de modelos, «Elegir más tarde», «Todo listo» |
| 6.2 | Inicio sin transcripciones | VERIFICADO | Barra lateral «Aquí aparecerán tus transcripciones» y zona de importación |
| 6.3 | Nueva desde archivos | VERIFICADO | Ficha con duración 00:22 y tamaño; «Transcribir» encola. La vía del panel «Elegir archivos…» no se pudo ejercitar (§9) |
| 6.4 | Desde URL | VERIFICADO (UI) | Sheet con detección de YouTube, métodos y quick settings. Descarga real no ejecutada (red externa) |
| 6.5 | Quick settings y presets | VERIFICADO | Segmentado, idioma y modelo; «Más opciones» baja a su línea en anchos estrechos |
| 6.6 | Cola y vista Trabajo | VERIFICADO | Fases, progreso 26 %→64 %, texto recibido y «Lista». Al terminar abre el documento |
| 6.7 | Popover Grabar | BLOQUEADO | El medidor abre el micrófono; no se captura audio real sin autorización |
| 6.8 | Panel flotante de grabación | BLOQUEADO | Requiere grabar |
| 6.9 | En vivo | BLOQUEADO | Requiere grabar |
| 6.10 | Editor y reproductor | VERIFICADO | Reproducción, clic en palabra (salto a 00:13), resaltado y seguimiento |
| 6.11 | Hablantes | VERIFICADO | Inspector › Hablantes y etiquetas coloreadas. Fusionar y renombrar no ejercitados en esta sesión |
| 6.12 | Buscar y reemplazar | VERIFICADO | «1 de 2», marcas en el carril, «Reemplazar todo» con aviso y Deshacer |
| 6.13 | Historial con búsqueda | VERIFICADO | Grupos Hoy/Ayer/Últimos 7 días/mes; fragmento con test unitario |
| 6.14 | Eliminados recientemente | VERIFICADO | Captura con días restantes |
| 6.15 | Proyectos `.transcriptor` | IMPLEMENTADO | Guardar y abrir no ejercitados en esta sesión |
| 6.16 | Exportación individual | VERIFICADO | Sheet y SRT generado y revisado. Opciones por formato con test |
| 6.17 | Exportación por lotes | IMPLEMENTADO | No ejercitada |
| 6.18 | IA local | VERIFICADO (error) | Proveedor Ollama detectado; «Sugerir título» mostró el error real «HTTP 500» con «Volver a intentar». El éxito queda PENDIENTE (el Ollama local devolvió 500) |
| 6.19 | Traducción | IMPLEMENTADO | Pestaña con origen, motor y destino. Traducción real no ejecutada |
| 6.20 | Ajustes (11 secciones) | VERIFICADO | 720×540, barra lateral fija de 200 pt, todas las secciones capturadas en oscuro y claro |
| 6.21 | Gestión de modelos | VERIFICADO | Tabla sin recortes a 480 pt; «Descargado» con modelo local enlazado. Descarga real no ejecutada |
| 6.22 | Automatización | VERIFICADO (UI) | Carpetas, `tx`, Atajos, enlaces. Vigilancia real no ejercitada |
| 6.23 | Dictado y overlay | BLOQUEADO | Requiere micrófono y Accesibilidad |
| 6.24 | Subtítulos flotantes | VERIFICADO (Ajustes) | Muestra «Así se verán los subtítulos». Panel en vivo bloqueado (requiere grabar) |
| 6.25 | Menú de barra y salida | VERIFICADO (menú) | Orden: Grabar, Última, Nueva, Historial, Ajustes y Salir. Confirmación de salida no ejercitada |
| 6.26 | Recuperación | IMPLEMENTADO | Requiere simular un cierre inesperado |
| 6.27 | Actualizaciones y Diagnóstico | VERIFICADO (UI) | Ajustes › Actualizaciones. «Buscar ahora» no pulsado (red externa) |

### 4.3 Editor (§7)

| Requisito | Estado | Evidencia |
|---|---|---|
| Cabecera de 96 pt que se compacta a 44 pt | VERIFICADO | Capturas |
| Modos Lectura y Edición | VERIFICADO | Doble clic entra en Edición (borde y padding); Esc sale |
| ↑/↓ y ⇧↑/⇧↓ | VERIFICADO tras corrección | ⇧↑ seleccionaba hasta el último segmento; corregido (§7.1) |
| Dividir en el cursor (⌥Retorno y menú) | VERIFICADO tras corrección | Corte en el carácter exacto, tiempo de palabra (00:02) y aviso con Deshacer |
| Unir; confirmación si los hablantes difieren | VERIFICADO | Mismo hablante: sin alerta. Distintos: alerta; Cancelar y Esc no cambian nada |
| Deshacer y rehacer | VERIFICADO | ⌘Z tras unir y tras reemplazar todo |
| Ajustar tiempos | IMPLEMENTADO | Validación con test (`testValidateTimes`, `testParseTime`) |
| Resaltado de palabra activa | VERIFICADO | Captura durante la reproducción |

### 4.4 Estados, errores y permisos (§8)

| Requisito | Estado | Evidencia |
|---|---|---|
| Migración JSON → SQLite con aviso y `.bak` | VERIFICADO | Aviso «Historial actualizado. Copia de seguridad guardada como transcriptions.json.bak» |
| Banner de memoria | VERIFICADO | Apareció con presión de memoria real del sistema |
| Modelo ausente (espera y descarga solo a petición) | IMPLEMENTADO | Código revisado; sin descarga real |
| Permisos pedidos solo en contexto | VERIFICADO (código) | `SystemAudioRecorder` ya no pide nada al arrancar; Calendario solo al activar la opción |

### 4.5 Animación (§9)

| Requisito | Estado | Evidencia |
|---|---|---|
| Apertura del símbolo | VERIFICADO (previo) | Capturas de la sesión anterior |
| Inspector 240 ms, avisos, banners y fichas | IMPLEMENTADO | Curvas de `TX.Motion`. No se midió fotograma a fotograma |
| Reducir movimiento y transparencia | PENDIENTE | Implementado con `accessibilityReduceMotion`; requiere cambiar el ajuste del sistema |

### 4.6 Accesibilidad y teclado (§10)

| Requisito | Estado | Evidencia |
|---|---|---|
| Etiquetas en botones de icono | VERIFICADO (código) | Barrido: todos con `accessibilityLabel` y `help` |
| Filas activables con VoiceOver (AXPress) | VERIFICADO | Filas del historial abiertas con `AXPress`. Se añadieron acciones a la carpeta vigilada y a la fila de hablante |
| Esc cancela las alertas | VERIFICADO tras corrección | Ver §7.1 |
| Atajos de menú | VERIFICADO | Menús Archivo, Edición, Visualización y Transcripción listados vía AX |
| VoiceOver real | PENDIENTE | No se activó VoiceOver; anuncios implementados en `AccessibilityAnnouncer` |

### 4.7 Matriz F01–F36 (§11)

| F | Estado | Nota |
|---|---|---|
| F01 Inicio y En proceso | VERIFICADO | Fichas, Transcribir, fila con estado y progreso |
| F02 Sheet de enlace | VERIFICADO (UI) | Sin descarga real |
| F03 Errores de descarga por causa | IMPLEMENTADO | `JobErrorPanel`; sin fallo real provocado |
| F04 En vivo | BLOQUEADO | Micrófono |
| F05 Modelo listo/en reposo y banner de memoria | VERIFICADO | Pie de la barra lateral y banner |
| F06 Más opciones | VERIFICADO (UI) | |
| F07 Recuperación | IMPLEMENTADO | |
| F08 Modelos | VERIFICADO | |
| F09 Popover Grabar | BLOQUEADO | Micrófono |
| F10 Banner de reunión | BLOQUEADO | Calendario o app de reuniones activa |
| F11 Panel flotante | BLOQUEADO | Grabación |
| F12 Editor | VERIFICADO | |
| F13 Buscar, dividir, unir, tiempos | VERIFICADO (tiempos IMPLEMENTADO) | |
| F14 Palabra activa | VERIFICADO | |
| F15 Hablantes | VERIFICADO (lista); fusionar IMPLEMENTADO | |
| F16 Subtítulos flotantes | BLOQUEADO (panel) / VERIFICADO (Ajustes) | |
| F17 Búsqueda del historial | VERIFICADO | |
| F18 Migración | VERIFICADO | |
| F19 Eliminados | VERIFICADO | |
| F20 Proyectos | IMPLEMENTADO | |
| F21 Formatos de exportación | VERIFICADO | |
| F22 Opciones recordadas | VERIFICADO (test) | |
| F23 Lotes | IMPLEMENTADO | |
| F24 IA | VERIFICADO (estado de error) / PENDIENTE (éxito) | |
| F25 Traducción | IMPLEMENTADO | |
| F26 CLI `tx` | IMPLEMENTADO | En QA el socket no se crea: la ruta del home aislado supera los 104 caracteres de `sun_path` |
| F27 Carpetas vigiladas | IMPLEMENTADO | |
| F28 Atajos y Spotlight | IMPLEMENTADO | |
| F29 Presets | VERIFICADO | |
| F30 `transcriptorx://` | IMPLEMENTADO | No se probó: abriría también la app real registrada |
| F31 Menú de barra | VERIFICADO (menú) | |
| F32 Ajustes | VERIFICADO | |
| F33 Dictado | BLOQUEADO | Micrófono y Accesibilidad |
| F34 Actualizaciones | VERIFICADO (UI) | Sin comprobación en red |
| F35 Asistente y Diagnóstico | VERIFICADO | |
| F36 Privacidad | VERIFICADO | Texto literal de la spec |

## 5. Desviaciones documentadas (el código manda en capacidades)

1. **Grabación:**
   - No hay texto en vivo mientras se graba. La vista En vivo lo explica, y el texto en streaming aparece en Trabajo en proceso.
   - Una sola fuente de audio, así que se usan botones de radio en lugar de casillas.
2. **Documento:**
   - El modelo no se guarda con el documento; la cabecera lo omite.
   - La traducción es de texto completo y de solo lectura, sin timestamps.
   - El chat de IA dura solo la sesión.
3. **Capacidades existentes que se conservan:** eliminación definitiva y PDF.
4. **Timestamps por palabra:** siempre activos (`-ojf`).
5. **Restaurar etiquetas de hablantes:** solo borra los nombres.
6. **Fichas hacia la cola:** no viajan visualmente a la barra lateral (no es posible entre columnas del split view); se encogen y se desvanecen.
7. **Banner de reunión:** borde de 1 px (§3.1), en lugar de 2 pt (§3.3).
8. **Ajustes:**
   - Usan una lista fija de 200 pt con un `HStack` en lugar de `NavigationSplitView`. Este último imponía 144 pt, truncaba «Comportamiento» y ofrecía plegar la barra.
   - El alto del contenido es 540 − 32 pt (barra de título medida).
9. **Tabla de modelos (§6.21):** se construye con `Grid` en lugar de `Table`. El `Table` inset añade unos 17 pt por columna, y las seis columnas no cabían en 480 pt sin desplazamiento horizontal.
10. **Quick settings:**
    - Idioma y modelo son menús ajustados a su valor; un pop-up mostraba «Espa…».
    - Con ancho de 560 pt, «Más opciones» pasa a una segunda línea alineada a la izquierda: la fila completa necesita unos 566 pt.
11. **Inicio:** la columna de 560 pt se estrecha hasta el ancho disponible menos 20 pt por lado (a 720 pt de ventana caben 440 pt). Sin esto el contenido se cortaba.
12. **Bloque Memoria (§6.21):** dice «whisper carga el modelo al empezar cada transcripción y lo libera al terminar.» El texto fijo de la spec (5 min / 60 s) describe un comportamiento que la app no tiene: whisper-cli carga el modelo por proceso.
13. **Asistente, paso 4:** la línea de dictado añade «Activa el dictado en Ajustes», porque el dictado está desactivado por defecto en el código.

## 6. Skills de diseño: uso, decisiones y conflictos

### Emil Kowalski (`emil-design-eng`)
- **Uso:** curvas de `TX.Motion`, asimetría entre entrada y salida, y nada animado en cambios de selección o pestañas.
- **Revisión final:**

| Before | After | Why |
| --- | --- | --- |
| Aviso: entrada y salida con fundido + desplazamiento de 8 pt, 200 ms | Entrada con fundido + 8 pt; salida solo con fundido, 160 ms (`Feedback.swift`) | La salida debe ser más rápida que la entrada, y la spec dice «se va con fundido» |
| Pulsado sin escala | Sin cambio (solo color) | Conflicto: §9.5 define el pulsado solo con color; prevalece la spec |
| Inspector animado también con ⌥⌘I | Sin cambio (240 ms) | Conflicto: Emil desaconseja animar acciones de teclado; §9 fija 240 ms para abrir el inspector |
| Curva de salida `(0.4, 0, 1, 1)` (tipo ease-in) | Sin cambio | Conflicto: Emil prohíbe ease-in; §9.5 la define para salidas |

### Impeccable (`impeccable`)
- **Uso:** se ejecutó `context`. Resultado: sin PRODUCT.md ni DESIGN.md, plataforma no registrada.
- **Auditoría nativa** (`audit.native`, adaptada a macOS):

| # | Dimensión | Puntuación | Hallazgo clave |
|---|---|---|---|
| 1 | Accesibilidad | 3 | Dos filas con gesto sin acción por defecto para VoiceOver (corregidas); VoiceOver real sin probar |
| 2 | Rendimiento | 3 | Lista perezosa y guardado en segundo plano. El `==` de `TranscriptionJob` (solo `id`) congelaba la UI de la cola (corregido) |
| 3 | Apariencia | 3 | Tokens en todo; 3 blancos literales sobre superficies siempre oscuras (cápsulas y pomo del reproductor) |
| 4 | Conformidad con macOS | 3 | Menús, NSAlert, MenuBarExtra y Settings nativos; Ajustes con `HStack` en lugar de split view |
| 5 | Adaptación | 3 | 720×520 verificado tras corregir Inicio y Quick settings |
| **Total** | | **15/20** | **Good** |

- **PRODUCT.md no se escribió.** El flujo `init` exige entrevistar al usuario y la instrucción general era preguntar solo ante bloqueos reales. El contexto inferido de la spec queda aquí: app macOS nativa, local y sin cuentas; para quien transcribe clases, podcasts, entrevistas y reuniones en su Mac; modo Operate.
  - Pendiente con el usuario: si quiere ese archivo, `/impeccable init`.

### Taste Skill (`design-taste-frontend`)
- **Alcance:** la propia skill declara fuera de alcance la UI nativa densa (§13). Solo se aplicaron sus comprobaciones transferibles.
- **Pre-flight transferible:**
  - Un solo acento, purple.X. La spec lo fija, y su «Lila rule» admite la excepción cuando lo pide la marca.
  - Una escala de radios: 4, 6, 8, 10, 14 y cápsula, según §3.3.
  - Ningún botón con el texto partido en dos líneas: revisado en capturas a 1280 y 720 pt.
  - Estados vacío, de carga y de error presentes.
  - Ambos modos verificados.
  - Reducir movimiento respetado en el código.
  - Revisión de textos hecha.
- **Conflicto:** la skill prohíbe la raya y racionar el punto medio, y la spec usa el punto medio en textos literales («22 s · Español»), así que prevalece la spec. Ningún texto visible usa raya; la única aparición es la clave heredada `settings.liveCaptions.subtitle`, que no se usa.

## 7. Defectos encontrados en la verificación de esta sesión y corregidos

### 7.1 Funcionales

| Defecto | Archivo | Corrección | Comprobación |
|---|---|---|---|
| La UI de la cola se quedaba en «En cola» durante todo el trabajo | `Models/TranscriptionJob.swift` | `==` compara el estado visible, no solo el `id` (defecto previo al rediseño) | Test `JobEqualityTests` y captura con fases y 26 %→64 % |
| Al terminar un trabajo se volvía a Inicio en vez de abrir el documento | `Services/JobManager.swift` | `LibraryStore.didSave` antes de publicar el fin (había una carrera con la recarga asíncrona) | Captura: abre el documento |
| «Dividir en el cursor» del menú siempre desactivado | `Workspace/Window/AppCommands.swift` | `CommandRouter` vuelve a publicar los cambios de modo, selección, filtro y búsqueda del editor | AX: `enabled = true` y la división funciona |
| Cursor de NSTextView (UTF-16) usado como desplazamiento en caracteres | `EditorOperations.characterOffset` | Conversión explícita | Test `testCursorOffsetConvertsUTF16ToCharacters` |
| ⇧↑ sin extensión previa seleccionaba hasta el último segmento | `DocumentEditor.moveSelection` | Parte de la selección; un ancla nueva reinicia la extensión | AX: «Unir 2 segmentos» |
| Esc no cancelaba las alertas (botón «Cancelar» localizado sin tecla) | 5 archivos | `keyEquivalent = "\u{1b}"` en «Cancelar» y «Ahora no» | Alerta de unión cancelada con Esc |
| La ruta del home se abreviaba por subcadena («/private~/…») | `TXFormat.displayPath` | Solo como prefijo | Test `DisplayPathTests` |

### 7.2 Visuales

| Defecto | Corrección |
|---|---|
| Ajustes medía 576 pt de alto y tenía botón para plegar la barra lateral | 540 pt exactos y lista fija (§5.8) |
| Tabla de modelos con la columna Estado cortada | Rejilla propia (§5.9) |
| Selector de idioma truncado y fila Quick settings desbordada a 720 pt | §5.10 y §5.11 |

## 8. Incidentes

### 8.1 Preferencias reales
La primera ejecución de QA (sesión anterior) usó `CFFIXED_USER_HOME`, que aísla Application Support pero **no las preferencias**. Esa ejecución escribió la clave `NSWindow Frame main` en el dominio real `io.github.alexbernaldo.transcriptorx`.
- Se borró solo esa clave con `defaults delete`.
- Desde entonces toda la QA usa el bundle id `io.github.alexbernaldo.transcriptorx.qa`.
- El log real `~/Library/Application Support/Transcriptor/Logs/app.log` no cambia desde el 10 oct, 19:44, antes de la QA.

### 8.2 Regresión de Info.plist
Al añadir `AppIcon.icon`, el procesado de Info.plist empezó a ejecutarse después del script «Register .transcriptor type». Eso borraba `SUFeedURL`, los tipos de documento y el esquema de URL. Se corrigió declarando el Info.plist como entrada del script, y las claves están verificadas en el build final.

### 8.3 DerivedData temporal
El sistema purgó el `Info.plist` del xcframework de Sparkle en el DerivedData de QA (`$TMPDIR`). Se restauró copiándolo desde el DerivedData de Xcode del usuario, sin descargar nada. El repositorio no se vio afectado.

### 8.4 Clic fuera de la ventana QA
Una coordenada mal calculada envió un clic simple fuera de la ventana QA, sobre la ventana de otra app (zona de editor/terminal). No se escribió texto ni se pulsó ningún botón conocido. Se notifica por transparencia.

## 9. Pendiente y bloqueado (causa exacta)

### Bloqueado (requiere autorización)
- **Grabación, En vivo, panel flotante, subtítulos en pantalla y dictado:** capturar audio real del micrófono o del sistema y conceder Accesibilidad.
- **Banner de reunión:** permiso de Calendario o una reunión real.

### Requiere red externa (no ejecutado por las reglas)
- Descarga de enlaces.
- Descarga de modelos.
- Comprobación de Sparkle.

### Pendiente por el entorno de QA
- **Panel «Elegir archivos…»:** `NSOpenPanel` se bloquea en `_initBridgeAndStuff` cuando `CFFIXED_USER_HOME` está definido. Se reprodujo con un binario mínimo: sin la variable funciona, con ella se bloquea. Para importar se usó `open -a <app QA> archivo`. Falta comprobarlo en un arranque normal.
- **`tx`:** la ruta del socket en el home aislado supera el límite de `sun_path`.
- **`transcriptorx://`:** Launch Services podría abrir la app real.

### Pendiente por el servicio externo
- **IA con éxito:** el Ollama local respondió HTTP 500 (sin modelo cargado; el sistema estaba con poca memoria).

### Pendiente por ajustes del sistema
- Reducir movimiento, Reducir transparencia, Aumentar contraste y VoiceOver: no se cambian ajustes de accesibilidad del sistema del usuario.

### No ejercitado en esta sesión
- Proyectos `.transcriptor`, lotes, Ajustar tiempos (sí con tests), fusionar o renombrar hablantes, traducción real, recuperación tras un cierre y confirmación de salida.

## 10. Herramientas de QA (fuera del repositorio)

Están en `$TMPDIR/tx-redesign/`:

| Herramienta | Uso |
|---|---|
| `pbx.py` | Registra archivos en `project.pbxproj` |
| `build.sh [qa] [adhoc]` | Compila; `qa` usa el bundle `.qa` y `adhoc` firma ad hoc solo en DerivedData temporal |
| `qa.sh start\|stop\|reset` | Arranca la app QA con home aislado; `reset` también reinicia las preferencias `.qa` |
| `fixture.py` | Home con `transcriptions.json` heredado y audio sintético generado con `say` |
| `winid`, `winall`, `shot.sh` | Listan ventanas por PID y hacen capturas |
| `ui.sh`, `row.sh`, `setsec.sh`, `mclick` | Menús y teclas vía AX, filas, secciones de Ajustes y clic real |
| `grid` | Compone capturas en mosaico |

Para la vista de trabajo se enlazaron (symlink, solo lectura) `whisper-cli` y `ggml-base.bin` del usuario dentro del home de QA. Se transcribió únicamente audio sintético de `say`.

## 11. Identificar hablantes (después de la v3.0)

- **Diagnóstico:**
  - La opción no funcionaba porque dependía de tinydiarize (`-tdrz`), que solo actúa con modelos «tdrz». El catálogo no ofrece ninguno.
  - Además, el análisis de las marcas de turno solo incrementaba el número de hablante y nunca volvía a uno anterior.
- **Cómo lo hace MacWhisper:**
  - Usa `Argmax_Runner` con **SpeakerKit**: modelos pyannote (segmentador, embeddings y proyector PLDA) en Core ML, en `speakerkit-v1.9.3.zip`.
  - Su licencia dice «Argmax proprietary and confidential. Under NDA», así que no se puede reutilizar.
- **Implementación** (decisión del usuario: FluidAudio con macOS 14):
  - **Motor:**
    - Paquete **FluidAudio 0.17.7** (Apache 2.0), con su pipeline offline: pyannote community-1, WeSpeaker y VBx en Core ML.
    - Modelos de Hugging Face `FluidInference/speaker-diarization-coreml`, en la revisión que fija FluidAudio, con licencia CC-BY-4.0.
    - Se guardan en `~/Library/Application Support/Transcriptor/diarization` (21 MB, medido).
  - **Flujo** (`Services/SpeakerDiarizationService.swift`): whisper transcribe; después se diariza el mismo WAV preprocesado.
  - **Asignación** (`Services/SpeakerAssignment.swift`, lógica pura con 5 tests):
    - cada palabra recibe el hablante con más solapamiento;
    - el segmento se divide donde cambia el hablante;
    - una palabra suelta se absorbe en el tramo vecino;
    - los hablantes se numeran por orden de aparición.
  - **Errores:** si la diarización falla, se guarda el texto y aparece un banner de aviso con los detalles.
  - **Interfaz:**
    - fases «Descargando el modelo de hablantes · n %» e «Identificando hablantes · n %» en la vista Trabajo;
    - la opción está activa con cualquier modelo;
    - la ayuda indica si falta la descarga.
- **Desviaciones:**
  - Deployment target 13.0 → **14.0** (FluidAudio exige macOS 14).
  - Ajustes › Privacidad añade la conexión «La primera vez que identificas hablantes, para descargar su modelo (Hugging Face)».
- **Verificado** con la build QA y audio sintético de `say`:
  - Tres voces distintas (Mónica, Grandpa, Eddy): **3 hablantes, 6 de 6 turnos correctos**, en 9 segmentos.
  - Tres voces con dos femeninas sintéticas muy parecidas (Mónica y Paulina): las dos femeninas se agruparon (2 hablantes). La voz masculina se separó bien.
  - La descarga del modelo y su progreso se vieron en la vista Trabajo.
- **Accesibilidad corregida de paso:**
  - Los interruptores de Más opciones y de Ajustes no tenían nombre para VoiceOver.
  - En Más opciones el interruptor quedaba pegado a la etiqueta.
- **Pendiente:** no se ha probado con grabaciones reales de varias personas, porque requiere audio real.
