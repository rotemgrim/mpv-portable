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

rem ------------------------------------------------------------
rem  Chrome auto-launch policy: skip the confirmation dialog for
rem  mpv:// links from any origin.
rem  (ExternalProtocolDialogShowAlwaysOpenCheckbox was removed in
rem  Chrome 104, so the per-click checkbox no longer exists. The
rem  modern replacement is AutoLaunchProtocolsFromOrigins.)
rem  Docs: https://chromeenterprise.google/policies/#AutoLaunchProtocolsFromOrigins
rem ------------------------------------------------------------
echo Setting Chrome policy AutoLaunchProtocolsFromOrigins for mpv://...

rem All the cmd <-> reg.exe quote escaping for JSON is unreliable
rem (it strips quotes when re-elevated through Start-Process), so we
rem delegate to a tiny PowerShell snippet that uses the .NET registry
rem APIs directly and self-elevates if needed.
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$code = {" ^
  "  $ErrorActionPreference = 'Continue';" ^
  "  $hives = @('HKCU:\Software\Policies\Google\Chrome', 'HKLM:\Software\Policies\Google\Chrome');" ^
  "  foreach ($base in $hives) {" ^
  "    if (-not (Test-Path $base)) { continue }" ^
  "    Remove-ItemProperty -Path $base -Name 'ExternalProtocolDialogShowAlwaysOpenCheckbox' -ErrorAction SilentlyContinue;" ^
  "  }" ^
  "  $base = 'HKCU:\Software\Policies\Google\Chrome';" ^
  "  $auto = Join-Path $base 'AutoLaunchProtocolsFromOrigins';" ^
  "  $json = '{\"protocol\":\"mpv\",\"allowed_origins\":[\"http://localhost\",\"https://localhost\",\"http://127.0.0.1\",\"https://127.0.0.1\",\"http://192.168.1.102\",\"https://192.168.1.102\"]}';" ^
  "  try {" ^
  "    if (-not (Test-Path $auto)) { New-Item -Path $auto -Force -ErrorAction Stop | Out-Null }" ^
  "    New-ItemProperty -Path $auto -Name '1' -Value $json -PropertyType String -Force -ErrorAction Stop | Out-Null;" ^
  "    Write-Host '  [OK] Written to HKCU.';" ^
  "    exit 0;" ^
  "  } catch {" ^
  "    Write-Host '  HKCU is locked down; requesting elevation to write HKLM...';" ^
  "  }" ^
  "  $script = '$auto = ''HKLM:\Software\Policies\Google\Chrome\AutoLaunchProtocolsFromOrigins''; Remove-ItemProperty -Path ''HKLM:\Software\Policies\Google\Chrome'' -Name ''ExternalProtocolDialogShowAlwaysOpenCheckbox'' -ErrorAction SilentlyContinue; if (Test-Path $auto) { Remove-Item -Path $auto -Recurse -Force }; New-Item -Path $auto -Force | Out-Null; New-ItemProperty -Path $auto -Name ''1'' -Value ''{\"protocol\":\"mpv\",\"allowed_origins\":[\"http://localhost\",\"https://localhost\",\"http://127.0.0.1\",\"https://127.0.0.1\",\"http://192.168.1.102\",\"https://192.168.1.102\"]}'' -PropertyType String -Force | Out-Null';" ^
  "  $b64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script));" ^
  "  try {" ^
  "    Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-EncodedCommand',$b64) -Verb RunAs -Wait -WindowStyle Hidden;" ^
  "    Write-Host '  [OK] Written to HKLM.';" ^
  "  } catch {" ^
  "    Write-Host '  [WARN] Elevation declined or failed. Chrome will keep prompting on mpv:// links.';" ^
  "  }" ^
  "};" ^
  "& $code"
echo.

echo Done. Test with:  start "" "mpv://https://www.w3schools.com/html/mov_bbb.mp4"
echo.
pause
endlocal
