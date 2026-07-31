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
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'

# $PSScriptRoot is not populated during parameter binding on PS 5.1 when
# invoked via -File with a full path, so the default is resolved here.
$repoRoot = $PSScriptRoot
if (-not $repoRoot) { $repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $repoRoot) { $repoRoot = (Get-Location).Path }
if (-not $OutputPath) { $OutputPath = Join-Path $repoRoot "MergeVideos-Installer.zip" }

$filesToBundle = @(
    'Install.bat',
    'install.ps1',
    'Test-System.ps1',              # pre-flight check
    'Get-DiagnosticInfo.ps1',       # support bundle generator
    'Trust-Publisher.ps1',          # one-time cert trust helper (optional use)
    'merge-videos.ps1',             # WPF single-window GUI (primary)
    'merge-videos-cli.ps1',         # classic step-by-step CLI (fallback)
    'MergeVideos.bat',
    'Uninstall.bat',
    'uninstall.ps1',
    'GETTING-STARTED.txt'
)

# Optional files -- only bundle if present (signed build).
$optionalFiles = @(
    'MergeVideos-Publisher.cer'     # only exists after Sign-Scripts.ps1 -Export
)

# Verify all source files are present -- fail loud if the checklist and repo drift.
$missing = @()
foreach ($f in $filesToBundle) {
    $path = Join-Path $repoRoot $f
    if (-not (Test-Path $path)) { $missing += $f }
}
if ($missing.Count -gt 0) {
    Write-Host "ERROR: The following files are missing from $repoRoot :" -ForegroundColor Red
    $missing | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}

# Stage into a temp folder so the ZIP has a clean tree with no repo-only files
# (.git, .github, tests, RUNBOOK, LICENSE, PSScriptAnalyzerSettings, etc.).
$staging = Join-Path $env:TEMP ("mvf-stage-{0}" -f ([guid]::NewGuid().ToString('N')))
try {
    New-Item -ItemType Directory -Force -Path $staging | Out-Null
    foreach ($f in $filesToBundle) {
        Copy-Item -Path (Join-Path $repoRoot $f) -Destination $staging -Force
    }
    foreach ($f in $optionalFiles) {
        $p = Join-Path $repoRoot $f
        if (Test-Path $p) { Copy-Item -Path $p -Destination $staging -Force }
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
