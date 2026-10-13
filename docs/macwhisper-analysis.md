# Análisis de MacWhisper 14.5 e integración en Transcriptor X

> **Alcance:** investigación de solo lectura. No se ha modificado código ni se ha lanzado la GUI de MacWhisper.
> **Fuentes MacWhisper:** `/Applications/MacWhisper.app` (v14.5, build 1471, `com.goodsnooze.MacWhisper`): `Info.plist`, `en.lproj/Localizable.strings` (1.978 claves), `strings` del binario principal (557.065 líneas) y del CLI `mw`, inventario de 60+ bundles, `Metadata.appintents`, `fakeRemoteConfig.json`, `codesign`, demangled symbols.
> **Fuentes Transcriptor X:** `README.md`, `CHANGELOG.md`, `CONTRIBUTING.md`, `docs/*`, código fuente bajo `TranscriptorNative/`, `project.pbxproj`, `scripts/`.
> **Aviso legal:** MacWhisper es software propietario (Good Snooze). Esto es una *reingeniería de funcionalidades e IA de producto* a partir de observación de binario/strings. Cualquier característica replicada debe **reimplementarse desde cero en Transcriptor X**; no copiar código, textos literales extensos ni assets.

---

## 1. Resumen ejecutivo

- MacWhisper es una **suite de transcripción de escritorio madura** (≈14 años de iteración aparente): entrada universal (archivo, micrófono, audio de sistema, reuniones, watch folders, YouTube), 4+ motores locales (whisper.cpp, WhisperKit, Parakeet/Argmax, Apple Speech, MLX), 17+ proveedores cloud, editor con diarización, traducción, IA (resumen/título/tags/chat), dictadura, live captions, exportación en 12 formatos, CLI, licencias por capas (Free/Pro/Assistant) y remote config.
- Transcriptor X es un **pipeline local sólido pero más estrecho**: whisper.cpp + preproceso neuronal (DeepFilter/Demucs) + cola serial + editor + 8 exportaciones + historial JSON. Sin IA en la nube, sin traducción (salvo `--translate`→EN), sin watch folders, sin CLI/URL scheme/Shortcuts, sin dictadura ni captions en vivo.
- El hueco principal no es el motor ASR (ambos usan whisper.cpp) sino la **capa alrededor**: ecosistema (CLI, atajos, automatización), **IA post-proceso**, **captura continua (reuniones/watch folders)** y **persistence/escala** (GRDB/SQLite vs un JSON monolítico).

---

## 2. MacWhisper: mapa de funcionalidades (lo que hay que conocer)

### 2.1 Módulos (bundles de `Resources`)

Todos los `.bundle` son **solo recursos** (sin ejecutable; `Info.plist` + `Localizable.strings`): el código está **estáticamente vinculado** al binario principal (build SwiftPM/Xcode, resource bundles). Frameworks embebidos: `Sparkle`, `RecordKit`, `ArgmaxSDK`, `YbridOgg/Opus`, `libMacWhisper.dylib`.

| Área | Bundles / clases clave |
|---|---|
| Núcleo ASR | `whisper_whisper` (whisper.cpp + `default.metallib`), `WhisperCPP_Runner` (+ `Wispa`: wrapper Swift), `WhisperManager` (`WhisperManager`, `TranscriptionQueue`), `WhisperRunnerLoader`, `MWModels` (`AnomalyDetector`, `ModelReferenceManager`), `MLXAudio_Runner` (Qwen3-ASR), `Argmax_Runner` (WhisperKit Pro/ParakeetKit/SpeakerKit para diarización) |
| Audio/captura | `Audio_Audio`/`Audio_AudioMacOS` (`AppAudioTapper`, `MicrophoneAudioTapper`, `SystemAudioPermissionManager`), `AudioKit`, `RecordApp` (`ActiveMeetingDetectionManager`, `CalendarManager`, `MeetingRecordingCoordinator`) |
| Entrada | `WatchedFolder` (`FolderMonitor`, `WatchedFoldersManager`), `YouTubeKit` (InnerTube propio: `Cipher`, `SignatureSolver`, fallback a servidor propio), cola/`BatchRunner` |
| IA/LLM | `LLMs` (`AISummaryManager`, `AIChatManager`), `Translator` (DeepL + Apple Translation), runners `Prompt{OpenAI,Anthropic,Gemini,Ollama}`, `AIProxy` (certificate pinning, 10+ servicios) |
| UI | `MagicTranscript` (editor rico en **WKWebView** con `EditorBridge`), `NSSegments` (NSCollectionView nativo), `Dictation*` (`DictationSession`, `PastingEngine`, overlay), `LiveMicOverlay` (`LiveCaptionsManager`), `MacWhisperUI` |
| Persistencia/licencias | `Persistence` (`.whisper` zip, security-scoped bookmarks), `GRDB` (SQLite), `DatabaseUndoSupport` (soft-delete/undo), `Licensing` (Gumroad + StoreKit 2 + MDM), `TelemetryDeck` |
| Cloud (runners) | `WhisperGroq`, `WhisperOpenAI(+Compatible)`, `Deepgram`, `ElevenLabs`, `AssemblyAI`, `Gladia`, `RevAI`, `Cartesia`, `Corti`, `Volcengine`, `Avalon`, `XAI`, `OpenRouter`, `Voxtral`, `Mistral`, + `Assistant*` (sin API key del usuario) |

### 2.2 Funcionalidades por área

**B.1 Transcripción local**
- Motores: `WhisperCPP`, `WhisperKit`, `WhisperKitPro`, `ParakeetKitPro`, `FluidParakeet`, `Qwen3ASR`, `macOS Native` (Apple Speech, macOS 26+), `Apple Foundation Models`.
- Modelos: GGML whisper (tiny→large-v3, kotoba, nb/sv), WhisperKit/HF (`openai_whisper-*`, `distil-whisper_*`, `nvidia_parakeet-v2/v3`), MLX (`mlx-community/Qwen3-ASR-*`), Apple por locale (`apple:en-GB`).
- Ajustes avanzados: initial prompt, entropy threshold, beam search size, greedy/temperature increments, word-level timestamps, límite de longitud de segmento, "un segmento por palabra", downmix a mono, GPU/Flash Attention/Neural Engine, concurrent workers, compute units, VAD, unload del modelo tras 1 min–4 h, "load at launch vs on first transcription", fast loading, "disable all GPU" (mitigación de crashes CoreML).
- Post-proceso: combinar segmentos en frases, quitar segmentos duplicados, **lista de segmentos a ignorar**, **Global Replace** (import/export JSON), limpieza automática (`*musica*`, guiones), *Transcript Suggestions*.
- Calidad: `AnomalyDetector` (repeticiones, huecos >5 min, fill-rate), pantallas de ayuda para alucinaciones/idioma erróneo.

