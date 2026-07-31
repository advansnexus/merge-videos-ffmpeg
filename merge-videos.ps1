#Requires -Version 5.1
<#
.SYNOPSIS
    Merge Videos (FFmpeg) - modern single-window WPF GUI.

.DESCRIPTION
    Persistent WPF window that lets the user add videos in order, review
    ffprobe-detected metadata (codec, resolution, duration, audio presence),
    pick an output path, and start a merge with a live progress bar and
    green-on-black log pane. Modelled on the Advans Signal design language
    (dark theme, cyan accent, orange danger, teal confirm).

    Handles both the fast stream-copy path (matching codecs) and the
    re-encode fallback with silent-audio injection for inputs that lack
    an audio track.

    STA thread required for WPF -- MergeVideos.bat and the installed
    shortcut both pass -STA.

    If the WPF window fails to start for any reason (rare -- e.g. WPF
    missing on Windows Server Core), the classic script is preserved as
    merge-videos-cli.ps1 in the same folder as a fallback.
#>

# --------------------------------------------------------- assembly loads ---
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms   # for OpenFileDialog / SaveFileDialog
Add-Type -AssemblyName System.Drawing

# --------------------------------------------------------- ffmpeg location ---
$ffmpeg  = "C:\Users\nexus\AppData\Local\Microsoft\WinGet\Packages\Gyan.FFmpeg_Microsoft.Winget.Source_8wekyb3d8bbwe\ffmpeg-8.1.1-full_build\bin\ffmpeg.exe"
$ffprobe = if ($ffmpeg) { Join-Path (Split-Path $ffmpeg -Parent) "ffprobe.exe" } else { $null }

