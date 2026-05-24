@echo off
rem ============================================================
rem  mpv:// URL protocol handler (single-file version)
rem  Invoked by Windows when an mpv://... link is opened.
rem  %1 is the full URL passed by the OS / browser.
rem ============================================================
setlocal
set "URL=%~1"
set "MPV_DIR=%~dp0"

powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$u = $env:URL;" ^
  "if (-not $u) { exit 1 };" ^
  "$u = $u -replace '^mpv:(//)?','';" ^
  "$u = $u.TrimEnd('/');" ^
  "$u = [uri]::UnescapeDataString($u);" ^
  "$u = $u -replace '^(https?|ftps?|rtmps?|rtsp|mms|file|srt)//','$1://';" ^
  "$d = $env:MPV_DIR;" ^
  "((Get-Date -Format o) + '  ' + $u) | Add-Content -LiteralPath (Join-Path $d 'mpv-protocol-handler.log');" ^
  "Start-Process -FilePath (Join-Path $d 'mpv.exe') -ArgumentList @('--', $u) -WorkingDirectory $d"

endlocal
