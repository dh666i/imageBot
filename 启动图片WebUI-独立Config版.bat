@echo off
setlocal
title Image WebUI Launcher

cd /d "%~dp0"

set "CONFIG_FILE=%~dp0config.ini"
set "SCRIPT_FILE=%~dp0openai_images_webui_no_python_config.ps1"
set "POWERSHELL_EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"

if not exist "%POWERSHELL_EXE%" (
    set "POWERSHELL_EXE=powershell.exe"
)

if not exist "%SCRIPT_FILE%" (
    echo [ERROR] Missing openai_images_webui_no_python_config.ps1 in current folder.
    echo Please keep the BAT, PS1 and config.ini files in the same folder.
    echo.
    pause
    exit /b 1
)

if not exist "%CONFIG_FILE%" (
    if exist "%~dp0config.example.ini" (
        copy "%~dp0config.example.ini" "%CONFIG_FILE%" >nul
        echo Created config.ini from config.example.ini.
        echo Please edit config.ini and fill OPENAI_API_KEY before real generation.
        echo.
    ) else (
        echo [ERROR] Missing config.ini in current folder.
        echo Please keep config.ini and this BAT file in the same folder.
        echo.
        pause
        exit /b 1
    )
)

echo Starting Image WebUI...
echo Config: "%CONFIG_FILE%"
echo.
echo Close this window to stop the service.
echo If startup fails, the error will stay visible here.
echo.

"%POWERSHELL_EXE%" -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_FILE%" -ConfigPath "%CONFIG_FILE%"

echo.
echo Program exited.
pause
