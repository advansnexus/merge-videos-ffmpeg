#Requires -Version 5.1
<#
.SYNOPSIS
    Merge two or more videos into one, in the order the user selects them.
    Uses a simple upload-style GUI: Video 1 -> Video 2 -> "Add another?" -> ...
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$ffmpeg  = "C:\Users\nexus\AppData\Local\Microsoft\WinGet\Packages\Gyan.FFmpeg_Microsoft.Winget.Source_8wekyb3d8bbwe\ffmpeg-8.1.1-full_build\bin\ffmpeg.exe"
$ffprobe = if ($ffmpeg) { Join-Path (Split-Path $ffmpeg -Parent) "ffprobe.exe" } else { $null }

function Wait-Keypress {
    Write-Host ""
    Write-Host "Press any key to close..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}

function Show-ErrorBox($msg) {
    [System.Windows.Forms.MessageBox]::Show($msg, "Merge Videos - Error",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
}

function Select-VideoFile($number, $initialDir) {
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Title = "Upload Video $number"
    $dlg.Filter = "MP4 Videos (*.mp4)|*.mp4|All Video Files (*.mp4;*.mov;*.mkv;*.avi;*.webm)|*.mp4;*.mov;*.mkv;*.avi;*.webm|All Files (*.*)|*.*"
    $dlg.Multiselect = $false
    if ($initialDir -and (Test-Path $initialDir)) { $dlg.InitialDirectory = $initialDir }
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        return $dlg.FileName
    }
    return $null
}

function Confirm-AddMore($currentCount) {
    $result = [System.Windows.Forms.MessageBox]::Show(
        "You have added $currentCount videos so far.`n`nAdd another video?",
        "Merge Videos",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question)
    return ($result -eq [System.Windows.Forms.DialogResult]::Yes)
}

function Get-VideoInfo($ffprobePath, $videoPath) {
    # Returns @{ Duration = <sec>; HasAudio = <bool>; VideoCodec = <str>; Width = <int>; Height = <int>; Fps = <str> }
    # Falls back to zero/empty values on failure so the caller can still proceed.
    $info = @{ Duration = 0.0; HasAudio = $false; VideoCodec = ""; Width = 0; Height = 0; Fps = "" }
    if (-not $ffprobePath -or -not (Test-Path $ffprobePath) -or -not (Test-Path $videoPath)) { return $info }

    try {
        $dur = & $ffprobePath -v error -show_entries format=duration -of csv=p=0 "$videoPath" 2>$null
        if ($dur) { $info.Duration = [double]$dur }

        $vStream = & $ffprobePath -v error -select_streams v:0 -show_entries stream=codec_name,width,height,r_frame_rate -of csv=p=0 "$videoPath" 2>$null
        if ($vStream) {
            $parts = $vStream -split ','
            if ($parts.Length -ge 1) { $info.VideoCodec = $parts[0] }
            if ($parts.Length -ge 2) { $info.Width      = [int]$parts[1] }
            if ($parts.Length -ge 3) { $info.Height     = [int]$parts[2] }
            if ($parts.Length -ge 4) { $info.Fps        = $parts[3] }
        }

        $aStream = & $ffprobePath -v error -select_streams a:0 -show_entries stream=codec_type -of csv=p=0 "$videoPath" 2>$null
        $info.HasAudio = [bool]$aStream
    } catch {
        # ffprobe missing or file unreadable -- return defaults; caller still merges best-effort.
        Write-Debug "Get-VideoInfo: ffprobe failed on '$videoPath': $($_.Exception.Message)"
    }
    return $info
}

function Format-Duration($seconds) {
    if ($seconds -le 0) { return "?" }
    $ts = [TimeSpan]::FromSeconds([double]$seconds)
    if ($ts.TotalHours -ge 1) {
        return ("{0}h{1:D2}m{2:D2}s" -f [int]$ts.TotalHours, $ts.Minutes, $ts.Seconds)
    }
    return ("{0}m{1:D2}s" -f [int]$ts.TotalMinutes, $ts.Seconds)
}

function Confirm-OrderWithSummary($files, $infos) {
    $list = ""
    $totalDur = 0.0
    $anyMissingAudio = $false
    for ($i = 0; $i -lt $files.Count; $i++) {
        $info    = $infos[$i]
        $codec   = if ($info.VideoCodec) { $info.VideoCodec } else { "?" }
        $res     = if ($info.Width -and $info.Height) { "$($info.Width)x$($info.Height)" } else { "?" }
        $dur     = Format-Duration $info.Duration
        $audio   = if ($info.HasAudio) { "audio" } else { "SILENT" }
        if (-not $info.HasAudio) { $anyMissingAudio = $true }
        $totalDur += [double]$info.Duration
        $list += ("  {0}. {1}`r`n     [{2} {3} {4} {5}]`r`n" -f ($i + 1), (Split-Path $files[$i] -Leaf), $codec, $res, $dur, $audio)
    }
    $totalStr = Format-Duration $totalDur
    $note = ""
    if ($anyMissingAudio) {
        $note = "`r`nNote: at least one input has no audio track. Silent audio will be`r`ninjected so the merge succeeds (forces re-encode path)."
    }
    $msg = "Videos will be merged in this order:`r`n`r`n$list`r`nEstimated total duration: $totalStr$note`r`n`r`nProceed?"
    $result = [System.Windows.Forms.MessageBox]::Show($msg, "Confirm Merge Order",
        [System.Windows.Forms.MessageBoxButtons]::OKCancel,
        [System.Windows.Forms.MessageBoxIcon]::Information)
    return ($result -eq [System.Windows.Forms.DialogResult]::OK)
}

function Invoke-FfmpegWithProgress {
    <#
    .DESCRIPTION
        Runs ffmpeg with -progress pipe:1 -nostats, parses key=value progress
        lines to render a simple percentage bar based on $totalDurationSec.
        stderr passes through to the console (so real errors are still visible).
        Returns the process exit code.
    #>
    param(
        [string]$ffmpegPath,
        [string[]]$arguments,
        [double]$totalDurationSec
    )

    $allArgs = @('-hide_banner', '-loglevel', 'error', '-progress', 'pipe:1', '-nostats') + $arguments

    # ffmpeg writes progress key=value lines to stdout when -progress pipe:1
    # is set; real errors still go to stderr and pass through to the console
    # (we do NOT redirect stderr). PowerShell's & invocation handles argument
    # quoting for native binaries automatically.
    $lastPct = -1
    & $ffmpegPath @allArgs | ForEach-Object {
        $line = "$_"
        if ($line -match '^out_time_ms=(\d+)') {
            $outSec = [int64]$Matches[1] / 1000000.0
            if ($totalDurationSec -gt 0) {
                $pct = [math]::Min(100, [math]::Floor(($outSec / $totalDurationSec) * 100))
                if ($pct -ne $lastPct) {
                    $bar = ('#' * ([int]($pct / 2))).PadRight(50, '-')
                    Write-Host ("`r  [{0}] {1,3}%  ({2} / {3})" -f $bar, $pct, (Format-Duration $outSec), (Format-Duration $totalDurationSec)) -NoNewline
                    $lastPct = $pct
                }
            }
        } elseif ($line -match '^progress=end') {
            if ($lastPct -ge 0) { Write-Host "" }
        }
    }
    return $LASTEXITCODE
}

function Select-OutputFile($initialDir, $defaultName) {
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Title = "Save merged video as..."
    $dlg.Filter = "MP4 Video (*.mp4)|*.mp4"
    $dlg.DefaultExt = "mp4"
    $dlg.FileName = $defaultName
    if ($initialDir -and (Test-Path $initialDir)) { $dlg.InitialDirectory = $initialDir }
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        return $dlg.FileName
    }
    return $null
}

