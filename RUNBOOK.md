# RUNBOOK — Merge Videos (FFmpeg)

Operational reference for maintainers. If you only want to use the tool, read `README.md` or `GETTING-STARTED.txt` instead.

---

## Architecture

```
User double-clicks "Merge Videos" (Desktop / Start Menu / MergeVideos.bat)
         │
         ▼
powershell.exe -File %LOCALAPPDATA%\FFmpegTools\merge-videos.ps1
         │
         ▼
WinForms upload flow
  • OpenFileDialog "Upload Video 1"
  • OpenFileDialog "Upload Video 2"
  • MessageBox "Add another video?"  ── Yes ─► OpenFileDialog "Upload Video N"
  • MessageBox "Confirm merge order"
  • SaveFileDialog "Save merged video as..."
         │
         ▼
Write %TEMP%\merge-videos-<guid>.txt  (concat list, single-quote-escaped)
         │
         ▼
Try: ffmpeg -f concat -safe 0 -i list.txt -c copy output.mp4   (fast path)
         │
         ├── exit 0 ──► SUCCESS
         │
         └── exit ≠ 0 ─► Fallback:
                        ffmpeg -i v1 -i v2 ... -filter_complex "...concat=n=N..."
                              -c:v libx264 -crf 23 -c:a aac -b:a 192k output.mp4
         │
         ▼
Delete list.txt (finally block)
Wait-Keypress
```

### Why two paths?

- **Stream copy** is O(sum-of-file-sizes) I/O only — no decoding — and preserves the source quality bit-for-bit. It requires identical codec parameters across all inputs (codec, profile, level, resolution, framerate, timebase, pixel format).
- **Concat filter** re-decodes, converts to a common intermediate format, and re-encodes. It always works but is CPU-bound and introduces one generation of encode loss.

Screen recordings from the same tool (OBS, Game Bar, Snagit) usually take the fast path. Mixed camera / phone / downloaded footage usually falls back to re-encoding.

---

## FFmpeg Path Discovery

