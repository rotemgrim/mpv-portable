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
  "if ($u -notmatch '^[a-zA-Z][a-zA-Z0-9+.-]*:') { $u = $u -replace '^([A-Za-z])([\\/])','$1:$2' };" ^
  "if ($u -match '^[A-Za-z]:[\\/]') { $u = 'lavf://file:' + $u };" ^
  "$d = $env:MPV_DIR;" ^
  "((Get-Date -Format o) + '  ' + $u) | Add-Content -LiteralPath (Join-Path $d 'mpv-protocol-handler.log');" ^
  "$q = [char]34;" ^
  "$arg = '-- ' + $q + ($u -replace $q, ($q+$q)) + $q;" ^
  "$psi = New-Object System.Diagnostics.ProcessStartInfo -Property @{FileName=(Join-Path $d 'mpv.exe'); Arguments=$arg; UseShellExecute=$false; WorkingDirectory=$d; RedirectStandardInput=$true; RedirectStandardOutput=$true; RedirectStandardError=$true};" ^
  "try { $p = [System.Diagnostics.Process]::Start($psi); $p.StandardInput.Close(); $p.StandardOutput.Close(); $p.StandardError.Close() } catch { ((Get-Date -Format o) + '  ERROR ' + $_.Exception.Message) | Add-Content -LiteralPath (Join-Path $d 'mpv-protocol-handler.log') }"

endlocal