# -- Pre-flight ------------------------------------------------------------
if (-not (Test-Path $ffmpeg)) {
    Show-ErrorBox "FFmpeg not found at:`n$ffmpeg`n`nRun Install.bat from the merge-videos-ffmpeg folder first."
    Write-Host "ERROR: FFmpeg not found. Run Install.bat first." -ForegroundColor Red
    Wait-Keypress
    exit 1
}

Write-Host ""
Write-Host "Merge Videos (FFmpeg)" -ForegroundColor Cyan
Write-Host "Upload videos in the order you want them joined."
Write-Host ""

# -- Step 1: Video 1 -------------------------------------------------------
$videos  = @()
$lastDir = $null

$v = Select-VideoFile 1 $null
if (-not $v) {
    Write-Host "Cancelled - no video 1 selected." -ForegroundColor Yellow
    Wait-Keypress; exit 0
}
$videos += $v
$lastDir = Split-Path $v -Parent
Write-Host ("Video 1: {0}" -f (Split-Path $v -Leaf))

# -- Step 2: Video 2 -------------------------------------------------------
$v = Select-VideoFile 2 $lastDir
if (-not $v) {
    Write-Host "Cancelled - no video 2 selected." -ForegroundColor Yellow
    Wait-Keypress; exit 0
}
$videos += $v
$lastDir = Split-Path $v -Parent
Write-Host ("Video 2: {0}" -f (Split-Path $v -Leaf))

