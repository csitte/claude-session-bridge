@echo off
REM Double click: closes the Claude windows opened by start-cc-sessions.sh.
REM Machine-independent: calls its sibling .ps1 relative to itself (%~dp0).
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0close-cc-sessions.ps1"
echo.
pause
