#!/bin/bash
# Installs Jarvis's optional voice pack into a runtime folder: a Python environment with
# the Kokoro natural voice and the "Hey Jarvis" wake-word detector, plus their weights.
#
# Run by Setup inside Jarvis.app, or by hand:
#     scripts/provision-voice.sh "$HOME/Library/Application Support/JarvisLocal/runtime"
#
# Output protocol for the app: "STEP <text>" starts a step, "ERROR <text>" explains a
# failure, "DONE" ends a successful run. Everything else is detail.
set -euo pipefail
RUNTIME="${1:?usage: provision-voice.sh <runtime folder>}"
mkdir -p "$RUNTIME/models/wakeword" "$RUNTIME/huggingface"

UV=""
for candidate in "$HOME/.local/bin/uv" /opt/homebrew/bin/uv /usr/local/bin/uv "$HOME/.cargo/bin/uv"; do
    if [ -x "$candidate" ]; then UV="$candidate"; break; fi
done
if [ -z "$UV" ]; then
    echo "ERROR The voice pack needs uv to build its Python environment. Install it with 'brew install uv', then try again."
    exit 2
fi

echo "STEP Creating the voice environment"
# uv fetches a standalone Python 3.11 if none is installed; the system's 3.9 is too old.
"$UV" venv --allow-existing --python 3.11 "$RUNTIME/venv"
PY="$RUNTIME/venv/bin/python"

echo "STEP Installing speech packages (about 2 GB)"
# Versions match the environment the latency and accuracy numbers were measured with.
"$UV" pip install --python "$PY" \
    "mlx-audio==0.4.1" "misaki[en]==0.9.4" "soundfile==0.13.1" "numpy==2.4.6" \
    "openwakeword==0.6.0" "onnxruntime==1.30.0" \
    "en_core_web_sm @ https://github.com/explosion/spacy-models/releases/download/en_core_web_sm-3.8.0/en_core_web_sm-3.8.0-py3-none-any.whl"

echo "STEP Downloading the Kokoro voice"
HF_HOME="$RUNTIME/huggingface" "$PY" -c "from huggingface_hub import snapshot_download; snapshot_download('mlx-community/Kokoro-82M-bf16')"

echo "STEP Downloading the wake-word model"
"$PY" - "$RUNTIME/models/wakeword" <<'PY'
import sys
from openwakeword import utils
utils.download_models(model_names=["hey_jarvis"], target_directory=sys.argv[1])
PY
rm -f "$RUNTIME/models/wakeword/"*.tflite

echo "DONE"
