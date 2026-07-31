#Requires -Version 5.1
<#
.SYNOPSIS
    Merge Videos - support bundle generator. Colleague runs this when
    they hit a problem; it produces a single ZIP they can email back.

.DESCRIPTION
    Bundles everything a maintainer needs to diagnose a "works on my
    machine" report:

      1.  Windows + PowerShell version, apartment, execution policy.
      2.  Full Test-System.ps1 -Json output.
      3.  install.log (from %LOCALAPPDATA%\FFmpegTools\install.log).
      4.  Contents listing of %LOCALAPPDATA%\FFmpegTools\.
      5.  Both shortcut targets + arguments (Desktop + Start Menu).
      6.  Mark-of-the-Web state of every .ps1 in the ZIP folder.
      7.  Last 100 lines of Windows Application event log for
          powershell.exe (if any).
      8.  ffmpeg -version output.

    NO video content is bundled. Nothing under user's home other than
    the FFmpegTools install log and the diagnostic runs themselves.

    Output: MergeVideos-Diagnostic-<computer>-<timestamp>.zip in the
    same folder as this script.

.PARAMETER OutputPath
    Full path for the diagnostic ZIP.
    Defaults to "$PSScriptRoot\MergeVideos-Diagnostic-<host>-<yyyyMMdd-HHmmss>.zip".
#>

[CmdletBinding()]
param(
    [string]$OutputPath
)

$ErrorActionPreference = 'Continue'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$toolsDir  = Join-Path $env:LOCALAPPDATA "FFmpegTools"

if (-not $OutputPath) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $OutputPath = Join-Path $scriptDir ("MergeVideos-Diagnostic-{0}-{1}.zip" -f $env:COMPUTERNAME, $stamp)
}

Write-Host ""
Write-Host "Merge Videos - collecting diagnostic bundle..." -ForegroundColor Cyan
Write-Host ""

$staging = Join-Path $env:TEMP ("mvf-diag-{0}" -f ([guid]::NewGuid().ToString('N')))
New-Item -ItemType Directory -Force -Path $staging | Out-Null

function Collect($name, $scriptBlock) {
    Write-Host ("  collecting: {0}" -f $name)
    $out = Join-Path $staging ("{0}.txt" -f $name)
    try {
        & $scriptBlock 2>&1 | Out-File -FilePath $out -Encoding UTF8
    } catch {
        "COLLECTION FAILED: $($_.Exception.Message)" | Out-File -FilePath $out -Encoding UTF8
    }
}

# 1. Machine + PS environment
Collect '01-environment' {
    "Timestamp     : $(Get-Date -Format o)"
    "Computer      : $env:COMPUTERNAME"
    "User          : $env:USERNAME"
    "OS            : $((Get-CimInstance Win32_OperatingSystem).Caption) $((Get-CimInstance Win32_OperatingSystem).Version)"
    "PS Version    : $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))"
    "Apartment     : $([System.Threading.Thread]::CurrentThread.GetApartmentState())"
    "ExecPolicy    : Effective=$(Get-ExecutionPolicy) User=$(Get-ExecutionPolicy -Scope CurrentUser) Machine=$(Get-ExecutionPolicy -Scope LocalMachine)"
    ""
    "PATH:"; $env:PATH -split ';' | ForEach-Object { "  $_" }
}

# 2. Test-System JSON
Collect '02-test-system' {
    $testSys = Join-Path $scriptDir "Test-System.ps1"
    if (Test-Path $testSys) {
        & powershell -NoProfile -ExecutionPolicy Bypass -STA -File $testSys -Quiet -Json
    } else {
        "Test-System.ps1 not present in $scriptDir (was this a partial extract?)"
    }
}

# 3. install.log
Collect '03-install-log' {
    $log = Join-Path $toolsDir "install.log"
    if (Test-Path $log) { Get-Content $log -Raw } else { "install.log not present at $log (installer may not have been run yet)." }
}

