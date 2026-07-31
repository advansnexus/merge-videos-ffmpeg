@echo off
setlocal EnableExtensions EnableDelayedExpansion
title Merge Videos - Installer

REM ===================================================================
REM  Merge Videos (FFmpeg) - operator launcher.
REM
REM  Double-click this file. Every step is verified in plain English
REM  before any change is made to the machine.
REM
REM  Order:
REM    1. Pre-flight check (Test-System.ps1)   -- verify PS, WPF, etc.
REM    2. Install (install.ps1)                -- unblock, ffmpeg, copy, shortcuts
REM    3. Print summary or plain-English error
REM ===================================================================

cd /d "%~dp0"

set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS%" (
    echo.
    echo   ERROR: Windows PowerShell not found at:
    echo          %PS%
    echo   Contact IT; this launcher requires Windows PowerShell 5.1+.
    echo.
    pause
    exit /b 1
)

REM Pre-flight files must be present or the extract was incomplete.
if not exist "%~dp0Test-System.ps1" (
    echo.
    echo   ERROR: Test-System.ps1 is missing from this folder.
    echo   The Merge Videos folder is incomplete. Re-extract the ZIP.
    echo.
    pause
    exit /b 1
)
if not exist "%~dp0install.ps1" (
    echo.
    echo   ERROR: install.ps1 is missing from this folder.
    echo   The Merge Videos folder is incomplete. Re-extract the ZIP.
    echo.
    pause
    exit /b 1
)

echo.
echo   Merge Videos - installer starting
echo   ---------------------------------
echo   Step A: unblock files (Mark-of-the-Web)
echo   Step B: pre-flight check (Test-System.ps1)
echo   Step C: install (install.ps1)
echo.

REM ---- Step A: Unblock every file in this folder BEFORE we run anything ---
REM Otherwise MOTW-blocked scripts drop PS 5.1 into Constrained Language Mode,
REM which breaks the pre-flight and produces confusing errors. Doing this
REM inline avoids that whole class of failure. We already 'cd /d "%~dp0"'
REM above, so a bare '.\' works and dodges the trailing-backslash-in-quote
REM problem with %~dp0 inside PowerShell -Command.
echo   [A] Unblocking any Mark-of-the-Web on this folder...
"%PS%" -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem -Path .\ -Recurse -File -Include *.ps1,*.psd1,*.bat,*.vbs | Unblock-File -ErrorAction SilentlyContinue"

REM ---- Step B: pre-flight ---------------------------------------------
"%PS%" -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0Test-System.ps1"
if errorlevel 1 (
    echo.
    echo   ================================================================
    echo    INSTALL BLOCKED - pre-flight check reported a FAILURE above.
    echo.
    echo    Read the [FAIL] line + its "Fix:" hint, resolve it, then
    echo    double-click Install.bat again. If you cannot resolve it,
    echo    run Get-DiagnosticInfo.ps1 (bundle everything into a ZIP)
    echo    and send the ZIP to whoever shared this tool.
    echo   ================================================================
    echo.
    pause
    exit /b 1
)

echo.
echo   Pre-flight passed. Starting install...
echo.

REM ---- Step 2: install ------------------------------------------------
"%PS%" -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0install.ps1"
set "RC=%ERRORLEVEL%"

if not "%RC%"=="0" (
    echo.
    echo   ================================================================
    echo    INSTALL FAILED (exit code %RC%).
    echo.
    echo    Read the FAIL / "What to try" line above. If you are stuck,
    echo    run Get-DiagnosticInfo.ps1 in this folder and send the ZIP
    echo    it produces to whoever shared this tool.
    echo   ================================================================
    echo.
    pause
    exit /b %RC%
)

echo.
if not "%MERGE_NO_PAUSE%"=="1" (
    echo   Press any key to close this window...
    pause > nul
)
endlocal
exit /b 0
