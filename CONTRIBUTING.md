# Cómo contribuir

Gracias por querer mejorar TranscriptorX. Antes de enviar un cambio, lee este
documento: te ahorra que un PR vuelva atrás.

## Antes de empezar: la licencia

Este proyecto usa la **PolyForm Noncommercial 1.0.0**. Puedes usar, estudiar y
modificar el software libremente, siempre con fines no comerciales. No puedes
venderlo ni usarlo dentro de un producto o servicio de pago.

Al enviar un pull request confirmas que tu contribución se publica bajo esa
misma licencia. Si no estás de acuerdo, no abras el PR.

## Requisitos

- macOS 13 o superior.
- Xcode con las herramientas de línea de comandos (`xcode-select --install`).
- `gh` (CLI de GitHub) solo si vas a descargar binarios desde el Release.

## Clonar

```bash
git clone https://github.com/alexbernaldo/TranscriptorX.git
cd TranscriptorX
```

## Binarios del motor de audio

Dos ejecutables van dentro de la aplicación pero **no** se versionan en git: el de
separación de voces (`demucs-bundled`, ~120 MiB) supera el límite de 100 MiB por
fichero de GitHub. Se distribuyen como assets del Release.

```bash
bash scripts/fetch_binaries.sh
```

Los deja en `TranscriptorNative/AudioEngine/lib/`, que es de donde Xcode los
copia a la aplicación al compilar. Si prefieres compilarlos tú mismo, las
instrucciones están en `TranscriptorNative/AudioEngine/README.md`.

## Compilar

```bash
xcodebuild -project TranscriptorNative.xcodeproj \
  -scheme TranscriptorNative \
  -configuration Release \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Para una compilación normal desde Xcode: abre `TranscriptorNative.xcodeproj` y
pulsa *Run*.

## Comprobaciones antes de abrir un PR

```bash
# Toda clave de localización existe y tiene versión en español e inglés
python3 scripts/check_localization.py
```

Si el script falla, sûrrelo antes de continuar: es lo que garantiza que la
interfaz esté traducida.

Revisa además:

- Que no introduces rutas absolutas de tu máquina (`/Users/...`) ni datos
  personales.
- Que no versionas ficheros grandes ni generados: `DerivedData/`, `dist/`,
  `*.dmg`, y los binarios de `TranscriptorNative/AudioEngine/lib/` ya están en
  `.gitignore`.
- Si tocas el motor de audio o sus licencias, actualiza
  `THIRD_PARTY_NOTICES.md`.

## Estructura del repositorio

```
TranscriptorNative/
  App/            Punto de entrada de la app (SwiftUI, ciclo de vida)
  Views/          Pantallas: Main, Sheets, Setup, Components
  ViewModels/     Lógica de presentación (TranscriptionViewModel)
  Services/       Transcripción, modelos, jobs, exportación, dependencias
  Models/         Tipos de dominio y preferencias
  Resources/      Catálogo de localización, assets, tema
  AudioEngine/    Puente a Demucs/DeepFilterNet, binarios y scripts Python
docs/             Documentación de diseño y UX
scripts/          Utilidades (localización, descarga de binarios)
licenses/         Textos de licencia de terceros
```

## Pull requests

1. Una funcionalidad o una corrección por PR.
2. Explica **qué** cambias y **por qué**.
3. Indica cómo lo has probado.
4. Si toca la interfaz, revisa `docs/heuristics-checklist.md` y actualiza lo que
   corresponda.

Al abrir el PR se rellenará automáticamente la plantilla de `.github/`.
