@echo off
rem ============================================================
rem  Register the mpv:// URL protocol for the current user.
rem  No admin required (writes to HKCU only).
rem ============================================================
setlocal

set "ROOT=%~dp0"
if "%ROOT:~-1%"=="\" set "ROOT=%ROOT:~0,-1%"
set "BIN=%ROOT%\bin"

set "MPV_EXE=%BIN%\mpv.exe"
set "HANDLER=%BIN%\mpv-protocol-handler.cmd"

if not exist "%MPV_EXE%" (
    echo [ERROR] mpv.exe not found at "%MPV_EXE%".
    echo         Run this script from the portable mpv folder ^(mpv.exe must be in .\bin\^).
    pause
    exit /b 1
)
if not exist "%HANDLER%" (
    echo [ERROR] mpv-protocol-handler.cmd not found at "%HANDLER%".
    pause
    exit /b 1
)

set "KEY=HKCU\Software\Classes\mpv"

echo Registering mpv:// protocol for current user...
echo   mpv.exe : %MPV_EXE%
echo   handler : %HANDLER%
echo.

reg add "%KEY%"                   /ve /d "URL:mpv Protocol" /f >nul
reg add "%KEY%"                   /v  "URL Protocol" /d "" /f >nul
reg add "%KEY%\DefaultIcon"       /ve /d "\"%MPV_EXE%\",0" /f >nul
reg add "%KEY%\shell"             /f >nul
reg add "%KEY%\shell\open"        /f >nul
reg add "%KEY%\shell\open\command" /ve /d "\"%HANDLER%\" \"%%1\"" /f >nul

if errorlevel 1 (
    echo [ERROR] Registration failed.
    pause
    exit /b 1
)

echo Done. Test with:  start "" "mpv://https://www.w3schools.com/html/mov_bbb.mp4"
echo.
pause
endlocal
