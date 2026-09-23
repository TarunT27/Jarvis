#!/bin/bash
# Builds a standalone Jarvis.app and installs it, so Jarvis no longer depends on this
# checkout. The installed app keeps its runtime under Application Support:
#
#     ~/Library/Application Support/JarvisLocal/runtime
#
# If this checkout already has a provisioned .runtime, it is copied there as APFS clones
# (instant, and no extra disk space until a file changes). Anything missing is offered
# by the app's Setup page on first launch. Model weights stay in ~/.ollama, shared with
# the Ollama app, and are never copied.
#
#     ./scripts/install.sh                       # installs into /Applications
#     JARVIS_INSTALL_DIR=~/Applications ./scripts/install.sh
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${JARVIS_INSTALL_DIR:-/Applications}"
if [ ! -w "$DEST" ]; then DEST="$HOME/Applications"; mkdir -p "$DEST"; fi
STAGE="$PROJECT_DIR/.build/standalone/Jarvis.app"
RUNTIME="$HOME/Library/Application Support/JarvisLocal/runtime"

printf '==> Building a standalone Jarvis.app\n'
rm -rf "$STAGE"
JARVIS_STANDALONE=1 JARVIS_APP_OUT="$STAGE" "$PROJECT_DIR/scripts/build.sh"

if pgrep -f "Jarvis.app/Contents/MacOS/Jarvis" >/dev/null 2>&1; then
    printf '==> Quitting the running Jarvis\n'
    osascript -e 'quit app id "local.jarvis.mac"' >/dev/null 2>&1 || true
    for _ in $(seq 1 20); do pgrep -f "Jarvis.app/Contents/MacOS/Jarvis" >/dev/null 2>&1 || break; sleep 0.3; done
fi

printf '==> Installing into %s\n' "$DEST"
rm -rf "$DEST/Jarvis.app"
ditto "$STAGE" "$DEST/Jarvis.app"

SOURCE="$PROJECT_DIR/.runtime"
if [ -d "$SOURCE" ]; then
    printf '==> Seeding the runtime from this checkout (APFS clones)\n'
    mkdir -p "$RUNTIME"
    items=(venv huggingface models whisper-cli)
    # Jarvis runs the Ollama app's engine when it is installed; otherwise bring the private copy.
    [ -x /Applications/Ollama.app/Contents/Resources/ollama ] || items+=(ollama)
    for item in "${items[@]}"; do
        if [ -e "$SOURCE/$item" ] && [ ! -e "$RUNTIME/$item" ]; then
            cp -Rc "$SOURCE/$item" "$RUNTIME/" && printf '    %s\n' "$item"
        fi
    done
fi

cat <<EOF

Installed $DEST/Jarvis.app
Runtime   $RUNTIME

Open it from $DEST (or Spotlight). Setup in the sidebar shows anything still missing.
The copy at $PROJECT_DIR/Jarvis.app is the development build; open only one of them at a time.
EOF