# --------------------------------------------------------- helper functions ---
function Get-VideoInfo($ffprobePath, $videoPath) {
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
        Write-Debug "Get-VideoInfo failed on '$videoPath': $($_.Exception.Message)"
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

function Format-VideoRow($index, $path, $info) {
    $codec = if ($info.VideoCodec) { $info.VideoCodec } else { "?" }
    $res   = if ($info.Width -and $info.Height) { "$($info.Width)x$($info.Height)" } else { "?" }
    $dur   = Format-Duration $info.Duration
    $audio = if ($info.HasAudio) { "audio" } else { "SILENT" }
    return ("{0}. {1}    [{2} {3} {4} {5}]" -f $index, (Split-Path $path -Leaf), $codec, $res, $dur, $audio)
}

# --------------------------------------------------------- XAML ---
$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Merge Videos (FFmpeg) - Advans"
        Height="680" Width="1020" Background="#1A1A1A" Foreground="#FFFFFF"
        WindowStartupLocation="CenterScreen" ResizeMode="CanResize">
    <Window.Resources>
        <Style TargetType="Label">
            <Setter Property="Foreground" Value="#E0E0E0"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="Margin" Value="0,2,0,2"/>
        </Style>
        <Style TargetType="TextBox">
            <Setter Property="Background" Value="#2D2D2D"/>
            <Setter Property="Foreground" Value="#FFFFFF"/>
            <Setter Property="BorderBrush" Value="#404040"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="5"/>
            <Setter Property="Margin" Value="0,2,0,8"/>
        </Style>
        <Style TargetType="Button">
            <Setter Property="Background" Value="#007ACC"/>
            <Setter Property="Foreground" Value="#FFFFFF"/>
            <Setter Property="FontWeight" Value="Bold"/>
            <Setter Property="Padding" Value="8,5,8,5"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Margin" Value="3"/>
        </Style>
        <Style TargetType="ListBox">
            <Setter Property="Background" Value="#2D2D2D"/>
            <Setter Property="Foreground" Value="#FFFFFF"/>
            <Setter Property="BorderBrush" Value="#404040"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="FontFamily" Value="Consolas"/>
            <Setter Property="FontSize" Value="12"/>
        </Style>
    </Window.Resources>

    <Grid Margin="15">
        <Grid.ColumnDefinitions>
            <ColumnDefinition Width="440"/>
            <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>

        <!-- LEFT: Setup -->
        <ScrollViewer Grid.Column="0" VerticalScrollBarVisibility="Auto" Padding="0,0,10,0">
            <StackPanel>
                <TextBlock Text="Merge Setup" FontSize="18" FontWeight="Bold" Foreground="#00BCF2" Margin="0,0,0,15"/>

                <Label Content="Videos to merge (order = play order):"/>
                <ListBox x:Name="lstVideos" Height="220" SelectionMode="Single"/>

                <UniformGrid Columns="4" Margin="0,5,0,10">
                    <Button x:Name="btnAdd"    Content="Add Video..." Background="#008272"/>
                    <Button x:Name="btnRemove" Content="Remove"       Background="#3A3A3A"/>
                    <Button x:Name="btnUp"     Content="Move Up"      Background="#3A3A3A"/>
                    <Button x:Name="btnDown"   Content="Move Down"    Background="#3A3A3A"/>
                </UniformGrid>

                <Separator Background="#333333" Margin="0,10,0,10"/>

                <Label Content="Output file:"/>
                <TextBox x:Name="txtOutput" IsReadOnly="True" Text="(none chosen)" Background="#252525"/>
                <Button x:Name="btnChooseOutput" Content="Choose output location..." Background="#3A3A3A" HorizontalAlignment="Left" Margin="0,0,0,15"/>

                <Separator Background="#333333" Margin="0,10,0,10"/>

                <Button x:Name="btnMerge" Content="Start Merge" Background="#D83B01" FontSize="14" Padding="10,10,10,10" IsEnabled="False"/>
                <Button x:Name="btnCancel" Content="Cancel Running Merge" Background="#5A1A1A" IsEnabled="False" Margin="3,10,3,3"/>
            </StackPanel>
        </ScrollViewer>

        <!-- RIGHT: Summary + Progress + Log -->
        <Grid Grid.Column="1" Margin="15,0,0,0">
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
            </Grid.RowDefinitions>

            <TextBlock Grid.Row="0" Text="Merge Details" FontSize="18" FontWeight="Bold" Foreground="#00BCF2" Margin="0,0,0,15"/>

            <Border Grid.Row="1" Background="#252525" BorderBrush="#3A3A3A" BorderThickness="1" CornerRadius="4" Padding="10" Margin="0,0,0,10">
                <StackPanel>
                    <TextBlock x:Name="txtSummaryHead" Text="No videos added yet" Foreground="#E0E0E0" FontWeight="Bold" Margin="0,0,0,5"/>
                    <TextBlock x:Name="txtSummaryBody" Text="Click 'Add Video...' to begin." Foreground="#B0B0B0" TextWrapping="Wrap"/>
                    <TextBlock x:Name="txtSummaryWarn" Text="" Foreground="#F0A030" TextWrapping="Wrap" Margin="0,5,0,0"/>
                </StackPanel>
            </Border>

            <StackPanel Grid.Row="2" Margin="0,0,0,10">
                <Grid>
                    <TextBlock x:Name="txtProgressLabel" Text="System Idle" Foreground="#E0E0E0" FontWeight="SemiBold"/>
                    <TextBlock x:Name="txtProgressPct" Text="0%" Foreground="#E0E0E0" FontWeight="SemiBold" HorizontalAlignment="Right"/>
                </Grid>
                <ProgressBar x:Name="progressMerge" Height="15" Margin="0,5,0,0" Background="#2D2D2D" Foreground="#00BCF2" BorderThickness="0"/>
            </StackPanel>

            <Border Grid.Row="3" Background="#111111" BorderBrush="#3A3A3A" BorderThickness="1" CornerRadius="4">
                <TextBox x:Name="txtLogs" Background="Transparent" Foreground="#00FF00" BorderThickness="0"
                         FontFamily="Consolas" FontSize="11"
                         IsReadOnly="True" AcceptsReturn="True" TextWrapping="Wrap"
                         VerticalScrollBarVisibility="Auto" Margin="5"/>
            </Border>
        </Grid>
    </Grid>
</Window>
"@

# --------------------------------------------------------- load window ---
$reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($xaml))
$window = [System.Windows.Markup.XamlReader]::Load($reader)

