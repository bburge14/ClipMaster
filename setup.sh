#!/usr/bin/env bash
set -e

# ============================================================
#  ClipMaster Pro — One-Time Setup (Linux / macOS)
#  Run: chmod +x setup.sh && ./setup.sh
# ============================================================

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

echo ""
echo "  ======================================"
echo "   ClipMaster Pro — First-Time Setup"
echo "  ======================================"
echo ""

# -------------------------------------------------
# 1. Check for Python
# -------------------------------------------------
echo "[1/5] Checking for Python..."

if ! command -v python3 &> /dev/null; then
    echo "  ERROR: python3 is not installed."
    echo "  Install Python 3.10+ from https://www.python.org/downloads/"
    exit 1
fi

PYVER=$(python3 --version 2>&1)
echo "  Found $PYVER"

# -------------------------------------------------
# 2. Check for Flutter
# -------------------------------------------------
echo "[2/5] Checking for Flutter..."

if ! command -v flutter &> /dev/null; then
    echo "  ERROR: Flutter is not installed or not on your PATH."
    echo "  Install Flutter from https://docs.flutter.dev/get-started/install"
    exit 1
fi

FLVER=$(flutter --version 2>&1 | head -n1)
echo "  Found $FLVER"

# -------------------------------------------------
# 3. Set up Python virtual environment
# -------------------------------------------------
echo "[3/5] Setting up Python environment..."

if [ ! -d "$ROOT/.venv" ]; then
    echo "  Creating virtual environment..."
    python3 -m venv "$ROOT/.venv"
fi

source "$ROOT/.venv/bin/activate"
echo "  Installing Python dependencies..."
pip install --quiet --upgrade pip
pip install --quiet -r "$ROOT/clipmaster_sidecar/requirements.txt"
echo "  Python environment ready."

# -------------------------------------------------
# 4. Check for ffmpeg and yt-dlp
# -------------------------------------------------
echo "[4/5] Checking for ffmpeg and yt-dlp..."

mkdir -p "$ROOT/bundled_binaries"

if ! command -v ffmpeg &> /dev/null && [ ! -f "$ROOT/bundled_binaries/ffmpeg" ]; then
    echo "  WARNING: ffmpeg not found."
    echo "  Install via your package manager:"
    echo "    macOS:  brew install ffmpeg"
    echo "    Linux:  sudo apt install ffmpeg"
else
    echo "  ffmpeg found."
fi

if ! command -v yt-dlp &> /dev/null && [ ! -f "$ROOT/bundled_binaries/yt-dlp" ]; then
    echo "  Downloading yt-dlp..."
    curl -L -o "$ROOT/bundled_binaries/yt-dlp" "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp" 2>/dev/null || true
    chmod +x "$ROOT/bundled_binaries/yt-dlp" 2>/dev/null || true

    if [ -f "$ROOT/bundled_binaries/yt-dlp" ]; then
        echo "  yt-dlp downloaded."
    else
        echo "  WARNING: Could not download yt-dlp. Install manually: pip install yt-dlp"
    fi
else
    echo "  yt-dlp found."
fi

# -------------------------------------------------
# 5. Set up Flutter app
# -------------------------------------------------
echo "[5/5] Setting up Flutter app..."

cd "$ROOT/clipmaster_app"

# Detect platform for flutter create.
if [[ "$OSTYPE" == "darwin"* ]]; then
    PLATFORM="macos"
else
    PLATFORM="linux"
fi

if [ ! -f "$ROOT/clipmaster_app/${PLATFORM}/CMakeLists.txt" ] && [ ! -d "$ROOT/clipmaster_app/${PLATFORM}" ]; then
    echo "  Generating desktop scaffolding..."
    flutter create . --platforms="$PLATFORM" --project-name clipmaster_app --org com.clipmaster > /dev/null 2>&1 || true
fi

echo "  Fetching Flutter dependencies..."
flutter pub get

cd "$ROOT"

echo ""
echo "  ======================================"
echo "   Setup Complete!"
echo "  ======================================"
echo ""
echo "  To run ClipMaster Pro:"
echo "    ./run.sh"
echo ""
