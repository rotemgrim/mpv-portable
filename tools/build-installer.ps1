<#
.SYNOPSIS
  Build installer\Output\mpv-portable-setup.exe with Inno Setup 6.

.DESCRIPTION
  Packages a tree laid out like this repo with its binaries in place: this
  working tree by default (run ./bootstrap.ps1 first on a fresh clone), or the
  staged tree the CI workflow builds. installer\mpv-portable.iss picks the
  files and leaves out RIFE, SVP and local data (cache, logs, keys).

  Requires Inno Setup 6: winget install JRSoftware.InnoSetup

.PARAMETER Source
  The tree to package. Default: the repo root.

.PARAMETER Version
  Version shown in Windows' installed apps list. Default: today's date.
#>

param(
    [string]$Source,
    [string]$Version
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $Source) { $Source = $repoRoot }
$Source = (Resolve-Path $Source).Path

# Without these the install starts but its smoothing modes don't
foreach ($f in @('bin\mpv.exe', 'bin\msvcp140.dll', 'bin\Lib\site-packages\vapoursynth\vapoursynth.pyd',
                 'bin\Lib\site-packages\vapoursynth\plugins\gpumv.dll',
                 'bin\Lib\site-packages\vapoursynth\plugins\libmvtools.dll')) {
    if (-not (Test-Path (Join-Path $Source $f))) { throw "missing in ${Source}: $f" }
}

function Find-Iscc {
    $cmd = Get-Command iscc -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($p in @(
        "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe",
        "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
        "$env:ProgramFiles\Inno Setup 6\ISCC.exe"
    )) {
        if ($p -and (Test-Path $p)) { return $p }
    }
    return $null
}
$iscc = Find-Iscc
if (-not $iscc) { throw "Inno Setup 6 not found. Install it with: winget install JRSoftware.InnoSetup" }

$isccArgs = @("/DSrc=$Source", '/Q')
if ($Version) { $isccArgs += "/DAppVersion=$Version" }
& $iscc @isccArgs (Join-Path $repoRoot 'installer\mpv-portable.iss')
if ($LASTEXITCODE -ne 0) { throw "ISCC failed with exit $LASTEXITCODE" }

$out = Join-Path $repoRoot 'installer\Output\mpv-portable-setup.exe'
Write-Host ("Built {0} ({1:N1} MB)" -f $out, ((Get-Item $out).Length / 1MB)) -ForegroundColor Green