$lstVideos        = $window.FindName("lstVideos")
$btnAdd           = $window.FindName("btnAdd")
$btnRemove        = $window.FindName("btnRemove")
$btnUp            = $window.FindName("btnUp")
$btnDown          = $window.FindName("btnDown")
$txtOutput        = $window.FindName("txtOutput")
$btnChooseOutput  = $window.FindName("btnChooseOutput")
$btnMerge         = $window.FindName("btnMerge")
$btnCancel        = $window.FindName("btnCancel")
$txtSummaryHead   = $window.FindName("txtSummaryHead")
$txtSummaryBody   = $window.FindName("txtSummaryBody")
$txtSummaryWarn   = $window.FindName("txtSummaryWarn")
$txtProgressLabel = $window.FindName("txtProgressLabel")
$txtProgressPct   = $window.FindName("txtProgressPct")
$progressMerge    = $window.FindName("progressMerge")
$txtLogs          = $window.FindName("txtLogs")

# --------------------------------------------------------- shared state ---
$script:videos          = @()    # array of full paths in merge order
$script:infos           = @()    # parallel array of Get-VideoInfo hashtables
$script:outputPath      = $null
$script:cancelRequested = $false
$script:currentProcess  = $null

function Add-LogEntry {
    param([string]$message)
    $stamp = (Get-Date).ToString("HH:mm:ss")
    $txtLogs.AppendText("[$stamp] $message`r`n")
    $txtLogs.ScrollToEnd()
    [System.Windows.Forms.Application]::DoEvents()
}

function Update-Summary {
    if ($script:videos.Count -eq 0) {
        $txtSummaryHead.Text = "No videos added yet"
        $txtSummaryBody.Text = "Click 'Add Video...' to begin."
        $txtSummaryWarn.Text = ""
        return
    }

    $totalDur = 0.0
    $totalMb  = 0.0
    $anyMissingAudio = $false
    foreach ($i in 0..($script:videos.Count - 1)) {
        $totalDur += [double]$script:infos[$i].Duration
        $totalMb  += (Get-Item $script:videos[$i]).Length / 1MB
        if (-not $script:infos[$i].HasAudio) { $anyMissingAudio = $true }
    }

    $txtSummaryHead.Text = "{0} videos, {1} total, {2:N1} MB combined" -f $script:videos.Count, (Format-Duration $totalDur), $totalMb

    $resolutions = @($script:infos | ForEach-Object { "$($_.Width)x$($_.Height)" } | Sort-Object -Unique)
    $codecs      = @($script:infos | ForEach-Object { $_.VideoCodec } | Sort-Object -Unique)
    $body = "Codecs: $($codecs -join ', ')`nResolutions: $($resolutions -join ', ')"
    if ($resolutions.Count -eq 1 -and $codecs.Count -eq 1 -and -not $anyMissingAudio) {
        $body += "`nAll inputs match -- fast stream-copy path will be used."
    } else {
        $body += "`nInputs differ -- H.264 CRF 23 re-encode path will be used (slower)."
    }
    $txtSummaryBody.Text = $body

    if ($anyMissingAudio) {
        $txtSummaryWarn.Text = "Warning: at least one input has no audio track. Silent audio will be injected so the merge succeeds."
    } else {
        $txtSummaryWarn.Text = ""
    }
}

function Show-VideoList {
    $selectedIndex = $lstVideos.SelectedIndex
    $lstVideos.Items.Clear()
    for ($i = 0; $i -lt $script:videos.Count; $i++) {
        $lstVideos.Items.Add((Format-VideoRow ($i + 1) $script:videos[$i] $script:infos[$i])) | Out-Null
    }
    if ($selectedIndex -ge 0 -and $selectedIndex -lt $lstVideos.Items.Count) {
        $lstVideos.SelectedIndex = $selectedIndex
    }
    Update-Summary
    Update-MergeButtonState
}

function Update-MergeButtonState {
    $btnMerge.IsEnabled = ($script:videos.Count -ge 2) -and $script:outputPath
}

# --------------------------------------------------------- pre-flight ---
if (-not (Test-Path $ffmpeg)) {
    [System.Windows.MessageBox]::Show(
        "FFmpeg not found at:`n$ffmpeg`n`nRun Install.bat from the merge-videos-ffmpeg folder first.",
        "Merge Videos - Error",
        [System.Windows.MessageBoxButton]::OK,
        [System.Windows.MessageBoxImage]::Error) | Out-Null
    exit 1
}

