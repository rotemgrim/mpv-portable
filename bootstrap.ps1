<#
.SYNOPSIS
  Populate this clone with the binary payload (mpv.exe, VapourSynth
  plugins, ONNX models, ...) downloaded from the GitHub "payload"
  release.

.DESCRIPTION
  The repo only tracks small text/config/script files. Heavy binaries
  live as a single .7z asset on the rolling release tag "payload".
  Run this script once after cloning, or whenever you want to refresh
  the local binaries.

.PARAMETER Repo
  GitHub repo in "owner/name" form. Auto-detected from `git remote` if
  omitted.

.PARAMETER Tag
  Release tag to fetch from. Default: "payload".

.PARAMETER SkipChecksum
  Don't verify SHA256 (rarely useful).
#>

param(
    [string]$Repo,
    [string]$Tag = 'payload',
    [switch]$SkipChecksum
)

$ErrorActionPreference = 'Stop'
$repoRoot = $PSScriptRoot
Set-Location $repoRoot

if (-not $Repo) {
    $remote = git config --get remote.origin.url 2>$null
    if (-not $remote) { throw "Not a git repo and -Repo not specified." }
    if ($remote -match 'github\.com[:/]+([^/]+)/([^/.]+)(\.git)?') {
        $Repo = "$($Matches[1])/$($Matches[2])"
    } else {
        throw "Could not parse GitHub repo from remote: $remote"
    }
}
Write-Host "Repo: $Repo  tag: $Tag" -ForegroundColor Cyan

$base    = "https://github.com/$Repo/releases/download/$Tag"
$payload = Join-Path $repoRoot 'payload.7z'
$shaFile = "$payload.sha256"

# Need 7-Zip to extract. Look on PATH and standard install locations.
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

Write-Host "Downloading payload.7z ..." -ForegroundColor Cyan
Invoke-WebRequest -Uri "$base/payload.7z" -OutFile $payload -UseBasicParsing

if (-not $SkipChecksum) {
    try {
        Invoke-WebRequest -Uri "$base/payload.7z.sha256" -OutFile $shaFile -UseBasicParsing
        $expected = (Get-Content $shaFile -Raw).Trim().Split(' ')[0].ToLower()
        $actual   = (Get-FileHash -Algorithm SHA256 $payload).Hash.ToLower()
        if ($expected -ne $actual) {
            throw "SHA256 mismatch: expected $expected, got $actual"
        }
        Write-Host "SHA256 OK: $actual"
    } catch {
        Write-Warning "Checksum check skipped: $($_.Exception.Message)"
    }
}

Write-Host "Extracting into $repoRoot ..." -ForegroundColor Cyan
& $sevenZip x -y -o"$repoRoot" $payload | Out-Null
if ($LASTEXITCODE -ne 0) { throw "7z extract failed" }

Remove-Item -Force $payload, $shaFile -ErrorAction SilentlyContinue

if (Test-Path (Join-Path $repoRoot 'bin\mpv.exe')) {
    Write-Host "Done. bin\mpv.exe is ready." -ForegroundColor Green
} else {
    Write-Warning "Extraction finished but bin\mpv.exe not found -- check the payload contents."
}
