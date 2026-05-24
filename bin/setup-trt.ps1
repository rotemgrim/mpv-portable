# Downloads the TensorRT-RTX runtime + vstrt plugin from vs-mlrt v15.16.
#
# Target hardware: NVIDIA RTX GPUs (Blackwell sm_120, Ada, Ampere). TensorRT-RTX
# is NVIDIA's lightweight RTX-only runtime with native Blackwell support and
# JIT engine compilation (no per-GPU pre-build like classic TensorRT).
#
# Sources (GitHub release):
#   - VSTRT-RTX-Windows-x64.v15.16.7z   (~230 KB)  vstrt.dll plugin
#   - vsmlrt-cuda.v15.16.7z.001/.002    (~2.5 GB)  shared CUDA + tensorrt_rtx runtime
#                                                  (split because GitHub caps assets at 2 GB)
#
# We selectively extract only the tensorrt_rtx subset of vsmlrt-cuda to keep
# on-disk footprint reasonable (~1 GB instead of ~6 GB).
#
# Target layout:
#   Lib\site-packages\vapoursynth\plugins\vstrt.dll
#   Lib\site-packages\vapoursynth\plugins\vsmlrt-cuda\tensorrt_rtx.exe
#   Lib\site-packages\vapoursynth\plugins\vsmlrt-cuda\<TensorRT-RTX DLLs + CUDA core DLLs>

$ErrorActionPreference = "Stop"
$ProgressPreference     = "SilentlyContinue"

