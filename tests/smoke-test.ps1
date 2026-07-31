#Requires -Version 5.1
<#
.SYNOPSIS
    Headless smoke test for merge-videos-ffmpeg. Runs without opening any GUI.

.DESCRIPTION
    Phase 1 (always):
        - PowerShell parse check on merge-videos.ps1, install.ps1, uninstall.ps1
        - Concat-list escape correctness for pathological filenames
        - FFmpeg availability at the installed / configured path

    Phase 2 (opt-in via $env:MERGE_TEST_INPUTS):
        - End-to-end merge of two real video files
        - Verifies output exists and has non-zero duration via ffprobe
        Example:
            $env:MERGE_TEST_INPUTS = "C:\path\to\v1.mp4,C:\path\to\v2.mp4"
            powershell -ExecutionPolicy Bypass -File tests\smoke-test.ps1

    Exit code:
        0 = all pass
        1 = any test failed
#>

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$failed   = 0
$passed   = 0

function Assert($cond, $name) {
    if ($cond) {
        Write-Host "  [PASS] $name" -ForegroundColor Green
        $script:passed++
    } else {
        Write-Host "  [FAIL] $name" -ForegroundColor Red
        $script:failed++
    }
}

Write-Host ""
Write-Host "Merge Videos - Smoke Test" -ForegroundColor Cyan
Write-Host "=========================" -ForegroundColor Cyan
Write-Host ""

# -- Phase 1a: PowerShell parse check --------------------------------------
Write-Host "[1] PowerShell parse check"
$scripts = @('merge-videos.ps1', 'install.ps1', 'uninstall.ps1')
foreach ($s in $scripts) {
    $path = Join-Path $repoRoot $s
    $errors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errors)
    Assert ($errors.Count -eq 0) "$s parses without errors"
    if ($errors.Count -gt 0) {
        foreach ($e in $errors) {
            Write-Host "         $($e.Message) (line $($e.Extent.StartLineNumber))" -ForegroundColor DarkYellow
        }
    }
}

# -- Phase 1b: Concat-list escape correctness ------------------------------
Write-Host ""
Write-Host "[2] Concat-list escape correctness"

# Replicate the exact escape logic from merge-videos.ps1
function Format-ConcatLine([string]$path) {
    $escaped = $path -replace "'", "'\''"
    return "file '$escaped'"
}

Assert ((Format-ConcatLine "C:\videos\clip.mp4") -eq "file 'C:\videos\clip.mp4'") "plain path"
Assert ((Format-ConcatLine "C:\my videos\a clip.mp4") -eq "file 'C:\my videos\a clip.mp4'") "path with spaces"
Assert ((Format-ConcatLine "C:\videos\it's mine.mp4") -eq "file 'C:\videos\it'\''s mine.mp4'") "path with single quote"
Assert ((Format-ConcatLine "C:\videos\-y evil.mp4") -eq "file 'C:\videos\-y evil.mp4'") "path starting with dash (flag-injection attempt)"

# -- Phase 1c: FFmpeg availability -----------------------------------------
Write-Host ""
Write-Host "[3] FFmpeg availability"

# Extract the $ffmpeg path from the (possibly installer-patched) script
$installedScript = Join-Path $env:LOCALAPPDATA "FFmpegTools\merge-videos.ps1"
$scriptToCheck   = if (Test-Path $installedScript) { $installedScript } else { Join-Path $repoRoot "merge-videos.ps1" }

$content = Get-Content $scriptToCheck -Raw
$match   = [regex]::Match($content, '(?m)^\$ffmpeg\s*=\s*"([^"]+)"')
Assert $match.Success "found ffmpeg path declaration in $scriptToCheck"

if ($match.Success) {
    $ffmpegPath = $match.Groups[1].Value
    Assert (Test-Path $ffmpegPath) "ffmpeg.exe exists at $ffmpegPath"

    if (Test-Path $ffmpegPath) {
        $ver = & $ffmpegPath -version 2>&1 | Select-Object -First 1
        Assert ($ver -match '^ffmpeg version') "ffmpeg -version returns valid output"
        Write-Host "         $ver" -ForegroundColor DarkGray
    }
}

