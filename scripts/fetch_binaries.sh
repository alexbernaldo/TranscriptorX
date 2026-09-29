#!/usr/bin/env bash
set -euo pipefail

REPO="alexbernaldo/TranscriptorX"
TAG="v2.0"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$ROOT/TranscriptorNative/AudioEngine/lib"

command -v gh >/dev/null 2>&1 || {
  echo "ERROR: se requiere GitHub CLI (gh). Instala con: brew install gh" >&2
  exit 1
}

mkdir -p "$DEST"

echo "Descargando demucs-bundled y deep-filter desde $REPO ($TAG)..."
gh release download "$TAG" --repo "$REPO" \
  --pattern "demucs-bundled" --pattern "deep-filter" \
  --dir "$DEST" --clobber

chmod +x "$DEST/demucs-bundled" "$DEST/deep-filter"

echo "Listo. Binarios en $DEST:"
ls -lh "$DEST/demucs-bundled" "$DEST/deep-filter"