# -- Step 3: Loop - "Add another?" ----------------------------------------
while (Confirm-AddMore $videos.Count) {
    $n = $videos.Count + 1
    $v = Select-VideoFile $n $lastDir
    if (-not $v) {
        Write-Host ("Skipped video {0}. Continuing with {1} videos." -f $n, $videos.Count) -ForegroundColor Yellow
        break
    }
    $videos += $v
    $lastDir = Split-Path $v -Parent
    Write-Host ("Video {0}: {1}" -f $n, (Split-Path $v -Leaf))
}

# -- Pre-flight probe (ffprobe metadata for each input) -------------------
Write-Host ""
Write-Host "Analyzing videos..."
$infos = @()
foreach ($v in $videos) {
    $infos += ,(Get-VideoInfo $ffprobe $v)
}
$anyMissingAudio = ($infos | Where-Object { -not $_.HasAudio }).Count -gt 0

# -- Confirm order (with per-input summary) -------------------------------
if (-not (Confirm-OrderWithSummary $videos $infos)) {
    Write-Host "Cancelled by user." -ForegroundColor Yellow
    Wait-Keypress; exit 0
}

# -- Pick output ----------------------------------------------------------
$firstBase   = [System.IO.Path]::GetFileNameWithoutExtension($videos[0])
$defaultName = "${firstBase}_merged.mp4"
$outputFile  = Select-OutputFile $lastDir $defaultName
if (-not $outputFile) {
    Write-Host "Cancelled - no output file chosen." -ForegroundColor Yellow
    Wait-Keypress; exit 0
}
$outputFile = [System.IO.Path]::GetFullPath($outputFile)

# Reject output that matches any input (would corrupt the source)
foreach ($src in $videos) {
    if ([System.IO.Path]::GetFullPath($src) -ieq $outputFile) {
        Show-ErrorBox "Output file cannot be the same as an input video."
        Write-Host "ERROR: Output file matches an input video. Aborting." -ForegroundColor Red
        Wait-Keypress; exit 1
    }
}

