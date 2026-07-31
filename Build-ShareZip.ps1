#Requires -Version 5.1
<#
.SYNOPSIS
    Packages the files a colleague needs into MergeVideos-Installer.zip
    for easy distribution (email / Teams / shared drive).

.DESCRIPTION
    Bundles the installer, the merge script, the launcher, the uninstaller,
    and GETTING-STARTED.txt. The receiver extracts the ZIP and double-clicks
    Install.bat; the installer auto-detects FFmpeg and patches the script
    per-machine.

    Output: MergeVideos-Installer.zip next to this script (default) or the
    path you pass via -OutputPath.

.PARAMETER OutputPath
    Full path to the .zip file to create. Defaults to
    "$PSScriptRoot\MergeVideos-Installer.zip".

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File Build-ShareZip.ps1
    # Produces MergeVideos-Installer.zip in this folder.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File Build-ShareZip.ps1 -OutputPath C:\dist\merge.zip
#>

[CmdletBinding()]
param(
    [string]$OutputPath = (Join-Path $PSScriptRoot "MergeVideos-Installer.zip")
)

$ErrorActionPreference = 'Stop'

$filesToBundle = @(
    'Install.bat',
    'install.ps1',
    'merge-videos.ps1',
    'MergeVideos.bat',
    'Uninstall.bat',
    'uninstall.ps1',
    'GETTING-STARTED.txt'
)

# Verify all source files are present -- fail loud if the checklist and repo drift.
$missing = @()
foreach ($f in $filesToBundle) {
    $path = Join-Path $PSScriptRoot $f
    if (-not (Test-Path $path)) { $missing += $f }
}
if ($missing.Count -gt 0) {
    Write-Host "ERROR: The following files are missing from $PSScriptRoot :" -ForegroundColor Red
    $missing | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}

# Stage into a temp folder so the ZIP has a clean tree with no repo-only files
# (.git, .github, tests, RUNBOOK, LICENSE, PSScriptAnalyzerSettings, etc.).
$staging = Join-Path $env:TEMP ("mvf-stage-{0}" -f ([guid]::NewGuid().ToString('N')))
try {
    New-Item -ItemType Directory -Force -Path $staging | Out-Null
    foreach ($f in $filesToBundle) {
        Copy-Item -Path (Join-Path $PSScriptRoot $f) -Destination $staging -Force
    }

    if (Test-Path $OutputPath) { Remove-Item $OutputPath -Force }

    # Ensure the output directory exists.
    $outDir = Split-Path $OutputPath -Parent
    if ($outDir -and -not (Test-Path $outDir)) {
        New-Item -ItemType Directory -Force -Path $outDir | Out-Null
    }

    Compress-Archive -Path (Join-Path $staging '*') -DestinationPath $OutputPath -CompressionLevel Optimal

    $size = [math]::Round((Get-Item $OutputPath).Length / 1KB, 1)
    Write-Host ""
    Write-Host "SUCCESS!" -ForegroundColor Green
    Write-Host ""
    Write-Host ("  Bundled {0} files ({1} KB)" -f $filesToBundle.Count, $size)
    Write-Host ("  Output : {0}" -f $OutputPath) -ForegroundColor Green
    Write-Host ""
    Write-Host "Send this ZIP to a colleague. They extract it and double-click Install.bat."
    Write-Host "The installer will detect / install FFmpeg and patch the script for their machine."
} finally {
    if (Test-Path $staging) { Remove-Item $staging -Recurse -Force -ErrorAction SilentlyContinue }
}
