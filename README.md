# Merge Videos (FFmpeg) for Windows

[![CI](https://github.com/advansnexus/merge-videos-ffmpeg/actions/workflows/ci.yml/badge.svg)](https://github.com/advansnexus/merge-videos-ffmpeg/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

Zero-cost Windows utility that merges two or more videos into a single file, in the exact order you add them. **Modern WPF single-window GUI** (dark theme, matching the Advans Signal design language) — add videos, reorder, pick output, click Start Merge, watch live progress + log in the same window.

Companion to [`extract-audio-ffmpeg`](https://github.com/amoakoh22/extract-audio-ffmpeg) and shares the same install location (`%LOCALAPPDATA%\FFmpegTools\`).

---

## Tool

### Merge Videos

Joins the uploaded videos end-to-end in upload order. First tries **stream copy** (no re-encoding — seconds, zero quality loss). If the inputs have mismatched codecs, resolutions, or framerates, it automatically falls back to **H.264 CRF 23 re-encoding** — same visual quality standard used by the `compress-video` tool.

| | Input | Output |
|---|---|---|
| Example (stream copy) | 2 × 250 MB screen recordings, matching codecs | 500 MB `.mp4`, ~10 seconds |
| Example (re-encode)   | 3 × mixed-source clips, different resolutions | Single H.264 CRF 23 `.mp4`, minutes |
| Quality loss (stream copy) | — | None |
| Quality loss (re-encode)   | — | Visually none (CRF 23) |

**In scope**
- 2 or more `.mp4` / `.mov` / `.mkv` / `.avi` / `.webm` files
- Ordered join — the order you upload is the order they play
- Automatic codec-compatibility handling (stream copy → re-encode fallback)
- **Mixed-audio inputs** — if some videos have audio and some don't, silent audio is auto-injected so the merge succeeds cleanly
- **Pre-flight preview** — before merging, you see per-input codec / resolution / duration / audio-presence and the estimated merged duration
- **Real-time progress bar** — `[###----] 40% (0m30s / 1m15s)` in place, driven by ffmpeg's `-progress` output
- Files of any size — merge is I/O-bound when stream copy succeeds

**Out of scope**
- Video editing, transitions, effects, or cropping
- Audio-only merging (use standard audio tools)
- Reordering after upload — cancel and restart if the order is wrong
- Trimming individual clips before joining — trim first, then merge

---

## User Flow (WPF GUI)

The main entry point is a single always-visible window — no dialog-hopping, nothing can hide behind the terminal.

**Left column (Setup):**
1. **Add Video...** — multi-select file picker. Each added video is probed with ffprobe and rendered as `1. filename    [codec res dur audio/SILENT]`.
2. **Remove / Move Up / Move Down** — reorder freely. Order in the list = order in the merged output.
3. **Choose output location...** — SaveFileDialog; default filename is `<first-video-name>_merged.mp4`.
4. **Start Merge** — enabled once you have ≥2 videos AND an output path.
5. **Cancel Running Merge** — kills the ffmpeg process cleanly and leaves the queue intact.

**Right column (Details):**
- **Summary card** — updates live as you add/remove: total count, total duration, combined size, codecs, resolutions, and which merge path will be used (stream copy vs. re-encode).
- **Progress row** — label + percentage above a WPF ProgressBar animating on ffmpeg's `-progress pipe:1` output.
- **Live log** — green-on-black Consolas timeline with a timestamp per line.

If you prefer the classic step-by-step CLI (Video 1 → Video 2 → "Add another?"), run `merge-videos-cli.ps1` directly. It's installed alongside the GUI as a fallback for headless or WPF-unavailable environments.

---

## Quick Install (one command)

```powershell
powershell -ExecutionPolicy Bypass -File install.ps1
```

Or just double-click `Install.bat`. The installer:

1. Installs FFmpeg via winget if not already present
2. Copies `merge-videos.ps1` to `%LOCALAPPDATA%\FFmpegTools\` (auto-patches the FFmpeg path)
3. Creates shortcuts on **Desktop** and in the **Start Menu**

No admin rights required.

---

## Sharing with Colleagues

One command builds a ready-to-send ZIP:

```powershell
powershell -ExecutionPolicy Bypass -File Build-ShareZip.ps1
```

Produces `MergeVideos-Installer.zip` (~9 KB) containing the seven files a colleague needs. They extract it and double-click `Install.bat` — the installer auto-detects the FFmpeg path on their machine and patches the script. No manual editing required.

**Requirements:** Windows 10/11, PowerShell 5.1+, internet access (for the ~240 MB FFmpeg download on first install).

---

## Usage

After install, either:

- **Desktop**: double-click **Merge Videos**
- **Start Menu**: search for **Merge Videos**
- **From this folder** (portable, no install): double-click `MergeVideos.bat`

Then follow the upload prompts. The merged video is saved wherever you choose in the final Save dialog.

---

## How it works

### Stream copy path (fast)

FFmpeg's **concat demuxer** reads a list of input files and concatenates their packets without decoding a single frame:

```
ffmpeg -f concat -safe 0 -i list.txt -c copy output.mp4
```

`list.txt` is written to `%TEMP%` for each run and deleted after. Filenames are single-quote-escaped following FFmpeg's concat parser rules. This path takes seconds even for multi-GB inputs — it's the same trick `extract-audio.ps1` uses for pulling audio tracks.

**Requirements for stream copy to work:** all inputs must share codec (usually H.264 for `.mp4`), resolution, framerate, timebase, and pixel format. Screen recordings from the same tool (OBS, Game Bar) typically match.

### Re-encode fallback (safe)

If stream copy fails (non-zero exit), the script retries with FFmpeg's **concat filter**, which decodes each input, resamples to a common format, and re-encodes as H.264 CRF 23 + AAC 192 kbps:

```
ffmpeg -i v1 -i v2 -i v3 \
       -filter_complex "[0:v:0][0:a:0][1:v:0][1:a:0][2:v:0][2:a:0]concat=n=3:v=1:a=1[outv][outa]" \
       -map "[outv]" -map "[outa]" \
       -c:v libx264 -crf 23 -preset medium \
       -c:a aac -b:a 192k \
       output.mp4
```

This always works but is slower and involves one re-encode generation loss (visually imperceptible at CRF 23).

---

## Security

Hardened against **FFmpeg flag injection and concat-parser injection via crafted filenames**:

- All path arguments passed to FFmpeg are explicitly quoted (`"$InputFile"`, `"$OutputFile"`), preventing PowerShell from splitting filenames with spaces or flag-like characters into separate arguments.
- Filenames written into the concat list have single quotes escaped as `'\''`, matching FFmpeg's concat demuxer grammar — filenames containing quotes cannot break out of the list-line parser.
- Input paths are validated to exist before FFmpeg runs.
- Output path is normalised via `[System.IO.Path]::GetFullPath()` and checked against every input path — the tool refuses to overwrite a source file (which would truncate it mid-read).
- Concat list is written to `%TEMP%` with a per-run GUID name and deleted in a `finally` block even if FFmpeg is interrupted.
- Installer registers shortcuts and script under `%LOCALAPPDATA%` and `HKCU`-scoped folders (current user only, no admin required, no system-wide exposure).

---

## Uninstall

Double-click `Uninstall.bat`, or run:

```powershell
powershell -ExecutionPolicy Bypass -File uninstall.ps1
```

Removes: Desktop shortcut, Start Menu shortcut, and `%LOCALAPPDATA%\FFmpegTools\merge-videos.ps1`.  Leaves FFmpeg itself installed (other tools may depend on it) and leaves `extract-audio-ffmpeg`'s scripts untouched.

---

## Files

| File | Purpose |
|------|---------|
| `GETTING-STARTED.txt` | Plain-text setup guide for non-technical colleagues — share this with the ZIP |
| `Install.bat` | Double-click installer launcher — the only file non-technical colleagues need to run |
| `install.ps1` | Installer script — detects/installs FFmpeg, copies script, creates shortcuts |
| `merge-videos.ps1` | Main script — WPF single-window GUI (dark theme, progress bar, live log) |
| `merge-videos-cli.ps1` | Classic step-by-step CLI fallback (Video 1 → 2 → "Add another?") |
| `MergeVideos.bat` | Portable launcher — runs merge-videos.ps1 (WPF) from this folder without installing |
| `Uninstall.bat` | Double-click uninstaller launcher |
| `uninstall.ps1` | Removes shortcuts and the installed script |
| `Build-ShareZip.ps1` | Produces `MergeVideos-Installer.zip` for distribution |
| `tests/smoke-test.ps1` | Headless test suite — parse + PSScriptAnalyzer + escape corpus + end-to-end merges |
| `RUNBOOK.md` | Operational reference — architecture, troubleshooting, code-signing, sibling-compat, iteration log |

---

## Cost

$0. FFmpeg is free and open-source (LGPL/GPL). No cloud services, no accounts, no API keys.
