@echo off
:: ============================================================
::  ClipMaster Pro — Launch (Debug Mode with Hot Reload)
::  Double-click this to run the app during development.
:: ============================================================

title ClipMaster Pro
set "ROOT=%~dp0"
cd /d "%ROOT%"

:: Activate the Python venv so the sidecar can find its deps.
if exist "%ROOT%.venv\Scripts\activate.bat" (
    call "%ROOT%.venv\Scripts\activate.bat"
)

:: Check that setup was run.
if not exist "%ROOT%.venv" (
    echo.
    echo  ClipMaster Pro hasn't been set up yet.
    echo  Please run setup.bat first.
    echo.
    pause
    exit /b 1
)

:: Start the Python sidecar in the background.
echo Starting Python sidecar...
start /b "ClipMaster Sidecar" "%ROOT%.venv\Scripts\python.exe" -m clipmaster_sidecar --port 9120

:: Give the sidecar a moment to bind.
timeout /t 2 /nobreak >nul

:: Launch Flutter app in debug mode.
echo Starting ClipMaster Pro...
cd /d "%ROOT%clipmaster_app"
flutter run -d windows

:: When Flutter exits, kill the sidecar.
taskkill /f /fi "WINDOWTITLE eq ClipMaster Sidecar" >nul 2>&1
