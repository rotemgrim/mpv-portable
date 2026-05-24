@echo off
REM ============================================================
REM  Map B: to \\192.168.1.102\downloads on this PC
REM  Edit USERNAME and PASSWORD below, then run as the user
REM  who should have the drive (NOT as Administrator -- mapped
REM  drives are per-user; Admin-mapped drives won't show up
REM  in your normal session).
REM ============================================================

set SERVER=192.168.1.102
set SHARE=downloads
set DRIVE=B:
set USERNAME=CHANGEME
set PASSWORD=CHANGEME

REM --- Remove any existing mapping on this letter (ignore errors) ---
net use %DRIVE% /delete /y >nul 2>&1

REM --- Store the credential permanently in Credential Manager ---
REM     so Windows reconnects automatically after every reboot
REM     without prompting.
cmdkey /add:%SERVER% /user:%USERNAME% /pass:%PASSWORD%

REM --- Map the drive persistently ---
net use %DRIVE% \\%SERVER%\%SHARE% /user:%USERNAME% %PASSWORD% /persistent:yes

echo.
echo Done. Drive %DRIVE% is mapped to \\%SERVER%\%SHARE%.
echo It will reconnect automatically at every login.
pause
