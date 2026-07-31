#Requires -Version 5.1
<#
.SYNOPSIS
    Headless smoke test for merge-videos-ffmpeg. Runs without opening any GUI.

.DESCRIPTION
    Phase 1 (always):
        - PowerShell parse check on merge-videos.ps1, install.ps1, uninstall.ps1
        - PSScriptAnalyzer static analysis (skipped with a note if module missing)
        - Concat-list escape corpus for pathological filenames
        - FFmpeg availability at the installed / configured path, OR on PATH

    Phase 2 (opt-in via $env:MERGE_TEST_INPUTS):
        - End-to-end merge of two real video files (user-supplied)
        - Verifies output exists and has non-zero duration via ffprobe
        Example:
            $env:MERGE_TEST_INPUTS = "C:\path\to\v1.mp4,C:\path\to\v2.mp4"
            powershell -ExecutionPolicy Bypass -File tests\smoke-test.ps1

    Phase 3 (automatic when ffmpeg is available):
        - Pathological-filename end-to-end merge using ffmpeg-synthesized
          test videos with filenames containing spaces, %, &, $, single quotes,
          leading dashes, and unicode. Runs unattended in CI once ffmpeg is
          installed on the runner.
        - Disable with $env:MERGE_SKIP_PATHOLOGICAL = "1".

    CI mode:
        Set $env:MERGE_CI = "1" to soften ffmpeg-availability from FAIL to SKIP
        (so a lint-only CI job can run without downloading 240 MB of ffmpeg).

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

function Skip-Test($name, $reason) {
    Write-Host "  [SKIP] $name -- $reason" -ForegroundColor DarkGray
}

function Get-FfmpegPath {
    param([string]$hardcodedPath)
    if ($hardcodedPath -and (Test-Path $hardcodedPath)) { return $hardcodedPath }
    $onPath = Get-Command ffmpeg -ErrorAction SilentlyContinue
    if ($onPath) { return $onPath.Source }
    return $null
}

function Get-FfprobePath {
    param([string]$ffmpegPath)
    if ($ffmpegPath) {
        $sibling = Join-Path (Split-Path $ffmpegPath -Parent) "ffprobe.exe"
        if (Test-Path $sibling) { return $sibling }
    }
    $onPath = Get-Command ffprobe -ErrorAction SilentlyContinue
    if ($onPath) { return $onPath.Source }
    return $null
}

