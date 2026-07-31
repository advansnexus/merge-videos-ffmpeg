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

# Install both the WPF GUI (merge-videos.ps1) and the classic CLI fallback
# (merge-videos-cli.ps1). Patch each script's hardcoded $ffmpeg path so it
# points at the FFmpeg install on this machine. The regex is space-tolerant
# so it matches whether the source uses "$ffmpeg = " or "$ffmpeg  = ".
$scriptsToInstall = @('merge-videos.ps1', 'merge-videos-cli.ps1')
foreach ($scriptName in $scriptsToInstall) {
    $src = Join-Path $scriptDir $scriptName
    $dst = Join-Path $toolsDir  $scriptName
    if (-not (Test-Path $src)) {
        Write-Host "ERROR: $scriptName not found next to install.ps1. Aborting." -ForegroundColor Red
        exit 1
    }
    $content = Get-Content $src -Raw
    $content = $content -replace '(?m)^\$ffmpeg\s*=\s*".*"', "`$ffmpeg  = `"$ffmpegExe`""
    Set-Content -Path $dst -Value $content -Encoding UTF8
}

Write-Host "      Scripts installed (WPF + CLI fallback)." -ForegroundColor Green

# -- Step 3: Create Desktop + Start Menu shortcuts -------------------------
Write-Host "[3/4] Creating shortcuts..."

$wsh = New-Object -ComObject WScript.Shell

# The main shortcut always launches the WPF GUI. CLI fallback is available
# from the install folder but not exposed as a shortcut.
$mainScript = Join-Path $toolsDir "merge-videos.ps1"

$shortcutTargets = @(
    (Join-Path ([Environment]::GetFolderPath('Desktop')) "Merge Videos.lnk"),
    (Join-Path ([Environment]::GetFolderPath('StartMenu')) "Programs\Merge Videos.lnk")
)

foreach ($lnk in $shortcutTargets) {
    $parent = Split-Path $lnk -Parent
    if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }

    $sc = $wsh.CreateShortcut($lnk)
    $sc.TargetPath       = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    # -WindowStyle Hidden avoids a lingering conhost window behind the WPF UI.
    # The script also hides its own console via SW_HIDE at startup as a
    # belt-and-braces measure.
    $sc.Arguments        = "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$mainScript`""
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
Write-Host "The GUI opens as a persistent window. Add videos in the order"
Write-Host "you want them joined, choose an output location, then click"
Write-Host "'Start Merge'. Progress and live logs update in place."
Write-Host ""
Write-Host "To uninstall, run Uninstall.bat next to this installer, or:" -ForegroundColor DarkGray
Write-Host "  Remove-Item `"$($shortcutTargets[0])`" -Force" -ForegroundColor DarkGray
Write-Host "  Remove-Item `"$($shortcutTargets[1])`" -Force" -ForegroundColor DarkGray
Write-Host "  Remove-Item `"$toolsDir\merge-videos.ps1`" -Force" -ForegroundColor DarkGray
Write-Host "  Remove-Item `"$toolsDir\merge-videos-cli.ps1`" -Force" -ForegroundColor DarkGray
Write-Host ""