Add-Type -AssemblyName System.Net.Http
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Download-WithProgress($url, $outPath, $expectedSize) {
    $client = [System.Net.Http.HttpClient]::new()
    $client.Timeout = [TimeSpan]::FromMinutes(60)
    try {
        $resp = $client.GetAsync($url, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        $resp.EnsureSuccessStatusCode() | Out-Null
        $total = $resp.Content.Headers.ContentLength
        if (-not $total) { $total = $expectedSize }

        $inStream  = $resp.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $outStream = [System.IO.File]::Open($outPath, [System.IO.FileMode]::Create,
                                             [System.IO.FileAccess]::Write,
                                             [System.IO.FileShare]::Read)
        try {
            $buffer = New-Object byte[] 1048576
            $read = 0L
            $lastPrint = [DateTime]::MinValue
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            while (($n = $inStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                $outStream.Write($buffer, 0, $n)
                $read += $n
                $now = [DateTime]::Now
                if (($now - $lastPrint).TotalMilliseconds -ge 250) {
                    $mb    = $read / 1MB
                    $tmb   = $total / 1MB
                    $pct   = if ($total -gt 0) { [int](($read / $total) * 100) } else { 0 }
                    $speed = if ($sw.Elapsed.TotalSeconds -gt 0) { ($read / 1MB) / $sw.Elapsed.TotalSeconds } else { 0 }
                    Write-Host -NoNewline ("`r    progress: {0,3}%  {1,8:N1} / {2,8:N1} MB   {3,5:N1} MB/s   " -f $pct, $mb, $tmb, $speed)
                    $lastPrint = $now
                }
            }
            Write-Host ("`r    progress: 100%  {0,8:N1} MB                {1,5:N1} MB/s avg    " -f ($read / 1MB), (($read / 1MB) / [Math]::Max($sw.Elapsed.TotalSeconds, 0.001)))
        } finally {
            $outStream.Dispose()
            $inStream.Dispose()
        }
    } finally {
        $client.Dispose()
    }
}

function Get-Cached-Or-Download($url, $expectedSize, $outPath) {
    if (Test-Path $outPath) {
        $localSize = (Get-Item $outPath).Length
        if ($expectedSize -le 0 -or $localSize -eq $expectedSize) {
            Write-Host "    cached: $(Split-Path -Leaf $outPath)"
            return
        }
        Write-Host "    cache size mismatch ($localSize vs $expectedSize), redownloading"
        Remove-Item -Force $outPath
    }
    Write-Host "    downloading: $(Split-Path -Leaf $outPath) ($([math]::Round($expectedSize/1MB,1)) MB)"
    Download-WithProgress -url $url -outPath $outPath -expectedSize $expectedSize
}

$root        = Split-Path -Parent $MyInvocation.MyCommand.Path
$pluginsDir  = Join-Path $root "Lib\site-packages\vapoursynth\plugins"
$cudaDepsDir = Join-Path $pluginsDir "vsmlrt-cuda"
$tmpDir      = Join-Path $root ".trt-dl-tmp"

if (-not (Test-Path $pluginsDir)) {
    Write-Error "plugins folder not found at $pluginsDir"
    exit 1
}
New-Item -ItemType Directory -Force -Path $tmpDir, $cudaDepsDir | Out-Null

# --- 1) 7zr.exe (standalone 7-Zip extractor, ~600 KB) --------------------
# Needed because PowerShell cannot natively extract .7z archives.
$sevenZipExe = Join-Path $tmpDir "7zr.exe"
Write-Host ""
Write-Host "==> 7zr.exe (standalone 7-zip extractor)" -ForegroundColor Cyan
if (-not (Test-Path $sevenZipExe)) {
    # Pinned to a stable 7-Zip release; 7zr.exe is the LZMA SDK standalone extractor.
    Download-WithProgress -url "https://www.7-zip.org/a/7zr.exe" -outPath $sevenZipExe -expectedSize 0
} else {
    Write-Host "    cached"
}

function Extract-7z($archivePath, $destDir, $includePattern) {
    # -y: assume yes; -bso0 -bsp1: quiet stdout, keep progress; -ir!: recursive include
    # includePattern uses 7-zip wildcards (e.g., "vsmlrt-cuda/tensorrt_rtx*").
    $args = @("x", "-y", "-bso0", "-bsp1", "-o$destDir", $archivePath)
    if ($includePattern) { $args += "-ir!$includePattern" }
    & $sevenZipExe @args
    if ($LASTEXITCODE -ne 0) { throw "7zr.exe failed (exit $LASTEXITCODE) on $archivePath" }
}

# --- 2) VSTRT-RTX plugin (vstrt.dll) -------------------------------------
Write-Host ""
Write-Host "==> VSTRT-RTX plugin" -ForegroundColor Cyan
$vstrtUrl  = "https://github.com/AmusementClub/vs-mlrt/releases/download/v15.16/VSTRT-RTX-Windows-x64.v15.16.7z"
$vstrtZip  = Join-Path $tmpDir "VSTRT-RTX-Windows-x64.v15.16.7z"
Get-Cached-Or-Download -url $vstrtUrl -expectedSize 233126 -outPath $vstrtZip

# Extract directly into the plugins dir. Archive contains vstrt.dll at root.
Extract-7z -archivePath $vstrtZip -destDir $pluginsDir -includePattern $null
if (-not (Test-Path (Join-Path $pluginsDir "vstrt_rtx.dll"))) {
    Write-Error "vstrt_rtx.dll did not extract to $pluginsDir"
    exit 1
}
Write-Host "    -> vstrt_rtx.dll" -ForegroundColor Green

# --- 3) vsmlrt-cuda split parts ------------------------------------------
Write-Host ""
Write-Host "==> vsmlrt-cuda (split archive, ~2.5 GB total)" -ForegroundColor Cyan
$cudaBase    = "https://github.com/AmusementClub/vs-mlrt/releases/download/v15.16"
$cudaPart1   = Join-Path $tmpDir "vsmlrt-cuda.v15.16.7z.001"
$cudaPart2   = Join-Path $tmpDir "vsmlrt-cuda.v15.16.7z.002"
Get-Cached-Or-Download -url "$cudaBase/vsmlrt-cuda.v15.16.7z.001" -expectedSize 2147483647 -outPath $cudaPart1
Get-Cached-Or-Download -url "$cudaBase/vsmlrt-cuda.v15.16.7z.002" -expectedSize 464467988  -outPath $cudaPart2

# 7zr handles split archives natively when invoked on the .001 file.
# Selective extract:
#   - vsmlrt-cuda/tensorrt_rtx*  (the tensorrt_rtx.exe and its companion DLLs)
#   - vsmlrt-cuda/cudart64_*.dll, cublas*64_*.dll, cufft*64_*.dll, cupti64_*.dll,
#     nvinfer*.dll, nvonnxparser*.dll  (TRT-RTX runtime + CUDA core)
# The vsmlrt-cuda folder also contains classic TensorRT bits (~GB) we skip.
Write-Host ""
Write-Host "    extracting tensorrt_rtx subset into $cudaDepsDir" -ForegroundColor Cyan

# Extract to a staging folder first so we control final placement and can prune.
$stageDir = Join-Path $tmpDir "stage"
if (Test-Path $stageDir) { Remove-Item -Recurse -Force $stageDir }
New-Item -ItemType Directory -Force -Path $stageDir | Out-Null

# Include patterns (7-zip glob, matches anywhere in path):
$includes = @(
    "tensorrt_*"           # tensorrt_rtx.exe, tensorrt_rtx_*.dll, tensorrt_onnxparser_rtx_*.dll
    "cudart64_*.dll"
    "cublas*64_*.dll"
    "cufft*64_*.dll"
    "cupti64_*.dll"
    "nvinfer*.dll"
    "nvrtc*.dll"
    "zlibwapi.dll"
)
$argList = @("x", "-y", "-bso0", "-bsp1", "-o$stageDir", $cudaPart1)
foreach ($p in $includes) { $argList += "-ir!$p" }
& $sevenZipExe @argList
if ($LASTEXITCODE -ne 0) { throw "7zr.exe failed extracting vsmlrt-cuda (exit $LASTEXITCODE)" }

# Move extracted files (regardless of archive subdir) into the flat vsmlrt-cuda folder.
$extracted = Get-ChildItem -Path $stageDir -Recurse -File
if (-not $extracted) {
    Write-Error "Nothing was extracted from vsmlrt-cuda. Patterns may not match."
    exit 1
}
foreach ($f in $extracted) {
    $dest = Join-Path $cudaDepsDir $f.Name
    Copy-Item -Path $f.FullName -Destination $dest -Force
    Write-Host ("    -> {0,-45} ({1,7:N1} MB)" -f $f.Name, ($f.Length / 1MB))
}

if (-not (Test-Path (Join-Path $cudaDepsDir "tensorrt_rtx.exe"))) {
    Write-Warning "tensorrt_rtx.exe was not found. Inspect $stageDir to see what was extracted."
}

Write-Host ""
Write-Host "Cleaning up temp files..." -ForegroundColor Yellow
try {
    Remove-Item -Recurse -Force $tmpDir -ErrorAction Stop
} catch {
    Write-Host "    (some files in $tmpDir were locked; safe to delete manually later)" -ForegroundColor DarkYellow
}

Write-Host ""
Write-Host "Done. TensorRT-RTX installed:" -ForegroundColor Green
Write-Host "  $pluginsDir\vstrt.dll"
Write-Host "  $cudaDepsDir\tensorrt_rtx.exe"
Write-Host ""
Write-Host "First RIFE run will JIT-build an engine for your GPU (~10-30s)." -ForegroundColor Green
Write-Host "Subsequent runs use the cached engine." -ForegroundColor Green