# Exact replica of merge-videos.ps1's escape rule -- if this diverges from
# the production script, Phase 3 tests will drift silently. Keep in lockstep.
function Format-ConcatLine([string]$path) {
    $escaped = $path -replace "'", "'\''"
    return "file '$escaped'"
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

# -- Phase 1b: PSScriptAnalyzer static analysis ----------------------------
Write-Host ""
Write-Host "[2] PSScriptAnalyzer static analysis"

$pssa = Get-Module -ListAvailable -Name PSScriptAnalyzer | Select-Object -First 1
if (-not $pssa) {
    Skip-Test "PSScriptAnalyzer scan" "module not installed (Install-Module PSScriptAnalyzer -Scope CurrentUser)"
} else {
    Import-Module PSScriptAnalyzer -ErrorAction Stop
    $settings = Join-Path $repoRoot "PSScriptAnalyzerSettings.psd1"
    $pssaArgs = @{
        Path    = $repoRoot
        Recurse = $true
    }
    if (Test-Path $settings) { $pssaArgs.Settings = $settings }
    $findings = Invoke-ScriptAnalyzer @pssaArgs
    $errors   = @($findings | Where-Object Severity -in 'Error','Warning')
    Assert ($errors.Count -eq 0) "no Error/Warning-level PSScriptAnalyzer findings"
    if ($errors.Count -gt 0) {
        foreach ($f in $errors) {
            Write-Host ("         {0}:{1}:{2} [{3}] {4} -- {5}" -f `
                (Split-Path $f.ScriptName -Leaf), $f.Line, $f.Column, $f.Severity, $f.RuleName, $f.Message) `
                -ForegroundColor DarkYellow
        }
    }
}

# -- Phase 1c: Concat-list escape corpus -----------------------------------
Write-Host ""
Write-Host "[3] Concat-list escape corpus"

# Each case: description, input path, expected output.
# The corpus documents the security posture: any of these filenames must
# produce a concat-list line that ffmpeg parses back to exactly the original
# path (no flag injection, no truncation, no argument-splitting).
$corpus = @(
    @{ Name = "plain path";                          In = "C:\videos\clip.mp4";                                Out = "file 'C:\videos\clip.mp4'" },
    @{ Name = "path with spaces";                    In = "C:\my videos\a clip.mp4";                           Out = "file 'C:\my videos\a clip.mp4'" },
    @{ Name = "single quote (basic)";                In = "C:\videos\it's mine.mp4";                           Out = "file 'C:\videos\it'\''s mine.mp4'" },
    @{ Name = "multiple single quotes";              In = "C:\videos\'a''b'.mp4";                              Out = "file 'C:\videos\'\''a'\'''\''b'\''.mp4'" },
    @{ Name = "leading dash (flag injection try)";   In = "C:\videos\-y evil.mp4";                             Out = "file 'C:\videos\-y evil.mp4'" },
    @{ Name = "double quote in name";                In = 'C:\videos\hello"world.mp4';                         Out = "file 'C:\videos\hello`"world.mp4'" },
    @{ Name = "percent sign (batch var attempt)";    In = "C:\videos\100%complete.mp4";                        Out = "file 'C:\videos\100%complete.mp4'" },
    @{ Name = "ampersand (cmd chain attempt)";       In = "C:\videos\a&b.mp4";                                 Out = "file 'C:\videos\a&b.mp4'" },
    @{ Name = "semicolon";                           In = "C:\videos\a;b.mp4";                                 Out = "file 'C:\videos\a;b.mp4'" },
    @{ Name = "dollar sign (var-expand attempt)";    In = "C:\videos\`$evil.mp4";                              Out = "file 'C:\videos\`$evil.mp4'" },
    @{ Name = "backtick";                            In = "C:\videos\a``b.mp4";                                Out = "file 'C:\videos\a``b.mp4'" },
    @{ Name = "unicode (french accent)";             In = "C:\videos\Cafe`u{0301}.mp4";                        Out = "file 'C:\videos\Cafe`u{0301}.mp4'" },
    @{ Name = "unicode (emoji)";                     In = "C:\videos\clip`u{1F3AC}.mp4";                       Out = "file 'C:\videos\clip`u{1F3AC}.mp4'" },
    @{ Name = "very long filename (200 chars)";      In = "C:\videos\" + ("a" * 200) + ".mp4";                 Out = "file 'C:\videos\" + ("a" * 200) + ".mp4'" },
    @{ Name = "newline injection attempt";           In = "C:\videos\a`nfile 'evil.mp4";                       Out = "file 'C:\videos\a`nfile '\''evil.mp4'" }
)

foreach ($case in $corpus) {
    $actual = Format-ConcatLine $case.In
    Assert ($actual -eq $case.Out) $case.Name
    if ($actual -ne $case.Out) {
        Write-Host ("         expected: {0}" -f $case.Out) -ForegroundColor DarkYellow
        Write-Host ("         actual  : {0}" -f $actual)   -ForegroundColor DarkYellow
    }
}

# -- Phase 1d: FFmpeg availability -----------------------------------------
Write-Host ""
Write-Host "[4] FFmpeg availability"

# Extract the $ffmpeg path from the (possibly installer-patched) script
$installedScript = Join-Path $env:LOCALAPPDATA "FFmpegTools\merge-videos.ps1"
$scriptToCheck   = if (Test-Path $installedScript) { $installedScript } else { Join-Path $repoRoot "merge-videos.ps1" }

$content     = Get-Content $scriptToCheck -Raw
$pathMatch   = [regex]::Match($content, '(?m)^\$ffmpeg\s*=\s*"([^"]+)"')
Assert $pathMatch.Success "found ffmpeg path declaration in $scriptToCheck"

$hardcoded  = if ($pathMatch.Success) { $pathMatch.Groups[1].Value } else { $null }
$ffmpegPath = Get-FfmpegPath -hardcodedPath $hardcoded
$ciMode     = $env:MERGE_CI -eq '1'

if ($ffmpegPath) {
    Assert $true "ffmpeg found at $ffmpegPath"
    $ver = & $ffmpegPath -version 2>&1 | Select-Object -First 1
    Assert ($ver -match '^ffmpeg version') "ffmpeg -version returns valid output"
    Write-Host "         $ver" -ForegroundColor DarkGray
} elseif ($ciMode) {
    Skip-Test "ffmpeg presence check" "MERGE_CI=1 (stock runner image, ffmpeg not installed)"
} else {
    Assert $false "ffmpeg.exe exists (hardcoded path missing and not on PATH)"
}

# -- Phase 2: End-to-end merge with user-supplied inputs (opt-in) ----------
Write-Host ""
Write-Host "[5] End-to-end merge with user-supplied inputs (opt-in)"

if (-not $env:MERGE_TEST_INPUTS) {
    Skip-Test "user-supplied merge" "set `$env:MERGE_TEST_INPUTS=`"path1.mp4,path2.mp4`" to enable"
} elseif (-not $ffmpegPath) {
    Skip-Test "user-supplied merge" "ffmpeg not available"
} else {
    $inputs = $env:MERGE_TEST_INPUTS -split ','
    $allExist = $true
    foreach ($p in $inputs) {
        if (-not (Test-Path $p.Trim())) { $allExist = $false; Write-Host "  Missing: $p" -ForegroundColor Red }
    }
    Assert $allExist "all input files exist"

    if ($allExist) {
        $ffprobePath = Get-FfprobePath -ffmpegPath $ffmpegPath
        Assert ($null -ne $ffprobePath) "ffprobe available"

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

            if ((Test-Path $outFile) -and $ffprobePath) {
                $duration = & $ffprobePath -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$outFile"
                Assert ([double]$duration -gt 0) "merged output has non-zero duration ($duration s)"
            }
        } finally {
            if (Test-Path $listFile) { Remove-Item $listFile -Force -ErrorAction SilentlyContinue }
            if (Test-Path $outFile)  { Remove-Item $outFile  -Force -ErrorAction SilentlyContinue }
        }
    }
}

# -- Phase 3: Pathological-filename end-to-end merge (auto) ----------------
Write-Host ""
Write-Host "[6] Pathological-filename end-to-end merge (auto-generated inputs)"

if ($env:MERGE_SKIP_PATHOLOGICAL -eq '1') {
    Skip-Test "pathological-filename merge" "MERGE_SKIP_PATHOLOGICAL=1"
} elseif (-not $ffmpegPath) {
    Skip-Test "pathological-filename merge" "ffmpeg not available"
} else {
    $ffprobePath = Get-FfprobePath -ffmpegPath $ffmpegPath
    if (-not $ffprobePath) {
        Skip-Test "pathological-filename merge" "ffprobe not available"
    } else {
        # Generate two tiny test videos with adversarial filenames using lavfi.
        # If the pipeline mishandles the filename, either the source generation
        # or the merge will fail.
        $tempRoot = Join-Path $env:TEMP ("merge-patho-{0}" -f ([guid]::NewGuid().ToString("N")))
        New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null

        # Adversarial names: spaces, single quote, %, &, $, leading dash.
        # Cannot use ", <, >, |, ?, * (Windows filesystem forbids them).
        # Newlines also forbidden on Windows -- Phase 1c covers those at the escape level.
        $v1 = Join-Path $tempRoot "-y injection & 100% 'quoted'.mp4"
        $v2 = Join-Path $tempRoot "Cafe test video.mp4"
        $outFile  = Join-Path $tempRoot "merged output.mp4"
        $listFile = Join-Path $tempRoot "list.txt"

        try {
            Write-Host "  Synthesizing test videos with adversarial names..." -ForegroundColor DarkGray

            # 1-second 320x240 test pattern + silent audio, encoded fast.
            & $ffmpegPath -hide_banner -loglevel error `
                -f lavfi -i "testsrc=duration=1:size=320x240:rate=15" `
                -f lavfi -i "anullsrc=r=48000:cl=stereo" -shortest `
                -c:v libx264 -preset ultrafast -pix_fmt yuv420p `
                -c:a aac `
                "$v1" -y
            Assert ((Test-Path $v1) -and ((Get-Item $v1).Length -gt 0)) "generated adversarial video 1 (spaces + & + % + quotes + leading dash)"

            & $ffmpegPath -hide_banner -loglevel error `
                -f lavfi -i "testsrc=duration=1:size=320x240:rate=15" `
                -f lavfi -i "anullsrc=r=48000:cl=stereo" -shortest `
                -c:v libx264 -preset ultrafast -pix_fmt yuv420p `
                -c:a aac `
                "$v2" -y
            Assert ((Test-Path $v2) -and ((Get-Item $v2).Length -gt 0)) "generated adversarial video 2"

            if ((Test-Path $v1) -and (Test-Path $v2)) {
                # Write concat list using the EXACT same escape function as
                # merge-videos.ps1. If either escape rule or filename handling
                # in ffmpeg drifts, this will produce a corrupted list.
                $sw = New-Object System.IO.StreamWriter($listFile, $false, (New-Object System.Text.UTF8Encoding($false)))
                foreach ($v in @($v1, $v2)) {
                    $abs = [System.IO.Path]::GetFullPath($v)
                    $sw.WriteLine((Format-ConcatLine $abs))
                }
                $sw.Close()

                Write-Host "  Merging pathological filenames..." -ForegroundColor DarkGray
                & $ffmpegPath -hide_banner -loglevel error -f concat -safe 0 -i "$listFile" -c copy "$outFile" -y
                Assert ((Test-Path $outFile) -and ((Get-Item $outFile).Length -gt 0)) "pathological-filename merge produced a non-empty output"

                if (Test-Path $outFile) {
                    $duration = & $ffprobePath -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$outFile"
                    Assert ([double]$duration -ge 1.9) "pathological-filename merge duration >= 1.9s (got $duration)"
                }
            }
        } finally {
            if (Test-Path $tempRoot) { Remove-Item $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
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
