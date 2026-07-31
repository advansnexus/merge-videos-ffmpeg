@echo off
title Merge Videos - Installer
echo.
echo  Setting up Merge Videos (FFmpeg)...
echo  Please wait -- this may take a few minutes on first run.
echo.
powershell -ExecutionPolicy Bypass -File "%~dp0install.ps1"
echo.
echo  Press any key to close this window...
pause > nul
