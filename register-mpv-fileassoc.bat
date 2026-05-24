@echo off
rem ============================================================
rem  Register mpv as an "Open with" choice for common video / audio
rem  file extensions (current user, no admin required).
rem
rem  This does NOT force mpv to be the *default* app for these
rem  extensions -- Windows 10/11 protects that setting (UserChoice)
rem  with a per-user hash, so it must be set once via the Windows
rem  UI:
rem     Right-click a .mkv -> Open with -> Choose another app
rem     -> mpv -> tick "Always use this app" -> OK
rem  (Repeat once per extension, or use Settings -> Default apps.)
rem ============================================================
setlocal

set "ROOT=%~dp0"
if "%ROOT:~-1%"=="\" set "ROOT=%ROOT:~0,-1%"
set "BIN=%ROOT%\bin"
set "MPV_EXE=%BIN%\mpv.exe"

if not exist "%MPV_EXE%" (
    echo [ERROR] mpv.exe not found at "%MPV_EXE%".
    pause
    exit /b 1
)

set "PROGID=mpv.AssocFile"
set "CLASSES=HKCU\Software\Classes"

echo Registering ProgId "%PROGID%" -^> "%MPV_EXE%"
echo.

rem -- ProgId definition ----------------------------------------
reg add "%CLASSES%\%PROGID%"                    /ve /d "mpv media file"          /f >nul
reg add "%CLASSES%\%PROGID%"                    /v  FriendlyTypeName /d "mpv media file" /f >nul
reg add "%CLASSES%\%PROGID%\DefaultIcon"        /ve /d "\"%MPV_EXE%\",0"          /f >nul
reg add "%CLASSES%\%PROGID%\shell\open"         /v  FriendlyAppName  /d "mpv"     /f >nul
reg add "%CLASSES%\%PROGID%\shell\open\command" /ve /d "\"%MPV_EXE%\" \"%%1\"" /f >nul

rem -- Per-app entry (used by the "Open with" picker) -----------
reg add "%CLASSES%\Applications\mpv.exe"                    /v FriendlyAppName /d "mpv" /f >nul
reg add "%CLASSES%\Applications\mpv.exe\shell\open\command" /ve /d "\"%MPV_EXE%\" \"%%1\"" /f >nul

rem -- Video / audio extensions ---------------------------------
set "EXTS=.mkv .mp4 .avi .mov .webm .m4v .wmv .flv .mpg .mpeg .ts .m2ts .3gp .ogv .vob .mp3 .flac .wav .ogg .opus .m4a .aac .wma"

for %%E in (%EXTS%) do (
    reg add "%CLASSES%\%%E\OpenWithProgids"      /v "%PROGID%" /t REG_NONE /d "" /f >nul
    echo   added %%E
)

echo.
echo Done.
echo.
echo NEXT STEP (manual, one-time per extension):
echo   Right-click a video file -^> Open with -^> Choose another app -^>
echo   pick mpv -^> tick "Always use this app" -^> OK.
echo   Or use Settings -^> Apps -^> Default apps to assign mpv per extension.
echo.
pause
endlocal
