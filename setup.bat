@echo off
setlocal EnableDelayedExpansion

:: ============================================================
::  ClipMaster Pro — One-Time Setup
::  Double-click this file to install everything automatically.
:: ============================================================

title ClipMaster Pro Setup
color 0B

echo.
echo  ======================================
echo   ClipMaster Pro — First-Time Setup
echo  ======================================
echo.

:: Track where we are.
set "ROOT=%~dp0"
cd /d "%ROOT%"

:: -------------------------------------------------
:: 1. Check for Python
:: -------------------------------------------------
echo [1/6] Checking for Python...

where python >nul 2>&1
if %ERRORLEVEL% NEQ 0 (
    echo.
    echo  ERROR: Python is not installed or not on your PATH.
    echo.
    echo  Install Python 3.10+ from https://www.python.org/downloads/
    echo  IMPORTANT: Check "Add Python to PATH" during installation.
    echo.
    pause
    exit /b 1
)

for /f "tokens=2 delims= " %%v in ('python --version 2^>^&1') do set PYVER=%%v
echo   Found Python %PYVER%

:: -------------------------------------------------
:: 2. Check for Flutter
:: -------------------------------------------------
echo [2/6] Checking for Flutter...

where flutter >nul 2>&1
if %ERRORLEVEL% NEQ 0 (
    echo.
    echo  ERROR: Flutter is not installed or not on your PATH.
    echo.
    echo  Install Flutter from https://docs.flutter.dev/get-started/install/windows/desktop
    echo  Then run: flutter config --enable-windows-desktop
    echo.
    pause
    exit /b 1
)

for /f "tokens=2 delims= " %%v in ('flutter --version 2^>^&1 ^| findstr "Flutter"') do set FLVER=%%v
echo   Found Flutter %FLVER%

:: -------------------------------------------------
:: 3. Set up Python virtual environment + dependencies
:: -------------------------------------------------
echo [3/6] Setting up Python environment...

if not exist "%ROOT%.venv" (
    echo   Creating virtual environment...
    python -m venv "%ROOT%.venv"
)

echo   Installing Python dependencies...
call "%ROOT%.venv\Scripts\activate.bat"
pip install --quiet --upgrade pip
pip install --quiet -r "%ROOT%clipmaster_sidecar\requirements.txt"

if %ERRORLEVEL% NEQ 0 (
    echo.
    echo  ERROR: Python dependency installation failed.
    echo  Check the output above for details.
    pause
    exit /b 1
)
echo   Python environment ready.

:: -------------------------------------------------
:: 4. Download ffmpeg and yt-dlp if missing
:: -------------------------------------------------
echo [4/6] Checking bundled binaries...

if not exist "%ROOT%bundled_binaries" mkdir "%ROOT%bundled_binaries"

if not exist "%ROOT%bundled_binaries\yt-dlp.exe" (
    echo   Downloading yt-dlp...
    curl -L -o "%ROOT%bundled_binaries\yt-dlp.exe" "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe" 2>nul
    if !ERRORLEVEL! NEQ 0 (
        echo   WARNING: Could not download yt-dlp. You can place yt-dlp.exe in bundled_binaries\ manually.
    ) else (
        echo   yt-dlp downloaded.
    )
) else (
    echo   yt-dlp already present.
)

if not exist "%ROOT%bundled_binaries\ffmpeg.exe" (
    echo   Downloading ffmpeg...
    echo.
    echo   NOTE: ffmpeg is large (~140MB). Downloading a release build...
    curl -L -o "%ROOT%bundled_binaries\ffmpeg-release.zip" "https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip" 2>nul
    if !ERRORLEVEL! NEQ 0 (
        echo   WARNING: Could not download ffmpeg automatically.
        echo   Please download ffmpeg.exe and place it in bundled_binaries\
        echo   Get it from: https://www.gyan.dev/ffmpeg/builds/
    ) else (
        echo   Extracting ffmpeg...
        powershell -NoProfile -Command "try { $zip = '%ROOT%bundled_binaries\ffmpeg-release.zip'; $dest = '%ROOT%bundled_binaries\ffmpeg-temp'; Expand-Archive -Path $zip -DestinationPath $dest -Force; $ffmpeg = Get-ChildItem -Path $dest -Recurse -Filter 'ffmpeg.exe' | Select-Object -First 1; $ffprobe = Get-ChildItem -Path $dest -Recurse -Filter 'ffprobe.exe' | Select-Object -First 1; if ($ffmpeg) { Copy-Item $ffmpeg.FullName '%ROOT%bundled_binaries\ffmpeg.exe' }; if ($ffprobe) { Copy-Item $ffprobe.FullName '%ROOT%bundled_binaries\ffprobe.exe' }; Remove-Item $dest -Recurse -Force; Remove-Item $zip -Force; Write-Host 'ffmpeg extracted.' } catch { Write-Host 'Extraction failed:' $_.Exception.Message }"
    )
) else (
    echo   ffmpeg already present.
)

:: -------------------------------------------------
:: 5. Set up Flutter app
:: -------------------------------------------------
echo [5/6] Setting up Flutter app...

cd /d "%ROOT%clipmaster_app"

:: Generate the Windows runner scaffolding if it's missing.
if not exist "%ROOT%clipmaster_app\windows\runner\main.cpp" (
    echo   Generating Windows desktop scaffolding...
    flutter create . --platforms=windows --project-name clipmaster_app --org com.clipmaster >nul 2>&1
)

echo   Fetching Flutter dependencies...
flutter pub get

if %ERRORLEVEL% NEQ 0 (
    echo.
    echo  ERROR: Flutter dependency fetch failed.
    echo  Check the output above for details.
    pause
    exit /b 1
)

:: -------------------------------------------------
:: 6. Build the app
:: -------------------------------------------------
echo [6/6] Building ClipMaster Pro...

flutter build windows --release

if %ERRORLEVEL% NEQ 0 (
    echo.
    echo  WARNING: Release build failed. You can still run in debug mode.
    echo  Use run.bat to launch in debug mode instead.
) else (
    :: Copy bundled binaries into the release build output.
    set "BUILD_DIR=%ROOT%clipmaster_app\build\windows\x64\runner\Release"
    if not exist "!BUILD_DIR!\bundled_binaries" mkdir "!BUILD_DIR!\bundled_binaries"
    if exist "%ROOT%bundled_binaries\ffmpeg.exe" copy /y "%ROOT%bundled_binaries\ffmpeg.exe" "!BUILD_DIR!\bundled_binaries\" >nul
    if exist "%ROOT%bundled_binaries\ffprobe.exe" copy /y "%ROOT%bundled_binaries\ffprobe.exe" "!BUILD_DIR!\bundled_binaries\" >nul
    if exist "%ROOT%bundled_binaries\yt-dlp.exe" copy /y "%ROOT%bundled_binaries\yt-dlp.exe" "!BUILD_DIR!\bundled_binaries\" >nul

    :: Copy the sidecar into the build output.
    xcopy /s /e /i /y "%ROOT%clipmaster_sidecar" "!BUILD_DIR!\clipmaster_sidecar" >nul

    echo.
    echo  Build complete!
    echo  Executable: !BUILD_DIR!\clipmaster_app.exe
)

cd /d "%ROOT%"

:: -------------------------------------------------
:: Done
:: -------------------------------------------------
echo.
echo  ======================================
echo   Setup Complete!
echo  ======================================
echo.
echo  To run ClipMaster Pro:
echo    - Double-click  run.bat      (debug mode, hot-reload)
echo    - Double-click  run_release.bat  (release build)
echo.
pause