The installer looks for `ffmpeg.exe` recursively under `%LOCALAPPDATA%\Microsoft\WinGet\Packages\`. The winget install path includes the version, e.g.:

```
%LOCALAPPDATA%\Microsoft\WinGet\Packages\Gyan.FFmpeg_Microsoft.Winget.Source_8wekyb3d8bbwe\ffmpeg-<version>-full_build\bin\ffmpeg.exe
```

The installer patches `merge-videos.ps1`'s `$ffmpeg = "..."` line with the discovered path at install time — so upgrades to FFmpeg require re-running `Install.bat`.

### Handling FFmpeg upgrades

When winget updates the FFmpeg package, the version-numbered folder name changes and the hardcoded path in `%LOCALAPPDATA%\FFmpegTools\merge-videos.ps1` will break. Re-run `Install.bat` to re-patch — takes a second when FFmpeg is already installed.

---

## Security Notes

### Filename injection

FFmpeg treats `-` as a flag prefix. A malicious filename like `-y evil.mp4` could, if passed unquoted, be parsed by FFmpeg as flags. The script defends by:

1. Every filename argument is wrapped in double quotes at the PowerShell call site (`"$InputFile"`), so PowerShell passes it as a single argument.
2. Inside the concat list file, filenames are wrapped in single quotes with embedded single quotes escaped as `'\''`. This is FFmpeg's documented concat demuxer grammar.
3. `-safe 0` allows absolute paths (required for the temp list to reference user files anywhere) but combined with (1)+(2) does not enable injection.

### Path traversal

Output paths are normalised through `[System.IO.Path]::GetFullPath()` before use. There is no user-provided path that bypasses the Save dialog, so all writes go where the user explicitly said to save.

### Self-overwrite

The script rejects an output filename that equals any input filename (case-insensitive full-path compare). Without this check, a stream-copy operation could truncate its own input mid-read.

### Scope

- Script + shortcuts live under `%LOCALAPPDATA%` and per-user Desktop/Start Menu.
- No `HKLM` registry writes, no admin required, no system-wide state.
- Uninstall is a targeted `Remove-Item` list — no orphan state.

---

## Test Matrix

The project ships with `tests\smoke-test.ps1`, which runs headless without touching the GUI. It verifies:

1. **Syntax** — `merge-videos.ps1`, `install.ps1`, and `uninstall.ps1` parse without errors under Windows PowerShell 5.1.
2. **Concat-list generation** — Given a list of paths (including filenames with spaces and quotes), the produced concat list has correct escaping.
3. **FFmpeg availability** — `ffmpeg.exe` exists at the hardcoded path (or under `%LOCALAPPDATA%\FFmpegTools\merge-videos.ps1`'s patched path).
4. **End-to-end merge (opt-in)** — When `$env:MERGE_TEST_INPUTS` points to two comma-separated video paths, the test runs the actual ffmpeg concat and verifies a playable output.

Run:

```powershell
powershell -ExecutionPolicy Bypass -File tests\smoke-test.ps1
```

The end-to-end phase is off by default because it depends on the user's local files.

---

## Known Limitations

- **Inputs without an audio track** break the re-encode fallback (concat filter requires both `v` and `a` streams). Workaround: use the stream-copy path only, or preprocess by adding a silent audio track:
  ```
  ffmpeg -i silent.mp4 -f lavfi -i anullsrc=r=48000:cl=stereo -shortest -c:v copy -c:a aac out.mp4
  ```
- **Very-different resolutions** in the re-encode fallback use the first input's frame size — smaller sources are letterboxed, larger sources may be cropped. Preprocess with `-vf scale=1920:1080:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2` to normalise.
- **Reordering after upload** is not supported. Cancel at the "Confirm merge order" step and start over. This is intentional — the whole product is "the order you upload IS the order you merge."

---

## Maintenance Tasks

### Adding a new video format to the picker

Edit the `$dlg.Filter` line in `Select-VideoFile` in `merge-videos.ps1`:

```powershell
$dlg.Filter = "MP4 Videos (*.mp4)|*.mp4|All Video Files (*.mp4;*.mov;*.mkv;*.avi;*.webm;*.YOUR_EXT)|*.mp4;*.mov;*.mkv;*.avi;*.webm;*.YOUR_EXT|All Files (*.*)|*.*"
```

The concat demuxer / filter handle most FFmpeg-supported formats — no other changes needed.

### Changing the re-encode quality

Edit the fallback ffmpeg call in `merge-videos.ps1`. Current setting is CRF 23 (matches `compress-video.ps1`). Lower CRF = higher quality + bigger files. Range 18–28 is normal; 23 is the H.264 default sweet spot.

### Bulk-rolling the installer to colleagues

1. Zip: `Install.bat`, `install.ps1`, `merge-videos.ps1`, `MergeVideos.bat`, `Uninstall.bat`, `uninstall.ps1`, `GETTING-STARTED.txt`.
2. Attach to email / Teams post.
3. Colleagues follow `GETTING-STARTED.txt`.

The installer auto-patches the FFmpeg path per-machine — no manual editing.

---

## Troubleshooting Quick Reference

| Symptom | Cause | Fix |
|---|---|---|
| "FFmpeg not found" popup | Path in script doesn't match installed FFmpeg | Re-run `Install.bat` |
| Windows Defender SmartScreen warning | Unsigned script | Click "More info" → "Run anyway" |
| Yellow "Stream copy failed" then re-encode | Inputs have mismatched codecs — expected | Wait for green SUCCESS |
| Merge completes but audio is silent | One input had no audio track (fallback path) | Preprocess to add silent audio (see Known Limitations) |
| Output size is roughly sum of inputs | Stream copy path succeeded | Working as intended |
| Output size much smaller than sum | Re-encode fallback compressed it | Working as intended |
| Shortcut runs then window disappears instantly | PowerShell execution policy blocked | Shortcut already includes `-ExecutionPolicy Bypass`; check machine group policy overriding |
| "Output file cannot be the same as an input video" error | Save dialog picked a source filename | Choose a different output name |

---

## Related tools

- `extract-audio-ffmpeg` — sibling project. Same install location, same conventions. If you upgrade one, consider re-running the other's installer too to pick up any FFmpeg path change.

---

## Iteration Log

Chronological record of polish passes (from the `/loop 30m` polish cadence). Each entry says WHAT was changed and WHY, so future maintainers (and future polish iterations) don't repeat work.

### Iteration 1 — 2026-07-31 — Static analysis + CI
- **Added PSScriptAnalyzer** as the project's static-analysis gate.
  - `PSScriptAnalyzerSettings.psd1` — pinned config; excludes `PSAvoidUsingWriteHost` (the tool is deliberately console-first, matching sibling `extract-audio-ffmpeg`), fails on `Error` + `Warning` severities.
  - `tests\smoke-test.ps1` — new Phase 1b runs `Invoke-ScriptAnalyzer` with the settings file; if the module is absent, phase is SKIPPED with a note (won't false-fail on machines without PSSA).
  - Fixed the one baseline finding: renamed `Ask-AddMore` -> `Confirm-AddMore` (approved verb).
- **Added GitHub Actions CI** at `.github\workflows\ci.yml`.
  - Two jobs both on `windows-latest`: one under `powershell` (Windows PowerShell 5.1), one under `pwsh` (PowerShell 7).
  - Both install PSScriptAnalyzer, then run `tests\smoke-test.ps1` with `MERGE_CI=1` so the ffmpeg-availability check downgrades from FAIL to SKIP (no need to spend 240 MB of runner bandwidth on the ffmpeg install just to lint).
  - Triggers: push/PR to `main`, plus `workflow_dispatch` for manual reruns.
- **Rationale:** every future polish iteration now has a zero-friction quality gate. PSSA prevents regressions on style / correctness; CI proves the whole path works on a clean image, not just the dev box.

