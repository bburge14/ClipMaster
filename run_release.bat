@echo off
:: ============================================================
::  ClipMaster Pro — Launch (Release Build)
::  Double-click this to run the built application.
:: ============================================================

title ClipMaster Pro
set "ROOT=%~dp0"
cd /d "%ROOT%"

set "BUILD_DIR=%ROOT%clipmaster_app\build\windows\x64\runner\Release"

if not exist "%BUILD_DIR%\clipmaster_app.exe" (
    echo.
    echo  Release build not found. Please run setup.bat first.
    echo.
    pause
    exit /b 1
)

:: Activate the Python venv for the sidecar.
if exist "%ROOT%.venv\Scripts\activate.bat" (
    call "%ROOT%.venv\Scripts\activate.bat"
)

:: Start the sidecar.
start /b "ClipMaster Sidecar" "%ROOT%.venv\Scripts\python.exe" -m clipmaster_sidecar --port 9120

timeout /t 2 /nobreak >nul

:: Launch the release build.
echo Starting ClipMaster Pro (Release)...
start "" "%BUILD_DIR%\clipmaster_app.exe"
