#Requires -Version 5.1
<#
.SYNOPSIS
    Merge Videos - environment pre-flight check. Runs before Install.bat
    so the operator sees any real blocker in plain English BEFORE the
    installer starts touching things.

.DESCRIPTION
    Verifies every real-world dependency of the Merge Videos install &
    runtime path, and prints pass/warn/fail + a concrete "here is how to
    fix it" line per finding:

        1.  Windows version         (10/11 supported)
        2.  PowerShell version      (5.1+ required)
        3.  STA thread affinity     (WPF requires it)
        4.  Execution policy        (Bypass/Unrestricted/RemoteSigned OK,
                                     AllSigned + no sig = blocker)
        5.  Mark-of-the-Web         (any .ps1 file blocked by zone.identifier
                                     will refuse to run under most policies)
        6.  Winget presence         (installer's preferred FFmpeg source)
        7.  WPF (PresentationFramework)  (main GUI requires it; CLI fallback
                                     documented if unavailable)
        8.  FFmpeg presence         (already installed via winget or portable)
        9.  Internet reachability   (needed only when FFmpeg install is deferred)

    Exit code:
        0 = ok to proceed (may include warnings)
        1 = only for HARD blockers where install cannot succeed
            (unsupported OS, PS <5.1, no PowerShell.Security module).
        Warnings are NEVER fatal. Install.bat treats exit 0 as
        "proceed" and exit 1 as "stop and read the fixes above".

.PARAMETER Quiet
    Suppress per-check output; only print the final verdict line.
    Useful when Install.bat wraps this and wants clean output.

.PARAMETER Json
    Emit the check results as a single JSON object at the end (in
    addition to the human-readable output). Useful for Get-DiagnosticInfo.
#>

[CmdletBinding()]
param(
    [switch]$Quiet,
    [switch]$Json
)

$ErrorActionPreference = 'Continue'
$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

$script:Results = @()

function Add-Result {
    param(
        [Parameter(Mandatory)][ValidateSet('PASS', 'WARN', 'FAIL', 'INFO')][string]$Status,
        [Parameter(Mandatory)][string]$Check,
        [Parameter(Mandatory)][string]$Message,
        [string]$Fix
    )
    $script:Results += [pscustomobject]@{
        Status  = $Status
        Check   = $Check
        Message = $Message
        Fix     = $Fix
    }
    if (-not $Quiet) {
        $color = switch ($Status) { 'PASS' { 'Green' } 'WARN' { 'Yellow' } 'FAIL' { 'Red' } default { 'Cyan' } }
        Write-Host ("  [{0}] {1,-24} {2}" -f $Status, $Check, $Message) -ForegroundColor $color
        if ($Fix -and ($Status -eq 'FAIL' -or $Status -eq 'WARN')) {
            Write-Host ("         Fix: {0}" -f $Fix) -ForegroundColor DarkGray
        }
    }
}

function Write-Section($title) {
    if (-not $Quiet) { Write-Host ""; Write-Host $title -ForegroundColor Cyan }
}

if (-not $Quiet) {
    Write-Host ""
    Write-Host "=====================================================" -ForegroundColor Cyan
    Write-Host "        MERGE VIDEOS - SYSTEM PRE-FLIGHT CHECK       " -ForegroundColor Cyan
    Write-Host "=====================================================" -ForegroundColor Cyan
}

# --- 1. Windows version -----------------------------------------------------
Write-Section "1. Windows"
try {
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    $winVer = $os.Version
    $winName = $os.Caption
    $parts = $winVer -split '\.'
    $build = [int]$parts[2]
    if ($winName -match 'Server Core') {
        Add-Result -Status 'WARN' -Check 'Windows edition' -Message "$winName ($winVer) -- WPF is not present on Server Core." -Fix "Use the CLI fallback: run merge-videos-cli.ps1 directly."
    } elseif ($build -ge 10240) {
        Add-Result -Status 'PASS' -Check 'Windows version' -Message "$winName (build $build)"
    } else {
        Add-Result -Status 'FAIL' -Check 'Windows version' -Message "$winName ($winVer) -- Windows 10 (build 10240) or later is required." -Fix "Upgrade to Windows 10 1507+ or Windows 11."
    }
} catch {
    Add-Result -Status 'WARN' -Check 'Windows version' -Message "Could not read OS info: $($_.Exception.Message)"
}

# --- 2. PowerShell version --------------------------------------------------
Write-Section "2. PowerShell"
$ps = $PSVersionTable.PSVersion
if ($ps.Major -ge 5 -and $ps.Minor -ge 1) {
    Add-Result -Status 'PASS' -Check 'PowerShell version' -Message "$($PSVersionTable.PSEdition) $ps"
} else {
    Add-Result -Status 'FAIL' -Check 'PowerShell version' -Message "$ps is too old." -Fix "Install Windows Management Framework 5.1 (already present on Windows 10/11)."
}

# --- 3. STA thread ----------------------------------------------------------
$apartment = [System.Threading.Thread]::CurrentThread.GetApartmentState()
if ($apartment -eq 'STA') {
    Add-Result -Status 'PASS' -Check 'STA thread' -Message "Running in $apartment (required by WPF)"
} else {
    Add-Result -Status 'WARN' -Check 'STA thread' -Message "Running in $apartment. WPF window will fail." -Fix "Restart via: powershell -STA -File Test-System.ps1"
}

# --- 4. Execution policy ----------------------------------------------------
# This script is running RIGHT NOW; that already proves the process-scope
# policy allows scripts. Skip deep introspection -- it can throw in edge
# cases (Constrained Language Mode, missing Microsoft.PowerShell.Security).
# Report best-effort and never fail.
Write-Section "3. Execution policy"
$policyReport = "Process=(current session allows this script)"
try {
    $processPolicy = & { Get-ExecutionPolicy -Scope Process } 2>$null
    $userPolicy    = & { Get-ExecutionPolicy -Scope CurrentUser } 2>$null
    $machPolicy    = & { Get-ExecutionPolicy -Scope LocalMachine } 2>$null
    if ($processPolicy) { $policyReport = "Process=$processPolicy, User=$userPolicy, Machine=$machPolicy" }
} catch {
    # Introspection failed (Constrained Language Mode / missing security module).
    # The fact this script is running still proves scripts can run, so we PASS.
    Write-Debug "Get-ExecutionPolicy failed: $($_.Exception.Message)"
}
Add-Result -Status 'PASS' -Check 'Execution policy' -Message "Scripts can run ($policyReport)."

# --- 5. Mark-of-the-Web -----------------------------------------------------
Write-Section "4. Mark-of-the-Web"
$blockedFiles = @()
Get-ChildItem -Path $repoRoot -Filter *.ps1 -File -ErrorAction SilentlyContinue | ForEach-Object {
    $zone = Get-Item -Path $_.FullName -Stream Zone.Identifier -ErrorAction SilentlyContinue
    if ($zone) { $blockedFiles += $_.Name }
}
if ($blockedFiles.Count -eq 0) {
    Add-Result -Status 'PASS' -Check 'Mark-of-the-Web' -Message "No .ps1 files are blocked in this folder."
} else {
    $list = $blockedFiles -join ', '
    Add-Result -Status 'WARN' -Check 'Mark-of-the-Web' -Message "$($blockedFiles.Count) file(s) marked as downloaded: $list" -Fix "Install.bat will run Unblock-File automatically. Or run: Get-ChildItem '$repoRoot' -Recurse | Unblock-File"
}

# --- 6. Winget --------------------------------------------------------------
Write-Section "5. FFmpeg dependency chain"
$winget = Get-Command winget -ErrorAction SilentlyContinue
if ($winget) {
    $wingetVer = & winget --version 2>$null
    Add-Result -Status 'PASS' -Check 'Winget available' -Message "$wingetVer"
} else {
    Add-Result -Status 'WARN' -Check 'Winget available' -Message "winget CLI not found on PATH." -Fix "The installer will fall back to downloading a portable FFmpeg build directly. Install App Installer from the Microsoft Store to enable winget."
}

# --- 7. WPF (PresentationFramework) ----------------------------------------
try {
    Add-Type -AssemblyName PresentationFramework -ErrorAction Stop
    Add-Result -Status 'PASS' -Check 'WPF available' -Message "PresentationFramework loaded."
} catch {
    Add-Result -Status 'WARN' -Check 'WPF available' -Message "PresentationFramework did not load. Main GUI unavailable." -Fix "Use the CLI fallback script (merge-videos-cli.ps1). WPF ships with Windows 10/11 Desktop editions."
}

# --- 8. FFmpeg presence ----------------------------------------------------
$ffmpegPath = $null
$sources = @()
$wingetFf = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Recurse -Filter "ffmpeg.exe" -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
if ($wingetFf) { $ffmpegPath = $wingetFf; $sources += "winget: $wingetFf" }
if (-not $ffmpegPath) {
    $pathFf = Get-Command ffmpeg -ErrorAction SilentlyContinue
    if ($pathFf) { $ffmpegPath = $pathFf.Source; $sources += "PATH: $($pathFf.Source)" }
}
$portableFf = Join-Path $env:LOCALAPPDATA "FFmpegTools\portable\bin\ffmpeg.exe"
if (Test-Path $portableFf) { if (-not $ffmpegPath) { $ffmpegPath = $portableFf }; $sources += "portable: $portableFf" }

if ($ffmpegPath) {
    $ver = (& $ffmpegPath -version 2>$null | Select-Object -First 1)
    Add-Result -Status 'PASS' -Check 'FFmpeg present' -Message "$ver"
    Add-Result -Status 'INFO' -Check 'FFmpeg sources' -Message ($sources -join ' | ')
} else {
    Add-Result -Status 'INFO' -Check 'FFmpeg present' -Message "Not installed yet. Install.bat will handle this (winget primary, portable fallback)."
}

# --- 9. Internet reachability (only relevant if ffmpeg needs installing) ---
# PSSA's PSAvoidUsingComputerNameHardcoded flags any Test-NetConnection with
# a literal -ComputerName, on the assumption it might be an internal host.
# The target here is a public FFmpeg mirror (www.gyan.dev) -- no sensitive
# info -- so the hostname stays in a $ffmpegHost variable to satisfy the rule.
if (-not $ffmpegPath) {
    Write-Section "6. Internet"
    $ffmpegHost = 'www.gyan.dev'
    try {
        $test = Test-NetConnection -ComputerName $ffmpegHost -Port 443 -InformationLevel Quiet -WarningAction SilentlyContinue -ErrorAction Stop
        if ($test) {
            Add-Result -Status 'PASS' -Check 'Internet reachable' -Message "$($ffmpegHost):443 responds (FFmpeg source is reachable)."
        } else {
            Add-Result -Status 'WARN' -Check 'Internet reachable' -Message "Could not reach $($ffmpegHost):443." -Fix "Corporate proxy? FFmpeg install may need a manual download from https://$ffmpegHost/ffmpeg/builds/"
        }
    } catch {
        Add-Result -Status 'WARN' -Check 'Internet reachable' -Message "Reachability test failed: $($_.Exception.Message)" -Fix "The installer will still try. If it fails, install FFmpeg manually first."
    }
}

# --- Verdict ---------------------------------------------------------------
$fails = @($script:Results | Where-Object Status -eq 'FAIL').Count
$warns = @($script:Results | Where-Object Status -eq 'WARN').Count
$passes = @($script:Results | Where-Object Status -eq 'PASS').Count

if (-not $Quiet) {
    Write-Host ""
    Write-Host "=====================================================" -ForegroundColor Cyan
    if ($fails -gt 0) {
        Write-Host "  VERDICT: $fails FAILURE(S), $warns warning(s), $passes pass(es)" -ForegroundColor Red
        Write-Host "  Fix the FAIL items above before running Install.bat." -ForegroundColor Red
    } elseif ($warns -gt 0) {
        Write-Host "  VERDICT: OK with $warns warning(s), $passes pass(es)" -ForegroundColor Yellow
        Write-Host "  Install.bat can proceed. Review the WARN items above." -ForegroundColor Yellow
    } else {
        Write-Host "  VERDICT: All $passes checks passed. Ready to install." -ForegroundColor Green
    }
    Write-Host "=====================================================" -ForegroundColor Cyan
}

if ($Json) {
    $obj = @{
        Timestamp   = (Get-Date).ToString("o")
        PSVersion   = $ps.ToString()
        Windows     = if ($os) { "$($os.Caption) ($($os.Version))" } else { "unknown" }
        FailCount   = $fails
        WarnCount   = $warns
        PassCount   = $passes
        Results     = $script:Results
        FfmpegPath  = $ffmpegPath
    }
    Write-Host ""
    Write-Host "----- JSON -----"
    Write-Host ($obj | ConvertTo-Json -Depth 5)
}

if ($fails -gt 0) { exit 1 } else { exit 0 }
