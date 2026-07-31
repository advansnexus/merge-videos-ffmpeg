#Requires -Version 5.1
<#
.SYNOPSIS
    Integration test that dot-sources merge-videos.ps1's helper functions
    (without triggering the WinForms upload flow) and exercises them
    against real files. NOT part of the CI smoke test -- run manually
    when you want to sanity-check a change against production files.

.DESCRIPTION
    The main script's helper functions are all defined above the
    '# -- Pre-flight ------' marker. We slurp the file, take everything
    before that marker, and Invoke-Expression it. The interactive flow
    is skipped entirely.

    Env vars:
        MERGE_TEST_V1, MERGE_TEST_V2  -- paths to two real videos
                                          (defaults to the AppStore sample pair)

    Exit code:
        0 = pass, 1 = fail
#>

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent

$scriptContent = Get-Content (Join-Path $repoRoot 'merge-videos.ps1') -Raw
$marker        = '# -- Pre-flight ------'
$cut           = $scriptContent.IndexOf($marker)
if ($cut -lt 0) {
    Write-Host "Could not find pre-flight marker; script layout changed." -ForegroundColor Red
    exit 1
}

# Load only the helper definitions -- write the extracted head to a temp .ps1
# file and dot-source it. This keeps PSScriptAnalyzer happy (no Invoke-Expression)
# while still avoiding execution of the interactive WinForms flow.
$helperFile = Join-Path $env:TEMP ("mvf-integ-helpers-{0}.ps1" -f ([guid]::NewGuid().ToString('N')))
try {
    Set-Content -Path $helperFile -Value $scriptContent.Substring(0, $cut) -Encoding UTF8
    . $helperFile
} finally {
    if (Test-Path $helperFile) { Remove-Item $helperFile -Force -ErrorAction SilentlyContinue }
}

$workspace = Split-Path $repoRoot -Parent
$v1 = if ($env:MERGE_TEST_V1) { $env:MERGE_TEST_V1 } else { Join-Path $workspace "Cropping and scanning.mp4" }
$v2 = if ($env:MERGE_TEST_V2) { $env:MERGE_TEST_V2 } else { Join-Path $workspace "IBRAHIM BASIRU SCANNING.mp4" }

if (-not (Test-Path $v1) -or -not (Test-Path $v2)) {
    Write-Host "Sample videos not found at:" -ForegroundColor Yellow
    Write-Host "  $v1"
    Write-Host "  $v2"
    Write-Host "Set MERGE_TEST_V1 / MERGE_TEST_V2 to run this test."
    exit 0
}

$failed = 0

Write-Host ""
Write-Host "Integration test - real files" -ForegroundColor Cyan
Write-Host "=============================" -ForegroundColor Cyan
Write-Host ""

# --- Test Get-VideoInfo ---
Write-Host "[1] Get-VideoInfo probes both files"
$ffprobePath = $ffprobe
$i1 = Get-VideoInfo $ffprobePath $v1
$i2 = Get-VideoInfo $ffprobePath $v2
if ($i1.Duration -gt 0 -and $i2.Duration -gt 0) {
    Write-Host "  [PASS] both durations detected" -ForegroundColor Green
    Write-Host ("         v1: {0} {1}x{2} dur={3:F1}s hasAudio={4}" -f $i1.VideoCodec, $i1.Width, $i1.Height, $i1.Duration, $i1.HasAudio) -ForegroundColor DarkGray
    Write-Host ("         v2: {0} {1}x{2} dur={3:F1}s hasAudio={4}" -f $i2.VideoCodec, $i2.Width, $i2.Height, $i2.Duration, $i2.HasAudio) -ForegroundColor DarkGray
} else {
    Write-Host "  [FAIL] one or both durations were zero" -ForegroundColor Red
    $failed++
}

# --- Test Format-Duration ---
Write-Host ""
Write-Host "[2] Format-Duration"
$cases = @{
    5     = '0m05s'
    65    = '1m05s'
    3725  = '1h02m05s'
}
foreach ($k in $cases.Keys) {
    $got = Format-Duration $k
    if ($got -eq $cases[$k]) {
        Write-Host ("  [PASS] {0}s -> {1}" -f $k, $got) -ForegroundColor Green
    } else {
        Write-Host ("  [FAIL] {0}s -> {1} (expected {2})" -f $k, $got, $cases[$k]) -ForegroundColor Red
        $failed++
    }
}

# --- Test Invoke-FfmpegWithProgress against a real merge ---
Write-Host ""
Write-Host "[3] Invoke-FfmpegWithProgress with real merge"
$listFile = Join-Path $env:TEMP ("mvf-integ-{0}.txt" -f ([guid]::NewGuid().ToString('N')))
$outFile  = Join-Path $env:TEMP ("mvf-integ-{0}.mp4" -f ([guid]::NewGuid().ToString('N')))
try {
    $sw = New-Object System.IO.StreamWriter($listFile, $false, (New-Object System.Text.UTF8Encoding($false)))
    foreach ($v in @($v1, $v2)) {
        $esc = [System.IO.Path]::GetFullPath($v) -replace "'", "'\''"
        $sw.WriteLine("file '$esc'")
    }
    $sw.Close()

    $totalDur = $i1.Duration + $i2.Duration
    $mergeArgs = @('-f', 'concat', '-safe', '0', '-i', $listFile, '-c', 'copy', $outFile, '-y')
    $ec = Invoke-FfmpegWithProgress -ffmpegPath $ffmpeg -arguments $mergeArgs -totalDurationSec $totalDur

    if ($ec -eq 0 -and (Test-Path $outFile) -and (Get-Item $outFile).Length -gt 0) {
        $sz = [math]::Round((Get-Item $outFile).Length / 1MB, 2)
        $outDur = & $ffprobePath -v error -show_entries format=duration -of csv=p=0 "$outFile"
        Write-Host ("  [PASS] merge succeeded: {0} MB, {1:F1}s duration" -f $sz, [double]$outDur) -ForegroundColor Green
    } else {
        Write-Host "  [FAIL] merge failed or produced empty file" -ForegroundColor Red
        $failed++
    }
} finally {
    if (Test-Path $listFile) { Remove-Item $listFile -Force -ErrorAction SilentlyContinue }
    if (Test-Path $outFile)  { Remove-Item $outFile  -Force -ErrorAction SilentlyContinue }
}

Write-Host ""
if ($failed -eq 0) {
    Write-Host "Integration test PASSED" -ForegroundColor Green
    exit 0
} else {
    Write-Host "Integration test FAILED ($failed check(s) failed)" -ForegroundColor Red
    exit 1
}
