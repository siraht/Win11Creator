@echo off
setlocal
cd /d "%~dp0"

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\Start-WinUtilLeanDawBuild.ps1"
if errorlevel 1 (
    echo.
    echo The Lean DAW ISO build did not complete. Review the error window for details.
    pause
)