# 4. FFmpegTools directory listing
Collect '04-toolsdir-listing' {
    if (Test-Path $toolsDir) {
        Get-ChildItem -Path $toolsDir -Recurse | Select-Object FullName, Length, LastWriteTime | Format-Table -AutoSize | Out-String -Width 200
    } else {
        "$toolsDir does not exist. Installer was never run."
    }
}

# 5. Shortcut targets
Collect '05-shortcuts' {
    $wsh = New-Object -ComObject WScript.Shell
    foreach ($p in @(
        (Join-Path ([Environment]::GetFolderPath('Desktop')) "Merge Videos.lnk"),
        (Join-Path ([Environment]::GetFolderPath('StartMenu')) "Programs\Merge Videos.lnk")
    )) {
        if (Test-Path $p) {
            $sc = $wsh.CreateShortcut($p)
            "$p"
            "  Target   : $($sc.TargetPath)"
            "  Args     : $($sc.Arguments)"
            "  WorkDir  : $($sc.WorkingDirectory)"
            ""
        } else {
            "$p  (not created)"
        }
    }
}

# 6. Mark-of-the-Web status of ZIP folder
Collect '06-motw' {
    Get-ChildItem -Path $scriptDir -Recurse -File -Include *.ps1,*.psd1,*.bat,*.vbs -ErrorAction SilentlyContinue | ForEach-Object {
        $zone = Get-Item -Path $_.FullName -Stream Zone.Identifier -ErrorAction SilentlyContinue
        if ($zone) { "BLOCKED : $($_.FullName)" } else { "OK      : $($_.FullName)" }
    }
}

# 7. Recent PowerShell errors (application log)
Collect '07-app-eventlog' {
    try {
        Get-WinEvent -LogName Application -MaxEvents 100 -ErrorAction Stop |
            Where-Object { $_.ProviderName -match 'PowerShell|WinRM' -and $_.LevelDisplayName -in 'Error','Warning' } |
            Format-Table TimeCreated, ProviderName, LevelDisplayName, Id, @{n='Msg';e={$_.Message.Substring(0, [Math]::Min(200, $_.Message.Length))}} -AutoSize -Wrap | Out-String -Width 200
    } catch {
        "Could not read application event log: $($_.Exception.Message)"
    }
}

# 8. ffmpeg -version
Collect '08-ffmpeg-version' {
    $installed = Join-Path $toolsDir "merge-videos.ps1"
    $ffPath = $null
    if (Test-Path $installed) {
        $m = [regex]::Match((Get-Content $installed -Raw), '(?m)^\$ffmpeg\s*=\s*"([^"]+)"')
        if ($m.Success) { $ffPath = $m.Groups[1].Value }
    }
    if ($ffPath -and (Test-Path $ffPath)) {
        "path: $ffPath"
        ""
        & $ffPath -version
    } elseif (Get-Command ffmpeg -ErrorAction SilentlyContinue) {
        "path (from PATH): $((Get-Command ffmpeg).Source)"
        ""
        & ffmpeg -version
    } else {
        "ffmpeg not found in installed script or on PATH."
    }
}

# Wrap up ------------------------------------------------------------------
Write-Host ""
Write-Host "  packaging bundle..." -ForegroundColor DarkGray

try {
    if (Test-Path $OutputPath) { Remove-Item $OutputPath -Force }
    $outDir = Split-Path $OutputPath -Parent
    if ($outDir -and -not (Test-Path $outDir)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }
    Compress-Archive -Path (Join-Path $staging '*') -DestinationPath $OutputPath -CompressionLevel Optimal

    $sz = [math]::Round((Get-Item $OutputPath).Length / 1KB, 1)
    Write-Host ""
    Write-Host "  Done." -ForegroundColor Green
    Write-Host ""
    Write-Host ("  Bundle: {0} ({1} KB)" -f $OutputPath, $sz) -ForegroundColor Green
    Write-Host ""
    Write-Host "  Email this ZIP to whoever maintains the tool. It contains no video"
    Write-Host "  content and no personal files -- just install logs and system info."
} finally {
    if (Test-Path $staging) { Remove-Item $staging -Recurse -Force -ErrorAction SilentlyContinue }
}
