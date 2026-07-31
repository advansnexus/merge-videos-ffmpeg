#Requires -Version 5.1
<#
.SYNOPSIS
    Uninstalls Merge Videos (FFmpeg): removes shortcuts and the installed script.
    Does NOT uninstall FFmpeg itself (other tools may depend on it).
#>

$ErrorActionPreference = "SilentlyContinue"

$targets = @(
    (Join-Path ([Environment]::GetFolderPath('Desktop'))    "Merge Videos.lnk"),
    (Join-Path ([Environment]::GetFolderPath('StartMenu'))  "Programs\Merge Videos.lnk"),
    (Join-Path $env:LOCALAPPDATA "FFmpegTools\merge-videos.ps1"),
    (Join-Path $env:LOCALAPPDATA "FFmpegTools\merge-videos-cli.ps1"),
    (Join-Path $env:LOCALAPPDATA "FFmpegTools\install.log")
)

# Portable FFmpeg -- only remove if this tool downloaded it (dir exists).
# We do NOT touch a winget-installed FFmpeg (other tools may depend on it).
$portableFf = Join-Path $env:LOCALAPPDATA "FFmpegTools\portable"

$removed = 0
foreach ($t in $targets) {
    if (Test-Path $t) {
        Remove-Item $t -Force
        Write-Host "Removed: $t" -ForegroundColor Green
        $removed++
    } else {
        Write-Host "Not found (skipped): $t" -ForegroundColor DarkGray
    }
}

if (Test-Path $portableFf) {
    Remove-Item $portableFf -Recurse -Force
    Write-Host "Removed portable FFmpeg: $portableFf" -ForegroundColor Green
    $removed++
} else {
    Write-Host "Not found (skipped): $portableFf" -ForegroundColor DarkGray
}

Write-Host ""
Write-Host "Uninstall complete. Removed $removed item(s)." -ForegroundColor Cyan
Write-Host "FFmpeg installed via winget was left in place (may be used by other tools)."
Write-Host ""
Write-Host "Press any key to close..."
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
