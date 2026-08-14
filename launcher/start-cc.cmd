@echo off
REM Starts all autostart sessions of this machine from ONE mintty window.
REM Mechanics: _lib.sh - data: projects.<host>.conf
REM Machine-independent: finds its sibling script relative to itself (%~dp0).
REM
REM Deliberately mintty and not a cmd console: in a conhost console a single click
REM into the window makes Windows' QuickEdit switch to selection mode (the title
REM gets a "Select" prefix). That freezes output AND keyboard - the starter window
REM could then be closed neither by countdown nor by keypress. mintty has no such
REM mode.
REM
REM Staying open on failure is handled by start-cc-sessions.sh itself (it prompts
REM when projects were skipped) - which is why there is no countdown and no pause
REM here. This .cmd exits immediately; only the mintty window remains.
setlocal
set "HERE=%~dp0"
set "HERE=%HERE:\=/%"
REM IMPORTANT: bash with its full MSYS path (/usr/bin/bash), not just "bash".
REM From cmd.exe, bash is NOT in PATH -> mintty would report
REM "Failed to run 'bash': No such file or directory" and exit with 126.
REM (_lib.sh can use plain "bash", because there mintty is started from bash.)
start "" "C:\Program Files\Git\usr\bin\mintty.exe" -o ConfirmExit=no --Title "Start Claude Sessions" -e /usr/bin/bash -lc "cd '%HERE%' && ./start-cc-sessions.sh"
