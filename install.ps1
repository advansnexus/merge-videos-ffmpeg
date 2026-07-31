#Requires -Version 5.1
<#
.SYNOPSIS
    One-click installer for Merge Videos (FFmpeg).

.DESCRIPTION
    Robust install path for shipping to non-technical colleagues:

      Step 0. Unblock any Mark-of-the-Web on this folder's .ps1 files.
              Defuses "cannot be loaded because running scripts is
              disabled on this system" that people hit after extracting
              a ZIP downloaded from Teams / email / OneDrive.

      Step 1. Locate or install FFmpeg. Order:
              (a) Any existing winget-installed Gyan.FFmpeg
              (b) Anything already on PATH
              (c) Portable install at %LOCALAPPDATA%\FFmpegTools\portable\
              (d) Install via winget (Gyan.FFmpeg)
              (e) Portable download from gyan.dev (winget-free fallback)
              Any failure at each step is caught and reported in plain
              English with a concrete "what to try next" hint.

      Step 2. Copy merge-videos.ps1 (WPF GUI) and merge-videos-cli.ps1
              (fallback) to %LOCALAPPDATA%\FFmpegTools\, patching the
              hardcoded FFmpeg path in each.

      Step 3. Create Desktop + Start Menu shortcuts targeting the WPF
              script, launched hidden.

      Step 4. Print a plain-English summary of what happened + what to
              do if anything went wrong.

    All operations are per-user (%LOCALAPPDATA%, current-user shortcuts).
    No admin rights required. Nothing is written to HKLM.

.PARAMETER Quiet
    Suppress per-step chatter; still prints the final verdict.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path $MyInvocation.MyCommand.Path -Parent
$toolsDir  = Join-Path $env:LOCALAPPDATA "FFmpegTools"
$logFile   = Join-Path $toolsDir "install.log"
$portable  = Join-Path $toolsDir "portable"

# ---- plain-language reporting -----------------------------------------------
function Say { param([string]$m, [string]$Color = 'White') Write-Host $m -ForegroundColor $Color }
function Step($n, $of, $msg) { Say ""; Say "[$n/$of] $msg" -Color Cyan }
function Ok  ($m) { Say "     OK   $m" -Color Green }
function Info($m) { Say "     info $m" -Color DarkGray }
function Warn($m) { Say "     warn $m" -Color Yellow }
function Fail($m, $fix) {
    Say ""
    Say "     FAIL $m" -Color Red
    if ($fix) { Say "     What to try: $fix" -Color Yellow }
    Say ""
}

# Log every step to a file too, so Get-DiagnosticInfo.ps1 can bundle it later.
if (-not (Test-Path $toolsDir)) { New-Item -ItemType Directory -Force -Path $toolsDir | Out-Null }
function LogLine($m) { Add-Content -Path $logFile -Value ("[{0}] {1}" -f (Get-Date -Format 'o'), $m) -ErrorAction SilentlyContinue }
LogLine "=== install.ps1 start (PS $($PSVersionTable.PSVersion), user $env:USERNAME) ==="

Say ""
Say "=====================================================" -Color Cyan
Say "        MERGE VIDEOS (FFmpeg) - INSTALLER            " -Color Cyan
Say "=====================================================" -Color Cyan

# ---- Step 0: Unblock this folder --------------------------------------------
Step 0 4 "Unblock Mark-of-the-Web on this folder..."
try {
    $blocked = 0
    Get-ChildItem -Path $scriptDir -Recurse -File -Include *.ps1,*.psd1,*.bat,*.vbs -ErrorAction SilentlyContinue | ForEach-Object {
        if (Get-Item -Path $_.FullName -Stream Zone.Identifier -ErrorAction SilentlyContinue) {
            Unblock-File -Path $_.FullName -ErrorAction SilentlyContinue
            $blocked++
        }
    }
    if ($blocked -gt 0) { Ok "unblocked $blocked file(s) marked as downloaded." }
    else                { Ok "no blocked files -- nothing to unblock." }
    LogLine "Step 0: unblocked $blocked files"
} catch {
    Warn "Unblock-File pass failed: $($_.Exception.Message). Continuing; if scripts refuse to run later, restart the installer."
    LogLine "Step 0 failed: $($_.Exception.Message)"
}

