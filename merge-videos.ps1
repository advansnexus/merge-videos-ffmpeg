#Requires -Version 5.1
<#
.SYNOPSIS
    Merge two or more videos into one, in the order the user selects them.
    Uses a simple upload-style GUI: Video 1 -> Video 2 -> "Add another?" -> ...
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$ffmpeg = "C:\Users\nexus\AppData\Local\Microsoft\WinGet\Packages\Gyan.FFmpeg_Microsoft.Winget.Source_8wekyb3d8bbwe\ffmpeg-8.1.1-full_build\bin\ffmpeg.exe"

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

function Confirm-Order($files) {
    $list = ""
    for ($i = 0; $i -lt $files.Count; $i++) {
        $list += ("  {0}. {1}`r`n" -f ($i + 1), (Split-Path $files[$i] -Leaf))
    }
    $msg = "Videos will be merged in this order:`r`n`r`n$list`r`nProceed?"
    $result = [System.Windows.Forms.MessageBox]::Show($msg, "Confirm Merge Order",
        [System.Windows.Forms.MessageBoxButtons]::OKCancel,
        [System.Windows.Forms.MessageBoxIcon]::Information)
    return ($result -eq [System.Windows.Forms.DialogResult]::OK)
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

# -- Confirm order --------------------------------------------------------
if (-not (Confirm-Order $videos)) {
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

    Write-Host ""
    Write-Host ("Inputs : {0} videos, {1} MB total" -f $videos.Count, $totalMb)
    Write-Host ("Output : {0}" -f (Split-Path $outputFile -Leaf))
    Write-Host ""
    Write-Host "Attempting fast stream-copy merge (no re-encoding)..."
    Write-Host ""

    & $ffmpeg -hide_banner -f concat -safe 0 -i "$listFile" -c copy "$outputFile" -y
    $streamCopyExit = $LASTEXITCODE

    if ($streamCopyExit -ne 0) {
        Write-Host ""
        Write-Host "Stream copy failed - inputs have mismatched codecs, resolutions, or framerates." -ForegroundColor Yellow
        Write-Host "Retrying with re-encoding at H.264 CRF 23 (may take a few minutes)..." -ForegroundColor Yellow
        Write-Host ""

        # Build: -i v1 -i v2 -i v3 -filter_complex "[0:v:0][0:a:0][1:v:0][1:a:0]...concat=n=N:v=1:a=1[outv][outa]"
        $inputArgs = @()
        foreach ($src in $videos) { $inputArgs += @("-i", $src) }

        $n = $videos.Count
        $streams = ""
        for ($i = 0; $i -lt $n; $i++) { $streams += "[$i`:v:0][$i`:a:0]" }
        $filterComplex = "$streams" + "concat=n=$n`:v=1:a=1[outv][outa]"

        & $ffmpeg -hide_banner @inputArgs -filter_complex $filterComplex `
            -map "[outv]" -map "[outa]" `
            -c:v libx264 -crf 23 -preset medium `
            -c:a aac -b:a 192k `
            "$outputFile" -y
    }

    Write-Host ""
    if ($LASTEXITCODE -eq 0 -and (Test-Path $outputFile)) {
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