# -- Write concat list file (temp) ----------------------------------------
$listFile = Join-Path $env:TEMP ("merge-videos-{0}.txt" -f ([guid]::NewGuid().ToString("N")))
try {
    $sw = New-Object System.IO.StreamWriter($listFile, $false, (New-Object System.Text.UTF8Encoding($false)))
    foreach ($v in $videos) {
        # Escape single quotes for the ffmpeg concat demuxer parser
        $escaped = $v -replace "'", "'\''"
        $sw.WriteLine("file '$escaped'")
    }
    $sw.Close()

    $totalMb = 0
    foreach ($v in $videos) { $totalMb += (Get-Item $v).Length / 1MB }
    $totalMb = [math]::Round($totalMb, 2)

    $totalDurSec = 0.0
    foreach ($info in $infos) { $totalDurSec += [double]$info.Duration }

    Write-Host ""
    Write-Host ("Inputs : {0} videos, {1} MB total, ~{2} duration" -f $videos.Count, $totalMb, (Format-Duration $totalDurSec))
    Write-Host ("Output : {0}" -f (Split-Path $outputFile -Leaf))
    Write-Host ""

    $streamCopyExit = -1
    if (-not $anyMissingAudio) {
        # Stream copy is only meaningful when all inputs have matching streams.
        # Skip straight to re-encode when at least one input has no audio,
        # otherwise ffmpeg would silently drop the audio track for that segment.
        Write-Host "Attempting fast stream-copy merge (no re-encoding)..."
        Write-Host ""
        $streamCopyArgs = @('-f', 'concat', '-safe', '0', '-i', $listFile, '-c', 'copy', $outputFile, '-y')
        $streamCopyExit = Invoke-FfmpegWithProgress -ffmpegPath $ffmpeg -arguments $streamCopyArgs -totalDurationSec $totalDurSec
    } else {
        Write-Host "One or more inputs have no audio track - skipping stream copy, going straight to re-encode." -ForegroundColor Yellow
        Write-Host ""
    }

    if ($streamCopyExit -ne 0) {
        if ($streamCopyExit -gt 0) {
            Write-Host ""
            Write-Host "Stream copy failed - inputs have mismatched codecs, resolutions, or framerates." -ForegroundColor Yellow
        }
        Write-Host "Re-encoding at H.264 CRF 23 (may take a few minutes)..." -ForegroundColor Yellow
        Write-Host ""

        # Re-encode fallback with silent-audio synthesis for audio-less inputs.
        # Filter graph:
        #   For each input i:
        #     If it has audio: use [i:v:0][i:a:0]
        #     Else:            declare "anullsrc=r=48000:cl=stereo:d=<dur>[silent_i]",
        #                      then use [i:v:0][silent_i]
        #   Then: <pairs> concat=n=N:v=1:a=1[outv][outa]
        $inputArgs = @()
        foreach ($src in $videos) { $inputArgs += @("-i", $src) }

        $n = $videos.Count
        $silentDecls = @()
        $concatChain = ""
        for ($i = 0; $i -lt $n; $i++) {
            if ($infos[$i].HasAudio) {
                $concatChain += "[$i`:v:0][$i`:a:0]"
            } else {
                # Use max(1, actual) as a floor so zero-duration probe failures still produce SOME audio.
                $dur = [math]::Max(1.0, [double]$infos[$i].Duration)
                $silentDecls += ("anullsrc=r=48000:cl=stereo:d={0}[silent{1}]" -f $dur, $i)
                $concatChain += "[$i`:v:0][silent$i]"
            }
        }
        $prefix = if ($silentDecls.Count -gt 0) { ($silentDecls -join ';') + ';' } else { '' }
        $filterComplex = "$prefix$concatChain" + "concat=n=$n`:v=1:a=1[outv][outa]"

        $reencodeArgs = @()
        $reencodeArgs += $inputArgs
        $reencodeArgs += @(
            '-filter_complex', $filterComplex,
            '-map', '[outv]', '-map', '[outa]',
            '-c:v', 'libx264', '-crf', '23', '-preset', 'medium',
            '-c:a', 'aac', '-b:a', '192k',
            $outputFile, '-y'
        )
        $finalExit = Invoke-FfmpegWithProgress -ffmpegPath $ffmpeg -arguments $reencodeArgs -totalDurationSec $totalDurSec
    } else {
        $finalExit = $streamCopyExit
    }

    Write-Host ""
    if ($finalExit -eq 0 -and (Test-Path $outputFile) -and ((Get-Item $outputFile).Length -gt 0)) {
        $newSize = [math]::Round((Get-Item $outputFile).Length / 1MB, 2)
        Write-Host "SUCCESS!" -ForegroundColor Green
        Write-Host ""
        Write-Host ("  Merged     : {0} videos" -f $videos.Count)
        Write-Host ("  Input size : {0} MB (sum)" -f $totalMb)
        Write-Host ("  Output size: {0} MB" -f $newSize)
        Write-Host ""
        Write-Host ("  Saved to: {0}" -f $outputFile) -ForegroundColor Green
    } else {
        Write-Host "ERROR: Merge failed. See messages above." -ForegroundColor Red
    }
} finally {
    if (Test-Path $listFile) { Remove-Item $listFile -Force -ErrorAction SilentlyContinue }
}

Wait-Keypress
