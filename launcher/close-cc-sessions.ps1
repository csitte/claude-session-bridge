# close-cc-sessions.ps1
#
# Closes ONLY the Claude windows opened by start-cc-sessions.sh
# (mintty windows whose start command contains '--remote-control').
# Other Git Bash windows stay open.
#
# Closing is equivalent to clicking the window's X: the session ends
# cleanly, and the conversation has been saved continuously all along,
# so nothing is lost.
#
# IMPORTANT: make sure no window is running a tool or command right now,
# and commit unsaved code changes first.
#
# Machine-independent — uses only Get-CimInstance/Get-Process/taskkill
# (runs on Windows PowerShell 5.1, PowerShell 7 not required).

$targets = Get-CimInstance Win32_Process -Filter "Name='mintty.exe'" |
    Where-Object { $_.CommandLine -like '*remote-control*' }

if (-not $targets) {
    Write-Host "No Claude remote-control windows found." -ForegroundColor Yellow
    return
}

Write-Host "Closing these Claude windows:" -ForegroundColor Cyan
foreach ($p in $targets) {
    # Pull the display name out of the title argument, if present.
    # -match is case-insensitive, so it covers --Title as well as --title.
    $name = if ($p.CommandLine -match '--title\s+"?([^"\s]+)"?') { $Matches[1] } else { "(unknown)" }
    Write-Host ("  - {0}  (PID {1})" -f $name, $p.ProcessId)
}

foreach ($p in $targets) {
    # /T -> also terminates the child processes (bash, claude).
    # /F -> forces termination without mintty asking
    #       ("Processes are running. Close anyway?").
    # Safe, because the transcript is saved continuously and this should only
    # be run while everything is idle (no tool running).
    taskkill /PID $p.ProcessId /T /F | Out-Null
}

# Also close the starter window: the console of the desktop shortcut carries the
# title "Start Claude Sessions"; plus any starter processes still running
# (bash/cmd executing the .sh).
$launcher = @()
$launcher += Get-Process | Where-Object { $_.MainWindowTitle -eq 'Start Claude Sessions' }
$launcher += Get-CimInstance Win32_Process |
    Where-Object { $_.Name -in 'bash.exe','cmd.exe','conhost.exe' -and $_.CommandLine -like '*start-cc-sessions.sh*' } |
    ForEach-Object { Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue }
$launcher = $launcher | Where-Object { $_ } | Sort-Object Id -Unique

foreach ($l in $launcher) {
    Write-Host ("  - starter window (PID {0})" -f $l.Id)
    taskkill /PID $l.Id /T /F | Out-Null
}

# Collect the bridge push watchers (watch-bridge.sh).
#
# Necessary because the taskkill /T above structurally does NOT catch them: msys tears
# the process tree apart (the intermediate shell started by the window exits at once),
# and the watcher is attached to no console. It therefore survives EVERY exit path —
# script, X button or crash. Measured once: four watchers from the previous day's
# sessions were still polling.
#
# Spared are watchers whose wrapper process still hangs under a live claude.exe (= a
# session this script did not close, e.g. one started by hand). Without a live wrapper
# the watcher is silent anyway.
$procs = Get-CimInstance Win32_Process
$byId  = @{}; foreach ($p in $procs) { $byId[[int]$p.ProcessId] = $p }
$wb    = $procs | Where-Object { $_.Name -eq 'bash.exe' -and $_.CommandLine -like '*watch-bridge.sh*' }
$rx    = "watch-bridge\.sh'?\s+'?([A-Za-z0-9._][A-Za-z0-9._-]*)"   # 1st char without "-": otherwise options like --status match

$aktiv = @()
foreach ($w in ($wb | Where-Object { $_.CommandLine -like '* -c *' })) {
    $cur = $byId[[int]$w.ParentProcessId]; $d = 0
    while ($cur -and $d -lt 6) {
        if ($cur.Name -eq 'claude.exe') {
            if ($w.CommandLine -match $rx) { $aktiv += $Matches[1] }
            break
        }
        $cur = $byId[[int]$cur.ParentProcessId]; $d++
    }
}

foreach ($w in ($wb | Where-Object { $_.CommandLine -notlike '* -c *' })) {
    $id = if ($w.CommandLine -match $rx) { $Matches[1] } else { '(unknown)' }
    if ($aktiv -contains $id) { continue }
    Write-Host ("  - bridge watcher {0} (PID {1})" -f $id, $w.ProcessId)
    taskkill /PID $w.ProcessId /F | Out-Null
}

Write-Host "Done. You can shut the machine down now." -ForegroundColor Green
