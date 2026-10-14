@echo off
rem Builds gpumv.dll with CUDA + MSVC and installs it into the portable VapourSynth plugins folder.
setlocal
cd /d "%~dp0"

set "VSDIR="
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
for /f "usebackq delims=" %%i in (`call "%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "VSDIR=%%i"
if not defined VSDIR (echo MSVC build tools not found & exit /b 1)
rem vcvars64 looks for vswhere on PATH
set "PATH=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer;%PATH%"
call "%VSDIR%\VC\Auxiliary\Build\vcvars64.bat" >nul || exit /b 1

if not exist build mkdir build
rem sm_120 native code for RTX 50, PTX for older GPUs (JIT-compiled by the driver)
nvcc -O3 -std=c++17 -shared -o build\gpumv.dll src\gpumv.cu -Iinclude ^
    -Xcompiler "/MD /O2 /W3" ^
    -gencode arch=compute_75,code=compute_75 ^
    -gencode arch=compute_120,code=sm_120 || exit /b 1

copy /y build\gpumv.dll ..\bin\Lib\site-packages\vapoursynth\plugins\gpumv.dll >nul || (echo Install failed, is mpv running? & exit /b 1)
echo Installed gpumv.dll
