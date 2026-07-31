@echo off
title Merge Videos - FFmpeg
rem -STA required for WinForms MessageBox / OpenFileDialog to render reliably.
powershell -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0merge-videos.ps1"
