<#
.SYNOPSIS
  Pack the heavy binary tree into payload.7z and upload it to the rolling
  GitHub release tag "payload".

.DESCRIPTION
  Run this from the repo root whenever the binaries under bin/ change
  (new mpv build, updated VapourSynth plugins, new ONNX model, etc.).

  It does NOT touch the git index. The binaries are expected to live on
  your local working tree (gitignored) and to also be hosted as a single
  release asset. Use ./bootstrap.ps1 on a clean clone to fetch them.

  Requires: 7-Zip on PATH, and optionally `gh` (GitHub CLI) for upload.
  Without gh, the .7z is built locally and you upload it yourself.

.PARAMETER NoUpload
  Build payload.7z but skip the release upload step.

.PARAMETER Tag
  Release tag to upload to. Default: "payload".
#>

param(
    [switch]$NoUpload,
    [string]$Tag = 'payload'
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

$payload = Join-Path $repoRoot 'payload.7z'
if (Test-Path $payload) { Remove-Item -Force $payload }

# Paths to include (relative to repo root). Globs accepted.
# Anything matched here is also gitignored; the two lists must stay in sync
# with .gitignore.
$includes = @(
    'bin/*.exe',
    'bin/*.dll',
    'bin/*.pyd',
    'bin/*.zip',
    'bin/Lib/site-packages/onnx',
    'bin/Lib/site-packages/onnx-*.dist-info',
    'bin/Lib/site-packages/vapoursynth',
    'bin/portable_config/fonts',
    'bin/portable_config/scripts/uosc/bin'
)

# Paths to exclude even if matched above. These are filename / directory
# patterns matched recursively by 7z's -xr! switch.
#
# Anything that is downloaded at runtime by a setup script must NOT be in
# the payload (it would just bloat the asset and overwrite user-specific
# choices). Keep this list in sync with .gitignore.
$excludes = @(
    'bin/portable_config/cache',
    'bin/portable_config/watch_later',
    '__pycache__',
    '*.log',

    # vsmlrt-cuda/ (entire folder, ~3 GB) is downloaded on demand by
    # setup-trt.ps1 from the upstream vs-mlrt release.
    'vsmlrt-cuda',

    # vsort/ CUDA + cuDNN runtime DLLs are downloaded on demand by
    # setup-cuda.bat / setup-cuda.ps1 (NVIDIA redistrib + PyPI cuDNN).
    'cudart64_*.dll',
    'cublas*64_*.dll',
    'cufft*64_*.dll',
    'cudnn*.dll',
    'nvblas*.dll',
    'nvrtc*.dll',
    'nvcudart_*.dll',
    'cupti*.dll',
    'nvperf_*.dll',
    'checkpoint.dll',
    'pcsamplingutil.dll',

    # Per-GPU TensorRT engine caches generated on first RIFE run.
    # Useless on a different GPU; rebuilt automatically.
    '*.engine',
    '*.engine.cache'
)

# Locate 7-Zip. Prefer PATH, fall back to standard install locations.
function Find-SevenZip {
    $cmd = Get-Command 7z -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($p in @(
        "$env:ProgramFiles\7-Zip\7z.exe",
        "${env:ProgramFiles(x86)}\7-Zip\7z.exe",
        "$env:LOCALAPPDATA\Programs\7-Zip\7z.exe"
    )) {
        if ($p -and (Test-Path $p)) { return $p }
    }
    return $null
}
$sevenZip = Find-SevenZip
if (-not $sevenZip) {
    throw "7-Zip not found. Install from https://7-zip.org or run: winget install 7zip.7zip"
}
Write-Host "Using 7-Zip: $sevenZip"

# Build switch list for 7z.
$zArgs = @('a', '-t7z', '-mx=5', '-ms=on', '-mmt=on', '-bb1', $payload)
foreach ($p in $includes) {
    if (-not (Test-Path $p)) {
        Write-Warning "Include path missing on disk, skipping: $p"
        continue
    }
    $zArgs += $p
}
foreach ($x in $excludes) {
    $zArgs += "-xr!$x"
}

Write-Host "Packing payload.7z ..." -ForegroundColor Cyan
Write-Host "  $sevenZip $($zArgs -join ' ')"
& $sevenZip @zArgs
if ($LASTEXITCODE -ne 0) { throw "7z failed with exit $LASTEXITCODE" }

$size = (Get-Item $payload).Length
Write-Host ("Built {0} ({1:N1} MB)" -f $payload, ($size / 1MB)) -ForegroundColor Green

# Compute checksum so the bootstrap script can verify integrity.
$sha = (Get-FileHash -Algorithm SHA256 $payload).Hash.ToLower()
$shaFile = "$payload.sha256"
"$sha *payload.7z" | Set-Content -NoNewline -Encoding ascii $shaFile
Write-Host "SHA256: $sha"

if ($NoUpload) {
    Write-Host "NoUpload set; stopping here. Upload manually with:" -ForegroundColor Yellow
    Write-Host "  gh release upload $Tag $payload $shaFile --clobber"
    return
}

$gh = Get-Command gh -ErrorAction SilentlyContinue
if (-not $gh) {
    Write-Warning "gh CLI not found. payload.7z built but not uploaded."
    Write-Host "Install GitHub CLI then run:"
    Write-Host "  gh release upload $Tag $payload $shaFile --clobber"
    return
}

# Ensure the release exists, then upload (replacing existing assets).
$releaseExists = $true
try { gh release view $Tag --json tagName *> $null } catch { $releaseExists = $false }
if ($LASTEXITCODE -ne 0) { $releaseExists = $false }

if (-not $releaseExists) {
    Write-Host "Creating release '$Tag' ..." -ForegroundColor Cyan
    gh release create $Tag --title "Binary payload" --notes "Heavy binary blobs (mpv.exe, VapourSynth plugins, ONNX models, etc.). Updated by tools/build-payload.ps1. Not a user-facing download -- see the 'latest' release for the portable SFX."
    if ($LASTEXITCODE -ne 0) { throw "gh release create failed" }
}

Write-Host "Uploading payload.7z to release '$Tag' ..." -ForegroundColor Cyan
gh release upload $Tag $payload $shaFile --clobber
if ($LASTEXITCODE -ne 0) { throw "gh release upload failed" }

Write-Host "Done." -ForegroundColor Green
