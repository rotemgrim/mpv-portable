@echo off
rem ============================================================
rem  Remove the mpv:// URL protocol registration for current user.
rem ============================================================
setlocal

echo Unregistering mpv:// protocol from HKCU...
reg delete "HKCU\Software\Classes\mpv" /f >nul 2>&1

if errorlevel 1 (
    echo Nothing to remove (key was not present^) or deletion failed.
) else (
    echo Done.
)
echo.
pause
endlocal
