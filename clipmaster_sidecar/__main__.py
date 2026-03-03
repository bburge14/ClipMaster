"""Entry point for the ClipMaster Python sidecar.

Usage:
    python -m clipmaster_sidecar --port 9120
"""

import argparse
import logging
import os
import sys

import uvicorn

from .server import create_app

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
logger = logging.getLogger("clipmaster_sidecar")


def _setup_bundled_binaries_path() -> None:
    """Add bundled_binaries/ to the system PATH so shutil.which() can find
    yt-dlp.exe, ffmpeg.exe, etc. that are shipped alongside the installed app.

    Layout in the installed .exe:
        <install_dir>/
            clipmaster_sidecar/   <-- we are here
            bundled_binaries/     <-- yt-dlp.exe, ffmpeg.exe
            python_runtime/
            clipmaster_app.exe
    """
    sidecar_dir = os.path.dirname(os.path.abspath(__file__))
    bundled = os.path.join(sidecar_dir, "..", "bundled_binaries")
    if os.path.isdir(bundled):
        bundled = os.path.realpath(bundled)
        logger.info("Adding bundled binaries to PATH: %s", bundled)
        os.environ["PATH"] = bundled + os.pathsep + os.environ.get("PATH", "")


def main() -> None:
    _setup_bundled_binaries_path()

    parser = argparse.ArgumentParser(description="ClipMaster Sidecar")
    parser.add_argument("--port", type=int, default=9120, help="WebSocket port")
    parser.add_argument("--host", type=str, default="127.0.0.1")
    args = parser.parse_args()

    app = create_app()
    logger.info("Starting sidecar on %s:%d", args.host, args.port)
    uvicorn.run(app, host=args.host, port=args.port, log_level="info")


if __name__ == "__main__":
    main()