**B.2 Cloud transcription** — 17+ proveedores con endpoints propios (Deepgram, ElevenLabs scribe_v1/v2, AssemblyAI, Gladia code-switching, Cartesia ink-whisper, Corti médico, Volcengine, Avalon, OpenRouter, Rev AI, xAI grok-stt, Mistral/Voxtral, Groq, OpenAI ± región EU, compatibles OpenAI-custom `/v1`, Ollama `localhost:11434`, LM Studio `localhost:1234`, HuggingFace router) + **Assistant** vía AIProxy (cloud "200x realtime" sin claves del usuario). Claves API en **Keychain** (`*APIKey_Key`), detectan cambios externos y MDM.

**B.3 Entrada de audio**
- Micrófono: pausa/reanudar, lista de prioridad de dispositivos, modo fijo/prioridad/sistema.
- Audio de sistema/app: backend conmutable **ScreenCaptureKit o CoreAudio**, cancelación de eco, selección de apps grabables, export de pistas (`Combined/Mic/App Audio`).
- **Reuniones**: detección automática de apps (Zoom, Teams, Meet, Webex, Discord, Slack, navegadores…), notificaciones, títulos desde **calendario**, auto-dismiss, contador de reuniones free.
- **Watch folders**: monitoreo con profundidad de subcarpetas, auto-export, notificaciones, guardar en historial, security-scoped bookmarks.
- **YouTube/URL**: cliente InnerTube propio con errores granulares (privado, members-only, región, livestream, edad) y fallback a servidor remoto propio.
- Lote y cola con pausa/reanuda; **podcasts** (auto-asignar hosts) y **multitrack** (una pista por hablante, beta).
- **Global window** (estilo Spotlight, always-on-top, auto-copy) y **atajos en Home**.

**B.4 Editor** — modos Editor (web)/Segments/Transcript/Inspector; segmentar, ajustar timestamps, milisegundos; **diarización** (WhisperKit/Parakeet local, cloud, SpeakerKit; merge/recluster/fotos/colores/8 paletas, entidad global *People*); favoritos por segmento y por palabra; find & replace + Global Replace; undo/redo; vídeo inline con PiP y subtítulos; re-transcripción con otro modelo manteniendo sesión.

**B.5 Exportación** — formatos `txt, srt, vtt, csv, json, html, md, pdf, docx, dote, avid, whisper`; estilos `fullTranscript, segments, subtitles, whisper, dote, script`; agrupación `none/words/sentences/people`; opciones (timestamps, fin de rango, ms, hablantes, solo favoritos, max chars/línea, FPS avid, columna de fichero); Quick Export, Batch Export, **Auto-Export** (formatos + resumen IA `.md` + media), destino "junto al audio" o "preguntar"; formatos propios = Pro.

**B.6 Traducción** — DeepL (formalidad, créditos), Apple Translation del sistema, Assistant (límite 25.000 chars); **auto-traducción** desde→a idiomas tras terminar; lado a lado; "solo modo activo" vs "transcript+segments"; `--translate` nativo a inglés.

**B.7 IA** — `AISummaryManager` (título, resumen corto/largo con chunking, tags, autostart), chat con el transcript (`AIChatManager`), 10 prompts predefinidos (FAQ, mindmap, estadísticas, emociones…), prompts custom con test, prompts por app; proveedores: OpenAI, Azure, Anthropic, Gemini, Groq, DeepSeek, xAI, OpenRouter, HF, Ollama, LM Studio, custom, Apple FM, Assistant; consentimiento explícito `gavePermissionForAIData`.

**B.8 Dictación y Live Captions** — push-to-talk o toggle (rightCmd/rightOption/fn/custom), overlay junto al campo de texto, pegado vía Accessibility (`PastingEngine`), corrección IA + puntuación, "usar texto en pantalla" (AX), diccionario de términos, mute de audio durante dictación, sonidos, historial con retención, WPM; Live Captions: ventana flotante/sidebar con tema/opacidad/tamaño/mayúsculas/idiomas, requiere modelo Parakeet.

**B.9 Integraciones** — Notion (API pages), Obsidian (Local REST API + YAML), Make/Zapier/n8n/custom webhook (con headers), formato de título con fecha, envío automático tras transcribir (Pro); **App Intent único** `TranscribeAudioIntent` (macOS 15+); URL scheme `macwhisper://` con **solo** `reopenWindow`; **CLI `mw`** (ver §3); widgets/iOS con app groups.

**B.10 Licencias** — Free (límite 200 historiales, 2 hablantes manuales, export básico) / **Pro one-time vía Gumroad** (+ StoreKit 2 suscripciones pro/assistant) / **Assistant** (IA+traducción+cloud sin claves) / MDM enterprise. Paywalls contextuales, remote config con flags de precio/descuento.

**B.11 UI** — `Router` con 20 raíces (`home, transcriptionDetail, transcriptionHistory, queue, recordings, dictationDetail, liveCaptions, batch, podcast, youtube, manageModels, watchFolders…`), sidebar con secciones (transcripciones/reuniones/personas), menubar `StatusBarItemManager`, onboarding multi-paso, remote config, roadmap con votación, localizaciones **en/de/nl**.

**B.12 Otras** — TelemetryDeck (opt-in, eventos de producto), logs con rotación + MetricKit, Sparkle (appcast + EdDSA), catálogo `models.json` remoto, descarga de modelos por chunks reanudables desde HuggingFace (`swift-transformers Hub`, `ChunkyDownloader`).

### 2.3 Detalles técnicos clave

