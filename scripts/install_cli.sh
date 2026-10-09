#!/bin/bash
set -euo pipefail
BIN="$(ls -d ~/Library/Developer/Xcode/DerivedData/TranscriptorNative-*/Build/Products/Debug/tx | head -1)"
if [ -z "$BIN" ]; then echo "Build the 'tx' scheme in Xcode first."; exit 1; fi
mkdir -p "$HOME/.local/bin"
ln -sf "$BIN" "$HOME/.local/bin/tx"
echo "Installed: $(command -v tx)"