# -- Phase 2: End-to-end merge (opt-in) ------------------------------------
Write-Host ""
Write-Host "[4] End-to-end merge (opt-in)"

if (-not $env:MERGE_TEST_INPUTS) {
    Write-Host "  [SKIP] set `$env:MERGE_TEST_INPUTS=`"path1.mp4,path2.mp4`" to enable" -ForegroundColor DarkGray
} else {
    $inputs = $env:MERGE_TEST_INPUTS -split ','
    $allExist = $true
    foreach ($p in $inputs) {
        if (-not (Test-Path $p.Trim())) { $allExist = $false; Write-Host "  Missing: $p" -ForegroundColor Red }
    }
    Assert $allExist "all input files exist"

    if ($allExist -and $match.Success) {
        $ffmpegPath = $match.Groups[1].Value
        $ffprobePath = Join-Path (Split-Path $ffmpegPath -Parent) "ffprobe.exe"
        Assert (Test-Path $ffprobePath) "ffprobe.exe available alongside ffmpeg"

        $listFile = Join-Path $env:TEMP ("merge-smoketest-{0}.txt" -f ([guid]::NewGuid().ToString("N")))
        $outFile  = Join-Path $env:TEMP ("merge-smoketest-{0}.mp4" -f ([guid]::NewGuid().ToString("N")))

        try {
            $sw = New-Object System.IO.StreamWriter($listFile, $false, (New-Object System.Text.UTF8Encoding($false)))
            foreach ($p in $inputs) {
                $abs = [System.IO.Path]::GetFullPath($p.Trim())
                $esc = $abs -replace "'", "'\''"
                $sw.WriteLine("file '$esc'")
            }
            $sw.Close()

            Write-Host "  Running: ffmpeg -f concat -safe 0 -i list -c copy $outFile ..." -ForegroundColor DarkGray
            & $ffmpegPath -hide_banner -loglevel error -f concat -safe 0 -i "$listFile" -c copy "$outFile" -y
            $streamCopyExit = $LASTEXITCODE

            if ($streamCopyExit -ne 0) {
                Write-Host "  Stream copy failed; trying re-encode fallback..." -ForegroundColor Yellow
                $inputArgs = @()
                foreach ($p in $inputs) { $inputArgs += @("-i", $p.Trim()) }
                $n = $inputs.Count
                $streams = ""
                for ($i = 0; $i -lt $n; $i++) { $streams += "[$i`:v:0][$i`:a:0]" }
                $filterComplex = "$streams" + "concat=n=$n`:v=1:a=1[outv][outa]"
                & $ffmpegPath -hide_banner -loglevel error @inputArgs -filter_complex $filterComplex `
                    -map "[outv]" -map "[outa]" `
                    -c:v libx264 -crf 23 -preset ultrafast `
                    -c:a aac -b:a 192k `
                    "$outFile" -y
            }

            Assert ((Test-Path $outFile) -and ((Get-Item $outFile).Length -gt 0)) "merged output file exists and is non-empty"

            if (Test-Path $outFile) {
                $duration = & $ffprobePath -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$outFile"
                Assert ([double]$duration -gt 0) "merged output has non-zero duration ($duration s)"
            }
        } finally {
            if (Test-Path $listFile) { Remove-Item $listFile -Force -ErrorAction SilentlyContinue }
            if (Test-Path $outFile)  { Remove-Item $outFile  -Force -ErrorAction SilentlyContinue }
        }
    }
}

# -- Summary --------------------------------------------------------------
Write-Host ""
Write-Host "Summary" -ForegroundColor Cyan
Write-Host "-------" -ForegroundColor Cyan
Write-Host "  Passed: $passed" -ForegroundColor Green
Write-Host "  Failed: $failed" -ForegroundColor $(if ($failed -eq 0) { 'Green' } else { 'Red' })
Write-Host ""

if ($failed -gt 0) { exit 1 } else { exit 0 }
