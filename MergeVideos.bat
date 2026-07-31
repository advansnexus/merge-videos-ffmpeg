@echo off
rem -STA required for WPF window; -WindowStyle Hidden avoids a lingering
rem console window (the WPF UI is the only window the user should see).
rem start ... /b launches without a new console, then the .bat exits
rem immediately so its own cmd host does not linger either.
start "" /b powershell -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0merge-videos.ps1"
