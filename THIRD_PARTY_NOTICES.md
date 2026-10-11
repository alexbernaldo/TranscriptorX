# Third-Party Notices

Transcriptor X distribuye o enlaza componentes de terceros. Este documento
recoge su atribución. Los textos de licencia completos están junto a este
fichero, en la carpeta indicada para cada componente cuando aplica.

## Componentes redistribuidos dentro de `demucs-bundled`

`TranscriptorNative/AudioEngine/lib/demucs-bundled` es un ejecutable generado
con PyInstaller que empaqueta los siguientes proyectos:

### PyTorch
- Licencia: BSD-3-Clause
- Copyright: The PyTorch Authors (Facebook, Inc.)
- Texto completo: ver `licenses/torch-LICENSE.txt` y `licenses/torch-NOTICE.txt`

### torchaudio
- Licencia: BSD-2-Clause
- Copyright: The torchaudio Authors (Facebook, Inc.)
- Texto completo: ver `licenses/torchaudio-LICENSE.txt`

### Demucs
- Licencia: MIT (código)
- Copyright: Meta Platforms, Inc. and affiliates
- Texto completo: ver `licenses/demucs-LICENSE.txt`
- **Nota sobre pesos:** los pesos preentrenados de Demucs (htdemucs) se
  distribuyen bajo CC-BY-NC 4.0. **No se redistribuyen en este repositorio ni
  en el binario**; la aplicación los descarga en tiempo de ejecución.

### Otras dependencias empaquetadas
numpy (BSD), sympy (BSD), networkx (BSD), einops (MIT), julius (MIT),
openunmix (MIT), dora-search (MIT), coremltools (BSD), lameenc (LGPL),
PyInstaller (GPLv2-or-later con excepción para el bootloader), y otras
dependencias transitivas. Ver `licenses/LICENSES-INVENTORY.txt` para la lista
completa con su licencia.

## Componentes redistribuidos como `deep-filter`

`TranscriptorNative/AudioEngine/lib/deep-filter` es un ejecutable derivado de
**DeepFilterNet** (Rikorose).
- Licencia: MIT / Apache-2.0 (dual)
- Texto completo: ver el repositorio upstream
  `https://github.com/Rikorose/DeepFilterNet` (el binario no lleva el fichero de
  licencia incrustado; no se ha capturado copia local)
- **Nota:** los pesos del modelo (df_v3_48kHz.onnx) se descargan en tiempo de
  ejecución y no se redistribuyen aquí.

## Componentes descargados en tiempo de ejecución (no redistribuidos)

- **whisper.cpp** (ggerganov) — MIT. Se clona con `git clone` al instalar.
- **FFmpeg** — instalado vía Homebrew por `DependencyManager`.
- **Modelos Whisper GGML** — descargados desde Hugging Face por la app.

## Nota sobre licencias de terceros

Este aviso se ofrece de buena fe para cumplir con las condiciones de
atribución. No constituye asesoramiento legal. Si eres autor de alguno de
estos proyectos y crees que la atribución es incorrecta o incompleta, abre un
issue en el repositorio.

## FluidAudio (identificación de hablantes)

- Paquete Swift `FluidInference/FluidAudio` 0.17.x, enlazado en la aplicación.
  Licencia **Apache 2.0** (Copyright FluidInference). Incluye código de
  fastcluster (BSD) y VBx (Apache 2.0); sus licencias están en
  `ThirdPartyLicenses/` dentro del paquete.
- Modelos Core ML de `FluidInference/speaker-diarization-coreml` (revisión
  fijada por FluidAudio), **no incluidos en la app**: se descargan de Hugging Face
  la primera vez que se identifican hablantes. Licencia **CC-BY-4.0**, derivados de
  pyannote `speaker-diarization-community-1`. Atribución: Plaquet y Bredin (2023,
  segmentación powerset), Wang et al. (2023, WeSpeaker), Landini et al. (2022, VBx).

## Handy (inspiración del dictado)

- El comportamiento del dictado (modos del atajo, cápsula de grabación, pegado
  que restaura el portapapeles y lista de muletillas) se inspira en
  [Handy](https://github.com/cjpais/Handy), de CJ Pais, licencia **MIT**. No se
  incluye código de Handy; la implementación en Swift es propia.