# --------------------------------------------------------- event wiring ---
$btnAdd.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Title = "Add video(s) to the merge queue"
    $dlg.Filter = "MP4 Videos (*.mp4)|*.mp4|All Video Files (*.mp4;*.mov;*.mkv;*.avi;*.webm)|*.mp4;*.mov;*.mkv;*.avi;*.webm|All Files (*.*)|*.*"
    $dlg.Multiselect = $true
    if ($script:videos.Count -gt 0) {
        $lastDir = Split-Path $script:videos[-1] -Parent
        if (Test-Path $lastDir) { $dlg.InitialDirectory = $lastDir }
    }
    if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }

    foreach ($f in $dlg.FileNames) {
        Add-LogEntry "Probing $(Split-Path $f -Leaf)..."
        $script:videos += $f
        $script:infos  += ,(Get-VideoInfo $ffprobe $f)
    }
    Show-VideoList
    Add-LogEntry "Queue now has $($script:videos.Count) videos."
})

# Helpers used by Remove / Up / Down click handlers.
function Remove-At($idx) {
    if ($idx -lt 0 -or $idx -ge $script:videos.Count) { return }
    $newV = @(); $newI = @()
    for ($i = 0; $i -lt $script:videos.Count; $i++) {
        if ($i -ne $idx) { $newV += $script:videos[$i]; $newI += $script:infos[$i] }
    }
    $script:videos = $newV
    $script:infos  = $newI
}
function Invoke-Swap($a, $b) {
    if ($a -lt 0 -or $b -lt 0 -or $a -ge $script:videos.Count -or $b -ge $script:videos.Count) { return }
    $tv = $script:videos[$a]; $script:videos[$a] = $script:videos[$b]; $script:videos[$b] = $tv
    $ti = $script:infos[$a];  $script:infos[$a]  = $script:infos[$b];  $script:infos[$b]  = $ti
}

$btnRemove.Add_Click({
    $idx = $lstVideos.SelectedIndex
    if ($idx -lt 0) { Add-LogEntry "Select a video first."; return }
    $removed = Split-Path $script:videos[$idx] -Leaf
    Remove-At $idx
    Show-VideoList
    Add-LogEntry "Removed: $removed"
})

$btnUp.Add_Click({
    $idx = $lstVideos.SelectedIndex
    if ($idx -le 0) { return }
    Invoke-Swap $idx ($idx - 1)
    Show-VideoList
    $lstVideos.SelectedIndex = $idx - 1
})

$btnDown.Add_Click({
    $idx = $lstVideos.SelectedIndex
    if ($idx -lt 0 -or $idx -ge ($script:videos.Count - 1)) { return }
    Invoke-Swap $idx ($idx + 1)
    Show-VideoList
    $lstVideos.SelectedIndex = $idx + 1
})

$btnChooseOutput.Add_Click({
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Title = "Save merged video as..."
    $dlg.Filter = "MP4 Video (*.mp4)|*.mp4"
    $dlg.DefaultExt = "mp4"
    if ($script:videos.Count -gt 0) {
        $firstBase = [System.IO.Path]::GetFileNameWithoutExtension($script:videos[0])
        $dlg.FileName = "${firstBase}_merged.mp4"
        $lastDir = Split-Path $script:videos[0] -Parent
        if (Test-Path $lastDir) { $dlg.InitialDirectory = $lastDir }
    } else {
        $dlg.FileName = "merged.mp4"
    }
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $script:outputPath = [System.IO.Path]::GetFullPath($dlg.FileName)
        $txtOutput.Text    = $script:outputPath
        Update-MergeButtonState
        Add-LogEntry "Output set to: $(Split-Path $script:outputPath -Leaf)"
    }
})

$btnCancel.Add_Click({
    $script:cancelRequested = $true
    if ($script:currentProcess -and -not $script:currentProcess.HasExited) {
        try { $script:currentProcess.Kill() } catch { Write-Debug "Kill: $($_.Exception.Message)" }
    }
    Add-LogEntry "Cancel requested."
})

