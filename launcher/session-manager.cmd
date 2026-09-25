@echo off
title Claude Session Manager
REM Double-click wrapper for session-manager.ps1 (checkbox UI for the autostart list).
REM Prefers pwsh (PowerShell 7), falls back to Windows PowerShell.
setlocal
where /q pwsh && (set "PS=pwsh") || (set "PS=powershell")
start "" /b %PS% -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0session-manager.ps1"
rem `start` opens a window with `cmd /K` for a .cmd file - the command runs, the
rem window STAYS. Anything launching this wrapper through `start` would leave an
rem empty window with a prompt behind. `exit` (not `exit /b`) ends a /K cmd too.
exit
