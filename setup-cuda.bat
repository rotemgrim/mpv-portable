@echo off
REM Wrapper that runs setup-cuda.ps1 with execution policy bypass.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0bin\setup-cuda.ps1"
pause
