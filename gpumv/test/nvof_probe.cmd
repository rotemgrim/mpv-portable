@echo off
rem Builds and runs nvof_probe.exe (NVIDIA optical-flow hardware check)
setlocal
cd /d "%~dp0"
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
for /f "usebackq delims=" %%i in (`call "%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "VSDIR=%%i"
set "PATH=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer;%PATH%"
call "%VSDIR%\VC\Auxiliary\Build\vcvars64.bat" >nul || exit /b 1
if not exist ..\build mkdir ..\build
nvcc -O2 -o ..\build\nvof_probe.exe nvof_probe.cu -I..\include -lcuda || exit /b 1
..\build\nvof_probe.exe
