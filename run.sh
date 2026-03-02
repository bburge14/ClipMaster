#!/usr/bin/env bash
set -e

# ============================================================
#  ClipMaster Pro — Launch (Debug Mode)
# ============================================================

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

if [ ! -d "$ROOT/.venv" ]; then
    echo "  ClipMaster Pro hasn't been set up yet."
    echo "  Please run ./setup.sh first."
    exit 1
fi

# Activate venv.
source "$ROOT/.venv/bin/activate"

# Start the Python sidecar in the background.
echo "Starting Python sidecar..."
python -m clipmaster_sidecar --port 9120 &
SIDECAR_PID=$!

# Cleanup: kill sidecar when this script exits.
trap "kill $SIDECAR_PID 2>/dev/null; exit" EXIT INT TERM

sleep 2

# Launch Flutter app.
echo "Starting ClipMaster Pro..."
cd "$ROOT/clipmaster_app"

if [[ "$OSTYPE" == "darwin"* ]]; then
    flutter run -d macos
else
    flutter run -d linux
fi