function Start-Merge {
    # Guard against self-overwrite: refuse if the chosen output is any input.
    foreach ($src in $script:videos) {
        if ([System.IO.Path]::GetFullPath($src) -ieq $script:outputPath) {
            [System.Windows.MessageBox]::Show("Output file cannot be the same as an input video.",
                "Merge Videos - Error",
                [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Error) | Out-Null
            return
        }
    }

    # Disable inputs during merge, enable cancel.
    $btnAdd.IsEnabled    = $false
    $btnRemove.IsEnabled = $false
    $btnUp.IsEnabled     = $false
    $btnDown.IsEnabled   = $false
    $btnChooseOutput.IsEnabled = $false
    $btnMerge.IsEnabled  = $false
    $btnCancel.IsEnabled = $true
    $script:cancelRequested = $false

    $progressMerge.Value = 0
    $txtProgressPct.Text = "0%"

    $totalMb = 0.0
    foreach ($v in $script:videos) { $totalMb += (Get-Item $v).Length / 1MB }
    $totalDurSec = 0.0
    foreach ($info in $script:infos) { $totalDurSec += [double]$info.Duration }

    Add-LogEntry ("Inputs : {0} videos, {1:N1} MB total, ~{2}" -f $script:videos.Count, $totalMb, (Format-Duration $totalDurSec))
    Add-LogEntry ("Output : {0}" -f (Split-Path $script:outputPath -Leaf))

    $anyMissingAudio = ($script:infos | Where-Object { -not $_.HasAudio }).Count -gt 0

    # Concat list for stream-copy attempt (only useful when audio is uniform).
    $listFile = Join-Path $env:TEMP ("merge-videos-{0}.txt" -f ([guid]::NewGuid().ToString("N")))
    try {
        $sw = New-Object System.IO.StreamWriter($listFile, $false, (New-Object System.Text.UTF8Encoding($false)))
        foreach ($v in $script:videos) {
            $escaped = $v -replace "'", "'\''"
            $sw.WriteLine("file '$escaped'")
        }
        $sw.Close()

        $streamCopyExit = -1
        if (-not $anyMissingAudio) {
            $txtProgressLabel.Text = "Attempting fast stream-copy merge..."
            Add-LogEntry "Attempting stream-copy merge (no re-encoding)..."
            $mergeArgs = @('-hide_banner', '-loglevel', 'error', '-progress', 'pipe:1', '-nostats',
                           '-f', 'concat', '-safe', '0', '-i', $listFile,
                           '-c', 'copy', $script:outputPath, '-y')
            $streamCopyExit = Invoke-FfmpegLive -arguments $mergeArgs -totalDurationSec $totalDurSec
        } else {
            Add-LogEntry "Mixed audio detected -- skipping stream copy, going straight to re-encode."
        }

        $finalExit = $streamCopyExit
        if (($streamCopyExit -ne 0 -or $anyMissingAudio) -and -not $script:cancelRequested) {
            if ($streamCopyExit -gt 0) {
                Add-LogEntry "Stream copy failed -- mismatched codecs/resolutions/framerates."
            }
            $txtProgressLabel.Text = "Re-encoding at H.264 CRF 23..."
            Add-LogEntry "Re-encoding (may take a few minutes)..."

            # Build filter graph with silent-audio injection for audio-less segments.
            $inputArgs = @()
            foreach ($src in $script:videos) { $inputArgs += @("-i", $src) }
            $n = $script:videos.Count
            $silentDecls = @()
            $concatChain = ""
            for ($i = 0; $i -lt $n; $i++) {
                if ($script:infos[$i].HasAudio) {
                    $concatChain += "[$i`:v:0][$i`:a:0]"
                } else {
                    $dur = [math]::Max(1.0, [double]$script:infos[$i].Duration)
                    $silentDecls += ("anullsrc=r=48000:cl=stereo:d={0}[silent{1}]" -f $dur, $i)
                    $concatChain += "[$i`:v:0][silent$i]"
                }
            }
            $prefix = if ($silentDecls.Count -gt 0) { ($silentDecls -join ';') + ';' } else { '' }
            $filterComplex = "$prefix$concatChain" + "concat=n=$n`:v=1:a=1[outv][outa]"

            $mergeArgs = @('-hide_banner', '-loglevel', 'error', '-progress', 'pipe:1', '-nostats') + $inputArgs
            $mergeArgs += @('-filter_complex', $filterComplex,
                            '-map', '[outv]', '-map', '[outa]',
                            '-c:v', 'libx264', '-crf', '23', '-preset', 'medium',
                            '-c:a', 'aac', '-b:a', '192k',
                            $script:outputPath, '-y')
            $finalExit = Invoke-FfmpegLive -arguments $mergeArgs -totalDurationSec $totalDurSec
        }

        # Report outcome.
        if ($script:cancelRequested) {
            Add-LogEntry "MERGE CANCELLED."
            $txtProgressLabel.Text = "Cancelled"
        } elseif ($finalExit -eq 0 -and (Test-Path $script:outputPath) -and (Get-Item $script:outputPath).Length -gt 0) {
            $newSize = [math]::Round((Get-Item $script:outputPath).Length / 1MB, 2)
            Add-LogEntry ("SUCCESS! Merged {0} videos, output {1} MB, saved to: {2}" -f $script:videos.Count, $newSize, $script:outputPath)
            $txtProgressLabel.Text = "Done"
            $progressMerge.Value   = 100
            $txtProgressPct.Text   = "100%"
        } else {
            Add-LogEntry "MERGE FAILED (exit=$finalExit). See messages above."
            $txtProgressLabel.Text = "Failed"
        }
    } finally {
        if (Test-Path $listFile) { Remove-Item $listFile -Force -ErrorAction SilentlyContinue }
        $btnAdd.IsEnabled    = $true
        $btnRemove.IsEnabled = $true
        $btnUp.IsEnabled     = $true
        $btnDown.IsEnabled   = $true
        $btnChooseOutput.IsEnabled = $true
        $btnCancel.IsEnabled = $false
        Update-MergeButtonState
    }
}

function Invoke-FfmpegLive {
    <#
    .DESCRIPTION
        Runs ffmpeg with -progress pipe:1, streams stdout line-by-line into
        the UI, updates the progress bar based on out_time_ms= vs the caller's
        total duration. Uses Diagnostics.Process so we can Kill on cancel.
    #>
    param([string[]]$arguments, [double]$totalDurationSec)

    # Build shell-quoted command line (WinPS 5.1 ProcessStartInfo lacks ArgumentList).
    $quoted = foreach ($a in $arguments) {
        if ($a -match '[\s"]') { '"' + ($a -replace '"', '\"') + '"' } else { $a }
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = $ffmpeg
    $psi.Arguments              = ($quoted -join ' ')
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true

    $proc = [System.Diagnostics.Process]::Start($psi)
    $script:currentProcess = $proc

    # Poll stdout + stderr inline while the process runs. Both must be drained
    # or ffmpeg's write buffers eventually fill and it blocks.
    while (-not $proc.HasExited) {
        # Poll stdout (progress) and stderr (errors) both.
        while (-not $proc.StandardOutput.EndOfStream) {
            $line = $proc.StandardOutput.ReadLine()
            if ($line -match '^out_time_ms=(\d+)') {
                $outSec = [int64]$Matches[1] / 1000000.0
                if ($totalDurationSec -gt 0) {
                    $pct = [math]::Min(100, [math]::Floor(($outSec / $totalDurationSec) * 100))
                    $progressMerge.Value = $pct
                    $txtProgressPct.Text = "$pct%"
                }
            } elseif ($line -match '^progress=end') {
                # end-of-stream marker
            }
        }
        while ($proc.StandardError.Peek() -ne -1) {
            $line = $proc.StandardError.ReadLine()
            if ($line) { Add-LogEntry $line }
        }
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 100
        if ($script:cancelRequested -and -not $proc.HasExited) {
            try { $proc.Kill() } catch { Write-Debug "Kill on cancel: $($_.Exception.Message)" }
            break
        }
    }
    $proc.WaitForExit()

    # Drain any final buffered output.
    while (-not $proc.StandardOutput.EndOfStream) { $null = $proc.StandardOutput.ReadLine() }
    while (-not $proc.StandardError.EndOfStream)  { $line = $proc.StandardError.ReadLine(); if ($line) { Add-LogEntry $line } }

    $exitCode = $proc.ExitCode
    $script:currentProcess = $null
    return $exitCode
}

$btnMerge.Add_Click({ Start-Merge })

# --------------------------------------------------------- launch ---
Add-LogEntry "Merge Videos ready. FFmpeg: $(Split-Path $ffmpeg -Leaf) at $(Split-Path $ffmpeg -Parent)"
[void]$window.ShowDialog()
