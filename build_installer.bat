@echo off
setlocal EnableDelayedExpansion

:: ============================================================
::  ClipMaster Pro — Build Standalone Installer
::
::  This script creates a fully self-contained distribution:
::    - Flutter release build
::    - Embedded Python (no system Python needed)
::    - FFmpeg + yt-dlp binaries
::    - Python sidecar + all dependencies
::
::  Output: dist\ClipMasterPro\  (ready for Inno Setup)
::
::  Prerequisites (dev machine only):
::    - Flutter SDK
::    - Python 3.12+
::    - Internet connection (to download embedded Python)
:: ============================================================

title ClipMaster Pro — Build Installer
color 0E

set "ROOT=%~dp0"
cd /d "%ROOT%"

set "DIST=%ROOT%dist\ClipMasterPro"
set "PYTHON_VERSION=3.12.8"
set "PYTHON_EMBED_URL=https://www.python.org/ftp/python/%PYTHON_VERSION%/python-%PYTHON_VERSION%-embed-amd64.zip"

echo.
echo  ==========================================
echo   ClipMaster Pro — Building Installer
echo  ==========================================
echo.

:: -------------------------------------------------
:: Clean previous build
:: -------------------------------------------------
if exist "%ROOT%dist" (
    echo Cleaning previous build...
    rmdir /s /q "%ROOT%dist"
)
mkdir "%DIST%"

:: -------------------------------------------------
:: 1. Build Flutter release
:: -------------------------------------------------
echo [1/5] Building Flutter app (release)...

cd /d "%ROOT%clipmaster_app"

:: Generate scaffolding if needed.
if not exist "%ROOT%clipmaster_app\windows\runner\main.cpp" (
    flutter create . --platforms=windows --project-name clipmaster_app --org com.clipmaster >nul 2>&1
)

flutter pub get
flutter build windows --release

if %ERRORLEVEL% NEQ 0 (
    echo  ERROR: Flutter build failed.
    pause
    exit /b 1
)

:: Copy the entire Flutter build output to dist.
set "BUILD_OUT=%ROOT%clipmaster_app\build\windows\x64\runner\Release"
xcopy /s /e /i /y "%BUILD_OUT%\*" "%DIST%" >nul
echo   Flutter build copied to dist.

cd /d "%ROOT%"

:: -------------------------------------------------
:: 2. Download and set up embedded Python
:: -------------------------------------------------
echo [2/5] Setting up embedded Python runtime...

set "PY_RUNTIME=%DIST%\python_runtime"
mkdir "%PY_RUNTIME%"

:: Download the embeddable Python zip.
if not exist "%ROOT%dist\python-embed.zip" (
    echo   Downloading Python %PYTHON_VERSION% embeddable...
    curl -L -o "%ROOT%dist\python-embed.zip" "%PYTHON_EMBED_URL%"
    if !ERRORLEVEL! NEQ 0 (
        echo  ERROR: Failed to download Python embeddable.
        pause
        exit /b 1
    )
)

:: Extract it.
echo   Extracting Python runtime...
powershell -NoProfile -Command "Expand-Archive -Path '%ROOT%dist\python-embed.zip' -DestinationPath '%PY_RUNTIME%' -Force"

:: Enable pip in the embedded Python by uncommenting "import site" in python312._pth
:: The ._pth file restricts imports; we need to open it up for pip and packages.
for %%f in ("%PY_RUNTIME%\python*.zip") do set "PY_STDLIB_ZIP=%%~nxf"
set "PTH_FILE=%PY_RUNTIME%\python312._pth"

:: Find the actual ._pth file (version may vary).
for %%f in ("%PY_RUNTIME%\python*._pth") do set "PTH_FILE=%%f"

echo   Enabling pip in embedded Python...
powershell -NoProfile -Command "(Get-Content '%PTH_FILE%') -replace '#import site', 'import site' | Set-Content '%PTH_FILE%'"

:: Add Lib\site-packages to the path file.
echo Lib\site-packages>> "%PTH_FILE%"

:: Download and install pip.
echo   Installing pip into embedded Python...
curl -L -o "%PY_RUNTIME%\get-pip.py" "https://bootstrap.pypa.io/get-pip.py" 2>nul
"%PY_RUNTIME%\python.exe" "%PY_RUNTIME%\get-pip.py" --no-warn-script-location >nul 2>&1
del "%PY_RUNTIME%\get-pip.py"

:: Install sidecar dependencies into the embedded Python.
echo   Installing sidecar dependencies...
"%PY_RUNTIME%\python.exe" -m pip install --quiet --no-warn-script-location -r "%ROOT%clipmaster_sidecar\requirements.txt"

echo   Embedded Python ready.

