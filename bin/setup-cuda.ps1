# Downloads CUDA 13 runtime + cuDNN 9 DLLs needed by the bundled vsort plugin
# (built against CUDA 13: requires cublas64_13.dll, cublasLt64_13.dll, cufft64_12.dll,
# nvcudart_hybrid64.dll, cudnn64_9.dll, etc.).
#
# Sources:
#   - CUDA 13 components: NVIDIA's official redistributable archive
#     (https://developer.download.nvidia.com/compute/cuda/redist/)
#   - cuDNN 9.19.0.56 for CUDA 13: NVIDIA's official archive
#     (pinned to match the version vs-mlrt's CI builds vsort against)
# Target: Lib\site-packages\vapoursynth\plugins\vsort\
# Total download ~700MB. Final extracted DLLs ~2GB.

$ErrorActionPreference = "Stop"
# Disable Invoke-WebRequest's slow built-in progress bar globally.
$ProgressPreference = "SilentlyContinue"

Add-Type -AssemblyName System.Net.Http

function Download-WithProgress($url, $outPath, $expectedSize) {
    $client = [System.Net.Http.HttpClient]::new()
    $client.Timeout = [TimeSpan]::FromMinutes(30)
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
            $buffer = New-Object byte[] 1048576   # 1 MiB
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
                    Write-Host -NoNewline ("`r    progress: {0,3}%  {1,7:N1} / {2,7:N1} MB   {3,5:N1} MB/s   " -f $pct, $mb, $tmb, $speed)
                    $lastPrint = $now
                }
            }
            Write-Host ("`r    progress: 100%  {0,7:N1} MB             {1,5:N1} MB/s avg    " -f ($read / 1MB), (($read / 1MB) / [Math]::Max($sw.Elapsed.TotalSeconds, 0.001)))
        } finally {
            $outStream.Dispose()
            $inStream.Dispose()
        }
    } finally {
        $client.Dispose()
    }
}

$root      = Split-Path -Parent $MyInvocation.MyCommand.Path
$vsortDir  = Join-Path $root "Lib\site-packages\vapoursynth\plugins\vsort"
$tmpDir    = Join-Path $root ".cuda-dl-tmp"

if (-not (Test-Path $vsortDir)) {
    Write-Error "vsort folder not found at $vsortDir"
    exit 1
}

New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

# --- Clean up any previous (incompatible) CUDA DLLs from vsort folder -----
# Keep onnxruntime*, DirectML.dll. Delete anything that looks like CUDA/cuDNN.
$cudaPatterns = @('cudart64_*.dll','cublas*64_*.dll','cufft*64_*.dll',
                  'cudnn*.dll','nvblas*.dll','nvrtc*.dll','nvcudart_*.dll',
                  'cupti*.dll','nvperf_*.dll','checkpoint.dll','pcsamplingutil.dll')
foreach ($pat in $cudaPatterns) {
    Get-ChildItem -Path $vsortDir -Filter $pat -ErrorAction SilentlyContinue | ForEach-Object {
        Write-Host "    cleaning old: $($_.Name)" -ForegroundColor DarkGray
        Remove-Item -Force $_.FullName -ErrorAction SilentlyContinue
    }
}

function Extract-DllsFromZip($zipPath, $entryRegex) {
    # Copy first to dodge AV/lock issues on the source.
    $workPath = Join-Path $tmpDir "_work.zip"
    if (Test-Path $workPath) { Remove-Item -Force $workPath -ErrorAction SilentlyContinue }
    Copy-Item -Path $zipPath -Destination $workPath -Force

    $fs = $null; $zip = $null
    try {
        $fs  = [System.IO.File]::Open($workPath, [System.IO.FileMode]::Open,
                                       [System.IO.FileAccess]::Read,
                                       [System.IO.FileShare]::ReadWrite)
        $zip = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Read)
        $entries = $zip.Entries | Where-Object { $_.FullName -match $entryRegex }
        foreach ($e in $entries) {
            $dest = Join-Path $vsortDir $e.Name
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($e, $dest, $true)
            Write-Host ("    -> {0,-40} ({1} MB)" -f $e.Name, [math]::Round($e.Length / 1MB, 1))
        }
    } finally {
        if ($zip) { $zip.Dispose() }
        if ($fs)  { $fs.Dispose() }
    }
}

