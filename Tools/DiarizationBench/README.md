# Diarization bench

Offline comparison of speaker diarization engines on the same audio, scored against
a reference, before changing anything in the app. Nothing here is linked into the app.

## Pieces

| Path | What it does |
|---|---|
| `Sources/DiarizationBench` | FluidAudio 0.17.7 offline diarizer (the app's engine), `default` (app settings) or `precise` (stepRatio 0.1, no minimum embedding segment). Writes raw turns as TSV, plus time and peak memory. |
| `speakrs-bench/` | speakrs (Rust, native Core ML), modes `coreml` (1 s step) and `coreml-fast` (2 s step). Same TSV output. |
| `score.py` | DER / JER / purity / coverage of each TSV against a Zoom `transcript.vtt` (pyannote.metrics, 0.5 s collar, overlap excluded), and how each real person is split across labels. |
| `assign_eval.py` | Ports `SpeakerAssignment.assign` and measures the share of transcript words that end up with the right speaker. |
| `work/` | Inputs and outputs (git-ignored). |

## Run

```sh
# 16 kHz mono WAV, same ffmpeg arguments as AudioPreprocessor (no trimming)
ffmpeg -i recording.mp4 -ar 16000 -ac 1 -c:a pcm_s16le work/meeting16k.wav

swift build -c release
M="$HOME/Library/Application Support/Transcriptor/diarization"
.build/release/DiarizationBench work/meeting16k.wav "$M" default work/fluid_default.tsv
.build/release/DiarizationBench work/meeting16k.wav "$M" precise work/fluid_precise.tsv

(cd speakrs-bench && cargo build --release)
speakrs-bench/target/release/speakrs-bench work/meeting16k.wav coreml work/speakrs_coreml.tsv

uv run --with pyannote.metrics python score.py transcript.vtt work/*.tsv

# whisper-cli as the app runs it, keeping stderr for the VAD map
whisper-cli -m ggml-base.bin -f work/meeting16k.wav -ojf -of work/full_vad --vad ... 2> work/full_vad.stderr
python3 assign_eval.py transcript.vtt work/full_vad.json - work/fluid_default.tsv work/full_vad.stderr   # before the fix
python3 assign_eval.py transcript.vtt work/full_vad.json work/full_vad.stderr work/fluid_default.tsv     # after the fix
```

In the app, `defaults write io.github.alexbernaldo.transcriptorx diagnostics.speakerTurns -bool YES`
writes the raw turns of every transcription with speakers to
`~/Library/Application Support/Transcriptor/diagnostics/`.

## Results, 11 Oct 2026

Recording: Zoom meeting `GMT20261009-080016` (92 min 39 s, 8 people, 87.5 min of speech).
Reference: Zoom's own `transcript.vtt`, where each cue carries the participant whose
audio channel produced it. Its boundaries are coarse, so most of the "miss" below is
pause time inside Zoom cues; confusion is the number that measures separation.
Apple M4 Pro, 24 GB.

| Engine | Speakers | DER | Confusion | JER | Process | Peak RSS |
|---|---:|---:|---:|---:|---:|---:|
| FluidAudio default (app) | 8 | 2.1% | 0.1% | 2.6% | 18.3 s | 1.0 GB |
| FluidAudio precise | 8 | 1.8% | 0.1% | 2.3% | 33.5 s | 1.2 GB |
| speakrs coreml | 8 | 2.1% | 0.1% | 2.8% | 14.6 s (+77 s first load) | 3.2 GB |
| speakrs coreml-fast | 8 | 1.2% | 0.1% | 1.8% | 7.5 s (+50 s load) | 3.0 GB |

Every engine finds the 8 people and keeps each one on a single label (99-100%).

Words with the right speaker after assignment to the whisper transcript (13,524 words):

| Turns | App before fix | After fix |
|---|---:|---:|
| FluidAudio default | 47.3% | 99.8% |
| FluidAudio precise | 47.3% | 99.9% |
| speakrs coreml | 47.2% | 99.8% |
| speakrs coreml-fast | 47.1% | 99.8% |

The cause was not the detector: with `--vad`, whisper.cpp maps segment times back
to the original audio but leaves token times on the timeline with the silences cut
out, so word timestamps drifted up to minutes early and `SpeakerAssignment` looked
up the wrong turns. `WhisperVADTimeMap` (TranscriptionService.swift) rebuilds
whisper's own map from the `vad_segment_info` lines it logs.

Recommendation: keep FluidAudio with the current settings. `precise` and speakrs do
not change the outcome on this recording; speakrs uses about 3x the memory and has
a long first load.