:: -------------------------------------------------
:: 3. Copy the Python sidecar
:: -------------------------------------------------
echo [3/5] Copying Python sidecar...

xcopy /s /e /i /y "%ROOT%clipmaster_sidecar" "%DIST%\clipmaster_sidecar" >nul
:: Remove test files and __pycache__ from distribution.
if exist "%DIST%\clipmaster_sidecar\tests" rmdir /s /q "%DIST%\clipmaster_sidecar\tests"
for /d /r "%DIST%\clipmaster_sidecar" %%d in (__pycache__) do if exist "%%d" rmdir /s /q "%%d"

echo   Sidecar copied.

:: -------------------------------------------------
:: 4. Bundle ffmpeg and yt-dlp
:: -------------------------------------------------
echo [4/5] Bundling binaries...

if not exist "%DIST%\bundled_binaries" mkdir "%DIST%\bundled_binaries"

:: yt-dlp
if exist "%ROOT%bundled_binaries\yt-dlp.exe" (
    copy /y "%ROOT%bundled_binaries\yt-dlp.exe" "%DIST%\bundled_binaries\" >nul
    echo   yt-dlp bundled.
) else (
    echo   Downloading yt-dlp...
    curl -L -o "%DIST%\bundled_binaries\yt-dlp.exe" "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe" 2>nul
)

:: ffmpeg
if exist "%ROOT%bundled_binaries\ffmpeg.exe" (
    copy /y "%ROOT%bundled_binaries\ffmpeg.exe" "%DIST%\bundled_binaries\" >nul
    if exist "%ROOT%bundled_binaries\ffprobe.exe" copy /y "%ROOT%bundled_binaries\ffprobe.exe" "%DIST%\bundled_binaries\" >nul
    echo   ffmpeg bundled.
) else (
    echo   Downloading ffmpeg...
    curl -L -o "%ROOT%dist\ffmpeg-release.zip" "https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip" 2>nul
    powershell -NoProfile -Command "try { Expand-Archive -Path '%ROOT%dist\ffmpeg-release.zip' -DestinationPath '%ROOT%dist\ffmpeg-temp' -Force; $ff = Get-ChildItem -Path '%ROOT%dist\ffmpeg-temp' -Recurse -Filter 'ffmpeg.exe' | Select-Object -First 1; $fp = Get-ChildItem -Path '%ROOT%dist\ffmpeg-temp' -Recurse -Filter 'ffprobe.exe' | Select-Object -First 1; if ($ff) { Copy-Item $ff.FullName '%DIST%\bundled_binaries\ffmpeg.exe' }; if ($fp) { Copy-Item $fp.FullName '%DIST%\bundled_binaries\ffprobe.exe' }; Remove-Item '%ROOT%dist\ffmpeg-temp' -Recurse -Force; Remove-Item '%ROOT%dist\ffmpeg-release.zip' -Force } catch { Write-Host $_.Exception.Message }"
    echo   ffmpeg bundled.
)

:: -------------------------------------------------
:: 5. Create launcher
:: -------------------------------------------------
echo [5/5] Creating launcher...

:: The launcher starts the sidecar with the embedded Python, then launches the app.
(
echo @echo off
echo setlocal
echo set "APP_DIR=%%~dp0"
echo.
echo :: Start the Python sidecar using the embedded Python runtime.
echo start /b "" "%%APP_DIR%%python_runtime\python.exe" -m clipmaster_sidecar --port 9120
echo.
echo :: Wait for sidecar to initialize.
echo timeout /t 2 /nobreak ^>nul
echo.
echo :: Launch the Flutter app.
echo start "" "%%APP_DIR%%clipmaster_app.exe"
) > "%DIST%\ClipMaster Pro.bat"

:: Also create a VBS wrapper so it launches without a console window.
(
echo Set WshShell = CreateObject("WScript.Shell"^)
echo WshShell.Run """" ^& Replace(WScript.ScriptFullName, WScript.ScriptName, ""^) ^& "python_runtime\python.exe"" -m clipmaster_sidecar --port 9120", 0, False
echo WScript.Sleep 2000
echo WshShell.Run """" ^& Replace(WScript.ScriptFullName, WScript.ScriptName, ""^) ^& "clipmaster_app.exe""", 1, False
) > "%DIST%\ClipMaster Pro.vbs"

echo.
echo  ==========================================
echo   Build Complete!
echo  ==========================================
echo.
echo  Distribution folder: %DIST%
echo.
echo  Contents:
dir /b "%DIST%"
echo.
echo  Next steps:
echo    1. Test: double-click "%DIST%\ClipMaster Pro.vbs"
echo    2. Build installer: run Inno Setup on installer\clipmaster.iss
echo.
pause