function Get-Cached-Or-Download($url, $expectedSize, $fileName) {
    $outPath = Join-Path $tmpDir $fileName
    if (Test-Path $outPath) {
        $localSize = (Get-Item $outPath).Length
        if ($expectedSize -le 0 -or $localSize -eq $expectedSize) {
            Write-Host "    cached: $fileName"
            return $outPath
        }
        Write-Host "    cache size mismatch ($localSize vs $expectedSize), redownloading"
        try { Remove-Item -Force $outPath -ErrorAction Stop }
        catch {
            $outPath = Join-Path $tmpDir ("retry-{0:yyyyMMddHHmmss}-{1}" -f (Get-Date), $fileName)
        }
    }
    Write-Host "    downloading: $fileName ($([math]::Round($expectedSize/1MB,1)) MB)"
    Download-WithProgress -url $url -outPath $outPath -expectedSize $expectedSize
    return $outPath
}

# --- 1) CUDA 13 components from NVIDIA's redistributable archive ---------
# We fetch the redistrib JSON to discover the latest version's archive URLs.
$cudaRedistRoot = "https://developer.download.nvidia.com/compute/cuda/redist"
$cudaRedistJson = "$cudaRedistRoot/redistrib_13.2.1.json"  # known-good release

Write-Host ""
Write-Host "==> Fetching CUDA 13 redistributable manifest" -ForegroundColor Cyan
Write-Host "    $cudaRedistJson"
$manifest = Invoke-RestMethod -Uri $cudaRedistJson -UseBasicParsing

# Components needed by the vsort plugin's preloadCudaDlls() check
# (see https://github.com/AmusementClub/vs-mlrt/blob/master/vsort/win32.cpp):
#   cuda_cudart  -> cudart64_13.dll
#   libcublas    -> cublas64_13.dll, cublasLt64_13.dll
#   libcufft     -> cufft64_12.dll, cufftw64_12.dll
#   cuda_cupti   -> cupti64_*.dll (REQUIRED by vsort preload, easy to miss)
$cudaComponents = @('cuda_cudart','libcublas','libcufft','cuda_cupti')

foreach ($comp in $cudaComponents) {
    Write-Host ""
    Write-Host "==> $comp" -ForegroundColor Cyan
    $node = $manifest.$comp
    if (-not $node) { Write-Error "Component $comp not in manifest"; exit 1 }
    $win  = $node.'windows-x86_64'
    if (-not $win) { Write-Error "$comp has no windows-x86_64 archive"; exit 1 }
    $archUrl  = "$cudaRedistRoot/$($win.relative_path)"
    $archName = Split-Path -Leaf $win.relative_path
    $archSize = [int64]$win.size
    $zipPath  = Get-Cached-Or-Download -url $archUrl -expectedSize $archSize -fileName $archName
    # CUDA redist archives put Windows DLLs under bin/x64/ (older: bin/).
    # cuda_cupti is the odd one out and puts its DLLs under lib/.
    Extract-DllsFromZip -zipPath $zipPath -entryRegex '/(bin/x64|bin|lib)/[^/]+\.dll$'
}

# --- 2) cuDNN 9 from NVIDIA's official archive ---------------------------
# Pinned to the exact version that the vs-mlrt CI uses to build vsort/onnxruntime
# (see https://github.com/AmusementClub/vs-mlrt/blob/master/.github/workflows/windows-cuda-dependency.yml).
# The PyPI `nvidia-cudnn-cu13` wheel ships a newer 9.22, which breaks the cuDNN
# frontend protocol vsort was built against (CUDNN_BACKEND_API_FAILED at runtime).
Write-Host ""
Write-Host "==> cuDNN 9.19.0.56 (cuda13)" -ForegroundColor Cyan
$cudnnUrl  = 'https://developer.download.nvidia.com/compute/cudnn/redist/cudnn/windows-x86_64/cudnn-windows-x86_64-9.19.0.56_cuda13-archive.zip'
$cudnnName = Split-Path -Leaf $cudnnUrl
# NVIDIA's archive doesn't expose Content-Length reliably; pass 0 so we re-download if missing.
$zipPath = Get-Cached-Or-Download -url $cudnnUrl -expectedSize 0 -fileName $cudnnName
Extract-DllsFromZip -zipPath $zipPath -entryRegex '/bin/(x64/)?[^/]+\.dll$'

Write-Host ""
Write-Host "Cleaning up temp files..." -ForegroundColor Yellow
try {
    Remove-Item -Recurse -Force $tmpDir -ErrorAction Stop
} catch {
    Write-Host "    (some files in $tmpDir were locked; safe to delete manually later)" -ForegroundColor DarkYellow
}

Write-Host ""
Write-Host "Done. CUDA DLLs installed into:" -ForegroundColor Green
Write-Host "  $vsortDir"
Write-Host ""
Write-Host "Now press Ctrl+4 in mpv to use RIFE on CUDA." -ForegroundColor Green