- **`.whisper`**: ZIP propio (JSON de metadatos + audio/vídeo opcional + versión), UTI `com.goodsnooze.whisper`, único tipo "Editor/Owner". Metadatos: traducciones, idioma detectado, si hubo diarización.
- **UTIs**: exportadas `com.goodsnooze.whisper|.srt|.vtt` + markdown; importadas 11 (ogg, wav, aiff, mp3, mp4, mov, m4v, m4a, folder, caf).
- **CLI `mw`**: binario Swift Argument Parser; comandos release `transcribe | models list/select | version | help`; **transporte = Unix socket** `~/Library/Application Support/MacWhisper/cli.sock` (la app hace el trabajo; eventos `TranscriptionPartial/Progress/ModelList/…`); flags ricos (`--format/--style/--group/--timestamps/--end-timestamps/--milliseconds/--speakers/--speaker-names/--max-characters/--fps/--stream/--persist/--recursive/--output(-dir)/--overwrite`); instalación por symlink a `/usr/local/bin/mw` con privilegios admin; comandos `open-session/open-home/translate-to` **solo debug**.
- **Permisos/entitlements**: micrófono, audio de apps (`NSAudioCaptureUsageDescription`), calendario (títulos), Screen Recording, Accessibility (dictado), notificaciones. **Sin sandbox**, sin hardened runtime, universal, notarizado.
- **Persistencia GRDB/SQLite**: tablas `session`, `transcriptline` (+FTS5), `speaker`, `session_speaker`, `mediafile`, `dictation`, `session_fulltexttranslation`, `recordedmeeting`, `podcast`… con migraciones versionadas, backup pre-migración, soft-delete (Recently Deleted) y `wordsJson` (timestamps por palabra).
- **Descarga de modelos**: catálogo remoto `https://cdn.macwhisper.com/models.json`, HF Hub con token, chunks reanudables, rutas `models/whisperkit*`, limpieza de caches e5/CoreML.
- **App Intents**: 1 sola acción (`TranscribeAudioIntent`).
- **Remote config**: `remoteConfig.json` con flags de paywall, descuentos, deshabilitar YouTube, kick-out, etc.

---

## 3. Transcriptor X: estado actual (verificado en código)

**Arquitectura:** MVVM ligero + singletons (`.shared`), sin DI ni SPM; un único `TranscriptionViewModel` (1.261 líneas); comunicación por `NotificationCenter`; Swift 5, macOS 13+, sandbox **off**.

**Pipeline (verificado):** entrada (drag&drop/picker/URL/Grabación) → `NewTranscriptionSheet` (settings snapshot) → `JobManager` (cola **serial**, retry ≤3) → `AudioPreprocessor` (ffmpeg→WAV 16 kHz, DeepFilter, Demucs, loudnorm) → `TranscriptionService` (proceso externo `whisper-cli` con CoreML + Silero VAD + `-tdrz`, streaming por stdout, progreso por stderr, cancelación SIGTERM) → `TranscriptionStorage` (`transcriptions.json` atómico) → `TranscriptViewer` (edición, favoritos, búsqueda, 8 exports vía IR `ExportDocument`).

**Ya tiene:** grabación de micrófono y de sistema (ScreenCaptureKit), URL/YouTube (yt-dlp + fallback Innertube), cola con panel, preproceso neuronal, diarización tinydiarize, traducción solo→EN, historial, preferencias de 4 pestañas, setup de dependencias, recovery WAL (solo grabaciones), logging, localización ES/EN, atajos básicos de menú.

**Ausente (clave para la comparación):** IA/LLM alguna, traducción a idiomas ≠EN, proveedores cloud, watch folders, detección de reuniones, dictación, live captions, CLI/URL scheme/App Intents, `.whisper`/proyecto enriquecido, GRDB (JSON monolítico), multi-ventana/menubar, auto-export, global replace, presets (existen en código pero sin UI), tests unitarios.

**Deuda detectada (relevante al integrar):** `ModelManager` simulado; WAL de transcripción sin conectar; código muerto (`RecorderSheet`, `FavoritesDrawerView`, presets, `TranscriptionTask`); `NSScreenCaptureUsageDescription` no declarada en pbxproj; un solo VM gigante.

---

## 4. Matriz de integración: MacWhisper → Transcriptor X

**Criterio de producto (decisión del propietario, 2026-10):** Transcriptor X es **100 % gratis y local**. No se porta nada que requiera **nube, llamadas a APIs de terceros ni monetización (planes Free/Pro)**. Todo valor añadido debe funcionar offline con modelos locales (whisper.cpp, Ollama/LM Studio, Apple Translation/Framework Models). Las filas afectadas por este criterio están marcadas **✗ FUERA DE ALCANCE**.

Leyenda de esfuerzo: **S** (<1 día) · **M** (2–5 días) · **L** (1–3 semanas) · **XL** (>3 semanas).
Prioridad propuesta: **P0** (diferenciador/core), **P1** (muy valor), **P2** (fase posterior), **P3** (descartar de momento).

