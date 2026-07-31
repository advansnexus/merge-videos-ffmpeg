#Requires -Version 5.1
<#
.SYNOPSIS
    One-click installer for Merge Videos (FFmpeg).
    Installs FFmpeg if missing, copies the script to %LOCALAPPDATA%\FFmpegTools\,
    and creates Desktop + Start Menu shortcuts. No admin rights required.
#>

$ErrorActionPreference = "Stop"
$toolsDir = Join-Path $env:LOCALAPPDATA "FFmpegTools"

Write-Host ""
Write-Host "Merge Videos (FFmpeg) - Installer" -ForegroundColor Cyan
Write-Host "==================================" -ForegroundColor Cyan
Write-Host ""

# -- Step 1: Check / install FFmpeg ----------------------------------------
Write-Host "[1/4] Checking for FFmpeg..."

$ffmpegExe = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Recurse -Filter "ffmpeg.exe" -ErrorAction SilentlyContinue |
             Select-Object -First 1 -ExpandProperty FullName

if (-not $ffmpegExe) {
    Write-Host "      FFmpeg not found. Installing via winget..." -ForegroundColor Yellow
    winget install --id Gyan.FFmpeg --exact --accept-package-agreements --accept-source-agreements
    $ffmpegExe = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Recurse -Filter "ffmpeg.exe" -ErrorAction SilentlyContinue |
                 Select-Object -First 1 -ExpandProperty FullName
}

if (-not $ffmpegExe) {
    Write-Host "ERROR: Could not locate ffmpeg.exe after install. Aborting." -ForegroundColor Red
    exit 1
}
Write-Host "      Found: $ffmpegExe" -ForegroundColor Green

# -- Step 2: Copy script to FFmpegTools folder -----------------------------
Write-Host "[2/4] Installing script to $toolsDir ..."

New-Item -ItemType Directory -Force -Path $toolsDir | Out-Null

$scriptDir = Split-Path $MyInvocation.MyCommand.Path -Parent
$src = Join-Path $scriptDir "merge-videos.ps1"
$dst = Join-Path $toolsDir  "merge-videos.ps1"

if (-not (Test-Path $src)) {
    Write-Host "ERROR: merge-videos.ps1 not found next to install.ps1. Aborting." -ForegroundColor Red
    exit 1
}

$content = Get-Content $src -Raw
# Patch the hardcoded ffmpeg path to match this machine
$content = $content -replace '(?m)^\$ffmpeg = ".*"', "`$ffmpeg = `"$ffmpegExe`""
Set-Content -Path $dst -Value $content -Encoding UTF8

Write-Host "      Script installed." -ForegroundColor Green

# -- Step 3: Create Desktop + Start Menu shortcuts -------------------------
Write-Host "[3/4] Creating shortcuts..."

$wsh = New-Object -ComObject WScript.Shell

$shortcutTargets = @(
    (Join-Path ([Environment]::GetFolderPath('Desktop')) "Merge Videos.lnk"),
    (Join-Path ([Environment]::GetFolderPath('StartMenu')) "Programs\Merge Videos.lnk")
)

foreach ($lnk in $shortcutTargets) {
    $parent = Split-Path $lnk -Parent
    if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }

    $sc = $wsh.CreateShortcut($lnk)
    $sc.TargetPath       = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $sc.Arguments        = "-NoProfile -ExecutionPolicy Bypass -STA -File `"$dst`""
    $sc.WorkingDirectory = $toolsDir
    $sc.IconLocation     = "$env:SystemRoot\System32\imageres.dll,174"  # film-reel-ish icon
    $sc.Description      = "Merge two or more videos with FFmpeg"
    $sc.Save()
}

Write-Host "      Shortcuts created (Desktop + Start Menu)." -ForegroundColor Green

# -- Step 4: Done ----------------------------------------------------------
Write-Host "[4/4] Done!" -ForegroundColor Green
Write-Host ""
Write-Host "To merge videos:" -ForegroundColor Cyan
Write-Host "  * Double-click 'Merge Videos' on your Desktop, OR"
Write-Host "  * Start Menu -> search 'Merge Videos'"
Write-Host ""
Write-Host "You will be prompted to upload Video 1, Video 2, then asked"
Write-Host "'Add another video?' - repeat until done. Videos are merged"
Write-Host "in the order you upload them."
Write-Host ""
Write-Host "To uninstall, run:" -ForegroundColor DarkGray
Write-Host "  Remove-Item `"$($shortcutTargets[0])`" -Force" -ForegroundColor DarkGray
Write-Host "  Remove-Item `"$($shortcutTargets[1])`" -Force" -ForegroundColor DarkGray
Write-Host "  Remove-Item `"$dst`" -Force" -ForegroundColor DarkGray
Write-Host ""