# ---- Step 1: Locate / install FFmpeg ----------------------------------------
Step 1 4 "Locate or install FFmpeg..."

function Find-ExistingFfmpeg {
    # (a) winget
    $winget = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Recurse -Filter "ffmpeg.exe" -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
    if ($winget) { return @{ Path = $winget; Source = 'winget' } }
    # (b) PATH
    $onPath = Get-Command ffmpeg -ErrorAction SilentlyContinue
    if ($onPath) { return @{ Path = $onPath.Source; Source = 'PATH' } }
    # (c) portable
    $portableFf = Join-Path $portable "bin\ffmpeg.exe"
    if (Test-Path $portableFf) { return @{ Path = $portableFf; Source = 'portable' } }
    return $null
}

$found = Find-ExistingFfmpeg
$ffmpegExe = $null
if ($found) {
    Ok "FFmpeg already present ($($found.Source)):"
    Info $found.Path
    $ffmpegExe = $found.Path
    LogLine "Step 1 (existing): $($found.Source) at $($found.Path)"
} else {
    # (d) winget install
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if ($winget) {
        Info "Trying winget install Gyan.FFmpeg (this may take a few minutes on first run)..."
        try {
            $out = & winget install --id Gyan.FFmpeg --exact --accept-package-agreements --accept-source-agreements --silent 2>&1
            LogLine ("winget output: " + ($out -join ' | '))
            $found = Find-ExistingFfmpeg
            if ($found) {
                Ok "FFmpeg installed via winget."
                Info $found.Path
                $ffmpegExe = $found.Path
            } else {
                Warn "winget completed but FFmpeg still not found on disk. Trying portable fallback..."
            }
        } catch {
            Warn "winget install failed: $($_.Exception.Message). Trying portable fallback..."
            LogLine "winget install exception: $($_.Exception.Message)"
        }
    } else {
        Warn "winget not found. Trying portable fallback..."
    }

    # (e) Portable download from gyan.dev
    if (-not $ffmpegExe) {
        Info "Downloading portable FFmpeg from www.gyan.dev (about 100 MB)..."
        $zipUrl = 'https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip'
        $zipTmp = Join-Path $env:TEMP ("mvf-ffmpeg-{0}.zip" -f ([guid]::NewGuid().ToString('N')))
        try {
            if (Test-Path $portable) { Remove-Item $portable -Recurse -Force -ErrorAction SilentlyContinue }
            New-Item -ItemType Directory -Force -Path $portable | Out-Null

            # PS 5.1 defaults to TLS 1.0 which gyan.dev refuses.
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            $ProgressPreference = 'SilentlyContinue'
            Invoke-WebRequest -Uri $zipUrl -OutFile $zipTmp -UseBasicParsing -TimeoutSec 300
            LogLine "Downloaded $([math]::Round((Get-Item $zipTmp).Length / 1MB, 1)) MB from $zipUrl"

            # Expand + flatten. Gyan builds ship as ffmpeg-<version>-essentials_build\{bin,doc,presets}.
            $expandRoot = Join-Path $env:TEMP ("mvf-ffmpeg-x-{0}" -f ([guid]::NewGuid().ToString('N')))
            Expand-Archive -Path $zipTmp -DestinationPath $expandRoot -Force
            $innerRoot = Get-ChildItem -Path $expandRoot -Directory | Select-Object -First 1
            if (-not $innerRoot) { throw "Downloaded ZIP had no top-level folder." }
            Copy-Item -Path (Join-Path $innerRoot.FullName '*') -Destination $portable -Recurse -Force
            Remove-Item $expandRoot -Recurse -Force -ErrorAction SilentlyContinue

            $portableFf = Join-Path $portable "bin\ffmpeg.exe"
            if (-not (Test-Path $portableFf)) { throw "Extract completed but bin\ffmpeg.exe missing at $portableFf." }
            $ffmpegExe = $portableFf
            Ok "Portable FFmpeg installed at $portable"
            LogLine "Step 1 (portable): $ffmpegExe"
        } catch {
            Fail "Could not install FFmpeg." "Download https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip manually, extract to '$portable', then re-run Install.bat."
            LogLine "Step 1 portable exception: $($_.Exception.Message)"
            exit 1
        } finally {
            if (Test-Path $zipTmp) { Remove-Item $zipTmp -Force -ErrorAction SilentlyContinue }
        }
    }
}