| # | Funcionalidad MacWhisper | Existe en TX? | Esfuerzo | Prioridad | Cómo integrarla (adaptada a TX) |
|---|---|---|---|---|---|
| 1 | **Post-proceso IA local** (título, resumen, tags, prompts) | **Hecho (local)** | **M** | **P1** | **Solo local:** `AIService` con `protocol LLMProvider` y únicamente **Ollama** (`localhost:11434`), **LM Studio** (`localhost:1234`) y **Apple Foundation Models** (macOS 26+). Nada de OpenAI/Anthropic/Gemini/Groq en la nube. Guardar `aiTitle/aiSummary` en la `Transcription`. UI: panel lateral en `TranscriptViewer`. Si no hay proveedor local disponible, la feature se oculta (patrón `correctlyConfiguredAIServicesManager`). Chat con transcript opcional en misma fase. |
| 2 | **Traducción a idiomas arbitrarios** | **Hecho (local)** | **M** | **P1** | **Solo local:** `TranslationService` con (a) **Apple `TranslationSession`** (del sistema, macOS 15+), (b) `whisper --translate` (ya existe, solo → EN), (c) LLM local vía Ollama. **Sin DeepL ni APIs.** Persistir por segmento con `decodeIfPresent` (convención 14 de CONTRIBUTING). En macOS 13–14 la opción principal es (b)+(c). |
| 3 | **CLI tipo `mw`** | ✅ **HECHO (Plan 2 2026-10-09):** target `tx` (parser manual, sin dependencias) + Unix socket `cli.sock` (0600) con framing JSON; `scripts/install_cli.sh` instala en `~/.local/bin`; `--format` solo extensión en v1 | **M** | **P0** | Target nuevo `tx` (Swift Argument Parser) + **Unix socket** en `Application Support/Transcriptor/cli.sock` con framing JSON; el CLI no transcribe, reenvía a la app (mismo patrón que MacWhisper: evita duplicar el motor). Reutiliza `JobManager.enqueue`. Flags mínimos v1: `--format, --language, --output, --stream, --speakers`. |
| 4 | **Watch folders** | ✅ **HECHO (Plan 2 2026-10-09):** `WatchedFoldersManager` (DispatchSource, seed/scan) + auto-export SRT `AutoExporter` al guardar en historial; UI en Preferencias (bookmarks/TCC: sin sandbox, no aplican) | **M** | **P0** | `WatchedFoldersManager` con `NSFileCoordinator`/DispatchSource + security-scoped bookmarks (TX no es sandbox, pero conviene bookmarks por robustez). Engancha directo a `JobManager.enqueue(files:)` y auto-export con `ExportDocument` + `autoExportEnabled`. |
| 5 | **Export: faltan json/avid + estilos/agrupación** | ✅ **HECHO (completo, Plan 4 2026-10-10):** json (Fase 0) + `case avid` (CMX3600, `AvidExportGenerator` con fps) + `ExportStyle`/`ExportGroupingPreference` con preferencias persistidas (`exportStyle/Grouping/favoritesOnly/milliseconds/fps` en `TranscriptionSettings`), UI en Preferencias y 13 claves `export.*` | **S–M** | **P1** | Ampliar `ExportFormat` (json, avid) y añadir `ExportStyle`/`ExportGroupingPreference` como en MacWhisper; la IR `ExportDocument` ya está diseñada para eso. Auto-export tras completar job = gancho para #4 y #1. |
| 6 | **Persistencia en SQLite (GRDB) con FTS5 y soft-delete** | ✅ **HECHO (Plan 5 2026-10-10):** SQLite nativo (`import SQLite3`, sin SPM — el plan descarta GRDB por eso): tabla única `transcriptions` con payload JSON completo + espejo FTS5 contentless (escape de frase, fallback LIKE), WAL + busy_timeout; migración one-shot `transcriptions.json` → `.bak` (60/60 filas verificadas); API de `TranscriptionStorage` intacta; búsqueda FTS en el drawer con debounce 300 ms | **L** | **P1** | Migración de `transcriptions.json` → tablas `session`/`transcriptline`(+FTS5)/`speaker`. Beneficios: búsqueda global, "Recently Deleted", rendimiento con historiales grandes, campo `wordsJson` (habilita edición palabra a palabra, ver #12). *Alternativa mínima:* mantener JSON y añadir solo índice; no recomendado si se ambiciona historial tipo MacWhisper (200+ items en Free). |
| 7 | **Grabación de reuniones / detección de apps** | ✅ **HECHO (Plan 6 2026-10-10):** `MeetingWatcherService` (Timer 2s + EventKit ±5min con permisos `NSCalendars*`, fallback "Reunión — App" con app de reunión activa), notificación `.meetingDetected` → banner naranja "Grabar ahora" (auto-hide 15s, `RecordingFloatingPanel` comparte `SystemAudioRecorder.shared`), setting `meetings.auto`; sin evento/calendario en vivo (TCC) — verificado por lldb E1–E4 | **L** | **P1** | Ya está el 60 %: `SystemAudioRecorder` (SCStream) + selección de dispositivos. Falta: detección de apps de reunión (`NSWorkspace` frontmost + lista de bundle IDs), notificación con "Grabar ahora", títulos desde calendario (`EventKit`), sesión `recordedmeeting`. Evitar el beta-fragility que MacWhisper advierte. |
| 8 | **Diarización real (hablantes con nombre/merge/fotos)** | ✅ **HECHO (Plan 6 2026-10-10):** Opción A: `Transcription.speakerNames` + `SpeakerLabelView` en la etiqueta (doble clic renombrar inline, menú contextual Renombrar/Fusionar con…/Restaurar nombre, colores existentes); VM `renameSpeaker`/`mergeSpeaker` renumera índices 0..n-1 con persistencia sqlite; exports TXT/CSV/HTML/SRT/VTT/MD/DOCX resuelven nombre vía `ExportDocument.speakerLabel` (corrige bug base-0 de HTML/DOCX); pruebas lldb E1–E3 ✓ | **L** | **P1** | Opción A: seguir con tinydiarize + UI de renombrar/merge/colores (ya hay `speaker` en `TranscriptionSegment`) — barata. Opción B: modelo tipo SpeakerKit/pyannote local — cara. Recomendación: A primero, B en fase 2. Añadir entidad "Personas" como MacWhisper solo si B llega. |
| 9 | **Export `.whisper` propio (paquete de proyecto)** | ✅ **HECHO (Plan 4 2026-10-10):** paquete `.transcriptor` (ZIP vía `/usr/bin/zip`): `manifest.json` + `transcript.json` + `media/` opcional; UTI `io.github.alexbernaldo.transcriptorx.project` + `CFBundleDocumentTypes` vía Run Script/PlistBuddy; guardar desde menú export, abrir por doble clic (`application(_:open:)` → `TranscriptionStorage`) | **M** | **P1** | ZIP (usar `ZIPFoundation`) con JSON de metadatos + media + transcripción; registra UTI `io.github.alexbernaldo.transcriptorx` + tipos de documento en Info.plist. Soluciona "compartir proyecto completo" sin depender de la BD. |
| 10 | **Global window / menubar** | ✅ **HECHO (Plan 6 2026-10-10):** `MenuBarExtra(isInserted:)` con panel `.window` `MenuBarContentView` (última transcripción, Grabar/Detener, cola, Nueva/Historial/Ajustes/Salir) + toggles en Preferencias; keep-alive: `applicationShouldTerminateAfterLastWindowClosed` + gate `applicationShouldTerminate` (macOS 27 postea kAEQuit al cerrar ventana/alternar panel) — cancel solo sin ventana normal visible y sin evento explícito; pruebas lldb de cancel/permitir/muerte ✓ (apertura del panel = manual: menú oculto en el entorno de pruebas) | **M** | **P2** | `MenuBarExtra` (macOS 13+) con inicio rápido de grabación y últimos trabajados; `GlobalWindowController` estilo Spotlight opcional después. Requiere pulir `applicationShouldTerminateAfterLastWindowClosed` (hoy cierra la app). |
| 11 | **Live captions (overlay en vivo)** | ✅ **HECHO (Plan 7 2026-10-10):** `LiveCaptionView` + `LiveCaptionOverlayController` (NSPanel nonactivating `.screenSaver`, `canJoinAllSpaces + fullScreenAuxiliary`, texto = `streamingText` con retardo whisper — documentado en el toggle "Subtítulos en pantalla", off por defecto, auto-hide 4 s sin segmentos); pruebas de overlay sobre vídeo = manuales | **L** | **P2** | Necesita modelo streaming (Parakeet-like) — con whisper.cpp sería.latente (latencia alta). Posible v1 con `realtimeWhisperManager`-style en fragmentos de 1–2 s. Dependencia fuerte: #8 y motor con streaming de palabras. |
| 12 | **Editor enriquecido: word-level timestamps, find&replace global, segmentar, ajustar timestamps** | ✅ **HECHO (Plan 4 2026-10-10):** find & replace global (+toggle `plusminus`), split/merge/ajuste de timestamps desde `CinemaSegmentRow`, word-level timestamps (`whisper -ojf` + `words` por segmento + resaltado en playback) | **M** | **P1** | whisper.cpp ya puede emitir `--output-json` con tokens; falta UI. Global Replace con import/export JSON como MacWhisper. "Un segmento por palabra" y ms configurables = flags de `TranscriptionSettings` existentes. |
| 13 | **Dictación (push-to-talk → pegar en app activa)** | ✅ **HECHO v1 (Plan 7 2026-10-10):** `DictationManager` (Carbon `RegisterEventHotKey` ⌃⌥Espacio/D/R configurable, mic vía `SystemAudioRecorder.shared`, transcripción DIRECTA sin cola ni historial + audio efímero borrado, paste CGEvent Unicode chunks de 20 UTF-16 con protección de pares sustitutos, overlay "Escuchando…", AX en runtime SOLO prompt desde Ajustes); registro de hotkey verificado por log; prueba manual con TCC mic/AX pendiente | **XL** | **P3** | Subsistema aparte: GlobalKeyboardShortcut, Accessibility (`PastingEngine`), overlay. Muy alejado del core "transcriptor"; considerar solo si el producto se reposiciona. |
| 14 | **YouTube mejorado / clientes propios** | ✅ **HECHO (Plan 7 2026-10-10):** `classifyYouTubeError/classifyYtDlpError` con 6 casos (privado/región/edad/unavailable/cookies/subtitles) aplicado al fallo de yt-dlp y al fallback Python; 6 mensajes localizados en `URLInputSheet`; patrón `"video is unavailable"` verificado contra yt-dlp real; cero código InnerTube nuevo | **M** | **P2** | Refinar errores granulares (privado/region/edad) como MacWhisper; **no** clonar el InnerTube cracking (riesgo legal/ToS y mantenimiento). Depender de yt-dlp es más sostenible. |
| 15 | **Multi-cloud ASR (Groq/Deepgram/OpenAI/…)** | No | — | **✗ FUERA DE ALCANCE** | Requiere APIs de terceros. No se porta. Alternativa local equivalente: nuevos motores locales (Parakeet/Qwen3-ASR vía MLX o whisper.cpp) si se quisiera competir en velocidad/precisión, todo descargable y ejecutable en el equipo. |
| 16 | **Multi-archivo con estilos de agrupación, batch export** | ✅ **HECHO (batch export, Plan 2 2026-10-09):** `exportAll(format:to:)` + menú "Exportar todo" en el drawer; estilos/agrupación pendientes | **S** | **P1** | Falta batch export (exportar todos los jobs completados con un set de formatos) + `--output-dir` equivalente en UI. |
| 17 | **Presets de transcripción (Lecture/Podcast/Interview)** | ✅ **HECHO (Fase 0 2026-10-09):** fila "Quick settings" en `NewTranscriptionSheet` (UI en `PreferencesSheet` pendiente) | **S** | **P0** | Ya están `TranscriptionSettings.lecture/podcast/interview` (Models.swift:419-451) sin referenciar: botones en `NewTranscriptionSheet` + `PreferencesSheet`. Quick win. |
| 18 | **Historial con Recently Deleted / retención** | ✅ **HECHO (Plan 5 2026-10-10):** soft-delete `deleted_at` + API `loadTrash/restoreTranscription/deleteForever/purgeTrash` (retención `trashRetentionDays` default 30, picker 7/14/30/90 en Comportamiento, purga al arrancar), UI Papelera en el drawer (toggle, estados vacíos, Restaurar/Eliminar definitivamente, audio intacto hasta la purga); pruebas T1–T4 ✓ | **S–M** | **P2** | Soft-delete en `TranscriptionStorage` (marcar `deletedAt`, purga a N días). Si hay migración a SQLite (#6), gratis con el patrón `DeletableItem`. |
| 19 | **Remote config / Sparkle / telemetría** | ✅ **HECHO (Plan 7 2026-10-10):** Sparkle **2.10.0** vía SPM (excepción al "sin SPM" registrada), `SPUStandardUpdaterController(startingUpdater: true)` semanal silencioso, menú Ayuda "Buscar actualizaciones…" (⌘U), `SUFeedURL` + `SUPublicEDKey` (clave EdDSA en Keychain, nunca en repo) vía Run Script PlistBuddy — pendiente de release publicada: `sign_update` + `appcast.xml` en GitHub Releases. **Remote config ✗ y telemetría ✗ siguen fuera de alcance** | **S** | **P2 (parcial)** | **Remote config ✗ fuera de alcance** (solo sirve para flags de paywall/monetización). **Telemetría ✗ fuera de alcance** (privacy-first, y MacWhisper solo la usa para su negocio). **Sparkle sí**: appcast propio para actualizaciones — es descarga de fichero, no API, y mantiene el producto vivo. |
| 20 | **Monetización (Free/Pro/Assistant, paywalls)** | No | — | **✗ FUERA DE ALCANCE** | Todo gratis. No se porta paywalls, ni StoreKit, ni Gumroad, ni MDM, ni límites (historial 200, 2 hablantes…). La matriz Free/Pro de §6.6 queda como referencia histórica del modelo de negocio de MacWhisper, no como plan de TX. |
| 21 | **App Intents / Shortcuts** | ✅ **HECHO (Plan 2 2026-10-09):** `TranscribeFileIntent` registrado en `Metadata.appintents` (ejecución interactiva en Atajos pendiente de prueba manual) | **S** | **P1** | 1 intent `TranscribeFileIntent` (macOS 13+ con App Intents), coste bajo, visibilidad alta en Spotlight/Atajos. |
| 22 | **URL scheme** | ✅ **HECHO (Plan 7 2026-10-10):** `CFBundleURLTypes` vía Run Script PlistBuddy, `application(_:open:)` fusionado con el `.transcriptor` del Plan 4; rutas `transcribe?url=` (notificación `.transcribeURL` → sheet `URLInputSheet(initialURL:)` precargada) y `open` (sin `activate` — restricción de foco); los 3 deep links verificados con app viva por logs AppLogger | **S** | **P2** | `transcriptorx://` con rutas reales (`transcribe?url=`, `open`) — más útil que el de MacWhisper (que solo tiene `reopenWindow`). |
| 23 | **Onboarding asistido + detección de dependencias** | `SetupView` ya existe | **S** | **P0** | Ya está; mejorar con diagnóstico "un clic" (Homebrew/FFmpeg/whisper/yt-dlp) y estado visible, al estilo MacWhisper. |
| 24 | **Saneamiento de código muerto y WAL de transcripción** | ✅ **HECHO (Fase 0 2026-10-09):** WAL conectado a `JobManager` (solo ruta multiarchivo; single-file sin WAL) + código muerto borrado (RecorderSheet, SplashScreenView, AppPreferences, FavoritesDrawerView, TranscriptionState, TranscriptionTask) | **S** | **P0** | Conectar `RecoveryManager.beginTranscriptionSession` a `JobManager` antes de añadir más features (evita perder trabajos largos). Quitar/aislar `RecorderSheet`, `FavoritesDrawerView`, etc. |

### 4.1 Fases recomendadas (alcance: local y gratis)

- **Fase 0 — Cimientos (1 semana):** #24, #17, #5 (json), #23 + brecha de permisos `NSScreenCaptureUsageDescription` (§6.7). Deja la base limpia.
- **Fase 1 — Diferenciador (2–4 semanas):** #3 (CLI socket), #4 (watch folders), #12 (editor), #21 (App Intent), #2 (traducción local), #1 (IA local con Ollama/LM Studio/Apple FM, degradando con elegancia si no hay proveedor).
- **Fase 2 (4–6 semanas):** #6 (SQLite/FTS), #7 (reuniones), #8 (diarización con nombres), #9 (`.whisper`), #16, #10, #18.
- **Fase 3 (opcional):** #11 (captions, requiere motor streaming), #14 (mejora de errores de YouTube — ya existe en TX), #19 (solo Sparkle).
- **✗ Fuera de alcance (decisión explícita):** #15 (cloud ASR), #20 (monetización/paywalls), remote config, telemetría, APIs DeepL/OpenAI/Anthropic/Gemini en la nube. **#13 (dictación)** se mantiene en P3: es local (AX + micrófono), pero es un subsistema grande ajeno al core.

> Nota: "local" incluye features que **necesitan red solo para descargar** (modelos, CoreML, actualizaciones Sparkle) — eso ya lo hace TX hoy y no cuenta como nube. Lo que no entra es **ejecutar el trabajo en servidores ajenos**.

### 4.2 Patrones de MacWhisper que merece la pena copiar *conceptualmente*

1. **CLI = thin client sobre Unix socket** (la app es la única dueña del motor; streaming de parciales). Evita duplicar lógica y permite `--stream`.
2. **IR de export con estilos/agrupación** (TX ya tiene `ExportDocument`: ampliarla, no reescribirla).
3. **Auto-export + watch folder como trinquete** (evento `job completed` → export + integración).
4. **Post-proceso IA desacoplado** (`AISummaryManager`-like con `protocol` de proveedor) — **adaptado: solo proveedores locales** (Ollama, LM Studio, Apple Foundation Models).
5. **Traducción multi-proveedor con persistencia por segmento** — adaptado a Apple Translation + LLM local (sin DeepL).
6. **Soft-delete + FTS5** para un historial que crece.
7. ~~Remote config~~ — descartado (solo aporta flags de monetización).
8. **Modelos descargados por chunks reanudables** (TX ya descarga; añadir reanudación si falla).
9. **Lista de claves/estados de UI como clusters tipados** (los defaults del §6.4 muestran cómo un store plano escala mejor que Bool dispersos).

### 4.3 Riesgos y diferencias a respetar

- **Legal/ToS:** no copiar InnerTube cracking ni textos/strings literales largos; reimplementar funcionalidades. Revisar licencias de WhisperKit/Argmax si se adoptan (TX es PolyForm Noncommercial).
- **Sandbox:** TX tiene `app-sandbox=false` y sin notarizar; MacWhisper también sin sandbox pero **notarizado**. Si se quiere distribuir fuera del propio DMG, hay que planear firma+notarización (y eso activaría restricciones a revisar para rutas de whisper.cpp/binarios externos).
- **Escala de esfuerzo real:** MacWhisper es un producto comercial de muchos años; la lista anterior está priorizada para **no** intentar clonarlo entero. El núcleo competitivo de TX (preproceso neuronal + pipeline local cuidado) es diferencial: MacWhisper no tiene Demucs/DeepFilter.
- **Deuda primero:** añadir IA/CLI/watch folders sobre `TranscriptionViewModel` de 1.261 líneas y un JSON monolítico multiplicará el caos; la Fase 0 existe por eso.

---

## 5. Huecos de la investigación — estado de cierre

| Hueco | Estado |
|---|---|
| JSON remotos (`models.json`, `remoteConfig`, `appcast`, release notes) | **CERRADO** — descargados a `/tmp/mw_remote/` (ver §6.1–6.2) |
| Array real de idiomas | **CERRADO con matiz** — función SWITCH con **120 casos** verificados por jump table; nombres estilo CLDR (ver §6.3) |
| App ID TelemetryDeck | **CANDIDATO ALTO** — UUID `5AAEE413-092E-461F-8856-858745AE7FA9`, adyacente a `analyticsEnabled`/eventos (ver §6.5) |
| Matriz Free/Pro | **CERRADA** — `fakeRemoteConfig.json` → `paywallFeatures` completo (ver §6.6) |
| Resto de claves `UserDefaults` | **CERRADO (claves clave)** — clusters contiguos A–G extraídos (ver §6.4); el resto de `camel.txt` sigue siendo solo identificadores |
| `NSAudioCaptureUsageDescription` en TX | **CONFIRMADA LA BRECHA** — no existe en `project.pbxproj` de TX; MacWhisper sí la declara (ver §6.7) |

---

## 6. Addendum de verificación (evidencia forense y datos remotos)

### 6.1 Catálogos remotos (`/tmp/mw_remote/`)

| Archivo | Contenido |
|---|---|
| `remoteConfig.json` (1.948 B) | Flags de paywall actuales: `translateLocales [fr,es,pt]`, `highlightedIAPId pro.annual`, descuento home screen "MW-2026" 10 %, `showPhoneApp` → App Store `id1668083311` |
| `remoteConfigTwo.json` | Link de TestFlight |
| `models.json` | Catálogo **solo ggml/whisper.cpp**: 15 modelos, `remoteUrl https://stickytimers.app/*.bin`, flags Pro por modelo, `latestVersion 1300` |
| `appcast.xml` | 219 ítems; últimas versiones **15.4 / 15.3 / 15.2.1** — la instalada es 14.5 → el catálogo vivo corre por delante |
| `appReleaseNotes.json` | **103 releases, 917 features** (168 new / 466 improved / 283 fixed), **173 con `requiresPro`** |

Highlights del changelog vivo (14.5 → 15.4, todos Pro salvo indicación): Qwen3-ASR en Apple Silicon; Grok Voice Transcribe 2; **macOS 26+**: audio de sistema vía CoreAudio (solo permiso *System Audio Recording*, en vez de ScreenCaptureKit) + cancelación de eco global; **Nemotron 3 Diarization** (Sortformer v3, ≤8 hablantes, bundled) y Pyannote seleccionables; live meeting transcription ON por defecto con diarización; transcripciones hasta 10 h / 3 GB; watched folders con espera de copias/iCloud; Cohere Transcribe, Speechmatics, Gemini 3.5 Transcribe, gpt-transcribe; traducción y captions en vivo; integraciones Make/Zapier/n8n/webhook/Obsidian.

### 6.2 Remote config vivo vs fallback

Las claves del cluster E (`showSuperPaywall`, `hideWeeklyCompletely`, `highlightedIAPId`, `paywallCTA`…) son **claves de remote config**, no de UserDefaults: el paywall es configurable en caliente sin actualizar la app (patrón a copiar: feature flags remotos).

### 6.3 Idiomas — 120 casos verificados

- Función de nombres de idioma = **SWITCH con 120 casos** (jump table en vmaddr `0x1009c874c`, 120 entradas de 4 bytes, 120 destinos únicos).
- Nombres reconstruidos de immediates: Chinese, Maltese, Haitian Creole, Portuguese, Afrikaans, Cantonese, Luxembourgish, Kabuverdianu, Nynorsk, Yiddish, Faroese, Bashkir, Wolof, Umbundu, Odia, Ganda, Sinhala…
- Procedencia **CLDR/Apple Locale** (no la tabla en minúsculas de whisper.cpp). Duplicados de nombre (Serbian ×6, Chinese ×3, Fulah ×5) = múltiples códigos/locales → **~120 códigos ≈ ~90 nombres distintos**; "100+ languages" es marketing coherente con el dato.
- No existe como `__cstring` completo: solo viven como immediates en el código (por eso `strings` no los encontraba).

### 6.4 UserDefaults — clusters de claves confirmadas

Extraídos de `strings` (claves contiguas = mismas zonas de `registerDefaults:`). Las 9 previas quedan confirmadas dentro de estos clusters:

- **A** (auto-export + limpieza + AI summary flags): `autoExportEnabled`, `autoExportDestinationFolder`, `autoExportAISummaryEnabled`, `autoExportMediaFileEnabled`, `shouldAutoCleanupTranscripts`, `includeBulletPointsInSummary`, `includeSectionsInSummary`, `highlightActionItemsInSummary`, `includeKeyPointsInSummary`, `includeSpeakersInAIPrompt`, `firstAppOpenTimestamp`, `firstTranscriptionTimestamp`, `knownRanVersions`, `appVisibilityMode`, `dictationOverlayPosition`, `dictationSoundsEnabled`.
- **B** (WhisperKit/GPU): `useWhisperKitAudioPipelineWhenPossible`, `useWhisperKitFastLoading_onByDefault`, `whisperKitVADWorkerCount`, `whisperKitShouldUseVAD`, `parakeetKitProShouldUseVAD`, `whisperKitEncoderPreferredCompute`, `whisperKitDecoderPreferredCompute`, `disableAllGPUUsageToMitigateCrash_offByDefault`.
- **C** (AI services): `gavePermissionForAIData`, `configuredCloudTranscriptionProviders`, `configuredAIServices_15july2025`, `selectedAIServiceID`, `selectedAIServiceIDForDictation`, `selectedAISummarizationProviderID`, `useCustomAITitlePrompt`, `customAITitlePrompt`, `useCustomAIShortSummaryPrompt`, `customAIShortSummaryPrompt`.
- **D** (live captions): `liveCaptionsTheme`, `liveCaptionsOpacity`, `liveCaptionsTextSize`, `liveCaptionsUppercase`, `liveCaptionsInputLanguage`, `liveCaptionsOutputLanguage`, `liveCaptionsTranslateEnabled`, `liveCaptionsTranslateTargetLanguage`, `liveCaptionsHypothesisDebounceMs`, `liveCaptionsLastUsedSource`, `liveTranscriptionAnimateTextChanges`, `liveTranscriptionRunnerConfig`.
- **F** (cloud/whisper runner): `deepgramFillerWords`, `deepgramCloudTranscriptionRegion`, `openAICloudTranscriptionRegion`, `elevenLabsNoVerbatim`, `customOpenAIWhisperProviderModel/BaseURL`, `whisperManagerRetentionMode`, `shouldLoadModelOnLaunch`, `whisperShouldTranslateResultsToEnglish`, `selectedRunnerConfig`, `shouldDetermineCorrectOffsetOfWaveData`, `downmixToMonoUsingNativeAPI_jun2025_defaulttrue`.
- **G** (editor/dictación): `autoScrollWhilePlaying`, `showSpeakerNamesInSegments`, `showTimestampMilliseconds`, `showTimestampInSegment`, `showEndTimestampInSpeakerGrouping`, `dictationActivationMode`, `dictationKeyboardButton`, `dictationRetentionPeriod`.
- Sueltas: `analyticsEnabled`, `mdmAnalyticsEnabled`.

### 6.5 TelemetryDeck

UUID candidato **`5AAEE413-092E-461F-8856-858745AE7FA9`** — adyacente literalmente a `analyticsEnabled` / `mdmAnalyticsEnabled` y a la lista de eventos (`liveCaptionsStarted`, `purchaseLicenseGumroadDirectClicked`, …). Las apps TelemetryDeck usan UUID (no 32-hex). **Alta confianza, no ejecutado en runtime.**

### 6.6 Matriz Free vs Pro (definitiva, `fakeRemoteConfig.json → paywallFeatures`)

**FREE:** calidad "buena" de transcripción (modelos básicos), abrir/drag&drop, micrófono, historial 200, 100+ idiomas, editor completo, **2 hablantes manuales**, export `txt/srt/vtt/csv/whisper` (transcript + segments), vídeo inline, 3 modos de display.

**PRO (one-time, Gumroad):** modelos Medium/Large/Distil + cloud + *Advanced Whisper Settings*; hablantes ilimitados; URLs/batch/auto-export; audio de sistema; reuniones (Zoom/Teams); auto-asignación de hablantes en podcasts; menubar + Global; export `docx/pdf/html/dote` + traducciones + con nombres de hablante; subtítulos sobre vídeo + traducciones múltiples; YouTube; IA (ChatGPT/Claude/prompts custom); traducción DeepL multi-idioma.

Matiz: la matriz de `fakeRemoteConfig.json` es la **incluida en el binario como fallback**; los flags concretos (`hideMonthlyCompletely`, `highlightedIAPId`, descuentos) los controla el remote config vivo — la puerta es configurable en caliente.

### 6.7 Permisos: brecha TX vs MacWhisper

- MacWhisper declara: `NSMicrophoneUsageDescription`, `NSAudioCaptureUsageDescription`, `NSCalendarsFullAccessUsageDescription` + enlaces a Privacidad para Screen Recording/Accessibility.
- **TX solo declara `NSMicrophoneUsageDescription`** en `TranscriptorNative.xcodeproj/project.pbxproj`. `SystemAudioRecorder` usa ScreenCaptureKit → **falta `NSScreenCaptureUsageDescription`** (y `NSAudioCaptureUsageDescription` si se captura audio de apps). Acción Fase 0.

## 7. Bugs preexistentes (hallados durante la Fase 0)

### Bug #1 — La app no transcribía con los settings por defecto (FIXED, 2026-10-09)

- **Síntoma:** cualquier job con `TranscriptionSettings()` por defecto terminaba con `Transcription error (code: 3)` (exit 3 de `whisper-cli`), es decir: la app no podía transcribir nada en esta máquina con sus ajustes normales.
- **Causa raíz (doble):**
  1. `DependencyManager.swift` compilaba whisper.cpp con `-DWHISPER_COREML=1` **sin** `-DWHISPER_COREML_ALLOW_FALLBACK=1` → la opción (default OFF en `whisper.cpp/CMakeLists.txt`) dejaba `WHISPER_COREML_ALLOW_FALLBACK:BOOL=OFF` en `CMakeCache.txt`.
  2. Con esa compilación, `whisper_init_state()` (`whisper.cpp/src/whisper.cpp:3440-3454`) **exige** el encoder CoreML `<modelo>-encoder.mlmodelc`: si falla su carga → `#ifndef WHISPER_COREML_ALLOW_FALLBACK` → `return nullptr` → "failed to initialize whisper context" → exit 3. `whisper-cli` no expone ningún flag runtime para desactivarlo.
  3. Agravante: `TranscriptionService.swift:622-645` (STEP 0b) con `useCoreML=false` (el default) renombra los encoders a `.off` vía `disableCoreML()` (líneas 308-321) para no usar la ANE → con este binario, el renombrado **garantizaba** el exit 3. Máquinas sin encoder descargado también fallaban por el mismo motivo (el init lo exige).
- **Fix (commit `8d7c11d` "fix: transcribe with default settings"):** `DependencyManager.swift` ahora (a) añade `-DWHISPER_COREML_ALLOW_FALLBACK=1` al cmake de `installCommands`, y (b) `checkCommand` exige `WHISPER_COREML_ALLOW_FALLBACK:BOOL=(ON|1)` en el `CMakeCache.txt` existente → instalaciones con el binario roto disparan reinstalación/rebuild desde SetupView. `disableCoreML` se mantiene (con fallback ON hace su trabajo: sin renombrar, whisper cargaría el encoder y usaría la ANE pese al default `useCoreML=false`).
- **Verificación:** rebuild local del binario con el flag; CLI con encoder `.off` → exit 0 (antes 3) y salida idéntica a CoreML; test in-app con `TranscriptionSettings()` puros sobre audio de 29 s → job completó en ~1 s, 1 segmento con texto real, manifiesto WAL limpio, entrada guardada en el historial. Binario reconstruido con `WHISPER_COREML_ALLOW_FALLBACK:BOOL=1`.
- **Nota de entorno (no es bug del código):** la app está firmada *adhoc* → cada rebuild invalida el acceso TCC previo a `~/Downloads`; los tests por lldb con un path crudo ahí dejan el `open()` de ffmpeg bloqueado esperando permiso. En uso normal el usuario elige el archivo con NSOpenPanel (security scope) y no aplica.
