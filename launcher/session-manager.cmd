@echo off
title Claude Session Manager
REM Double-click wrapper for session-manager.ps1 (checkbox UI for the autostart list).
REM Prefers pwsh (PowerShell 7), falls back to Windows PowerShell.
setlocal
where /q pwsh && (set "PS=pwsh") || (set "PS=powershell")
start "" /b %PS% -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0session-manager.ps1"