if (-not $ffmpegExe -or -not (Test-Path $ffmpegExe)) {
    Fail "FFmpeg was not installed and no existing copy was found." "Download from https://www.gyan.dev/ffmpeg/builds/ manually and re-run Install.bat."
    exit 1
}

# ---- Step 2: Copy the two scripts, patching the ffmpeg path -----------------
Step 2 4 "Install scripts to $toolsDir ..."

$scriptsToInstall = @('merge-videos.ps1', 'merge-videos-cli.ps1')
foreach ($scriptName in $scriptsToInstall) {
    $src = Join-Path $scriptDir $scriptName
    $dst = Join-Path $toolsDir  $scriptName
    if (-not (Test-Path $src)) {
        Fail "$scriptName not found in $scriptDir." "Re-extract the ZIP fully; do not run Install.bat from inside the ZIP viewer."
        LogLine "Step 2 missing: $src"
        exit 1
    }
    try {
        $content = Get-Content $src -Raw
        $content = $content -replace '(?m)^\$ffmpeg\s*=\s*".*"', "`$ffmpeg  = `"$ffmpegExe`""
        Set-Content -Path $dst -Value $content -Encoding UTF8
        Ok "$scriptName installed and patched."
        LogLine "Step 2 copied: $dst"
    } catch {
        Fail "Could not write $dst." "Check that %LOCALAPPDATA% is writable and re-run. Antivirus can also block script writes."
        LogLine "Step 2 write failed: $($_.Exception.Message)"
        exit 1
    }
}

# ---- Step 3: Create Desktop + Start Menu shortcuts --------------------------
Step 3 4 "Create shortcuts (Desktop + Start Menu)..."

$mainScript = Join-Path $toolsDir "merge-videos.ps1"
$wsh = New-Object -ComObject WScript.Shell

$shortcutTargets = @(
    (Join-Path ([Environment]::GetFolderPath('Desktop')) "Merge Videos.lnk"),
    (Join-Path ([Environment]::GetFolderPath('StartMenu')) "Programs\Merge Videos.lnk")
)

foreach ($lnk in $shortcutTargets) {
    try {
        $parent = Split-Path $lnk -Parent
        if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
        $sc = $wsh.CreateShortcut($lnk)
        $sc.TargetPath       = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
        $sc.Arguments        = "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$mainScript`""
        $sc.WorkingDirectory = $toolsDir
        $sc.IconLocation     = "$env:SystemRoot\System32\imageres.dll,174"
        $sc.Description      = "Merge two or more videos with FFmpeg"
        $sc.Save()
        Ok "shortcut: $(Split-Path $lnk -Leaf)"
        LogLine "Step 3 shortcut: $lnk"
    } catch {
        Warn "Could not create shortcut '$lnk': $($_.Exception.Message). You can still launch MergeVideos.bat directly."
        LogLine "Step 3 shortcut failed: $lnk -- $($_.Exception.Message)"
    }
}

# ---- Step 4: Verdict --------------------------------------------------------
Step 4 4 "Done."

Say ""
Say "=====================================================" -Color Cyan
Say "  Ready to use." -Color Green
Say ""
Say "  Launch by either:"
Say "    * Double-click 'Merge Videos' on your Desktop"
Say "    * Start Menu -> search 'Merge Videos'"
Say ""
Say "  If the GUI does not open:"
Say "    * Try MergeVideos.bat from the folder you extracted"
Say "    * Or run Get-DiagnosticInfo.ps1 to build a support bundle"
Say ""
Say "  To uninstall: run Uninstall.bat from this folder."
Say "=====================================================" -Color Cyan

LogLine "=== install.ps1 done ==="
exit 0
