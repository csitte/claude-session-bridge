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
#
# -RemnantsOnly [-Since <time>]: runs ONLY the fourth line (see below) and closes no window.
# Meant for testing and for cleaning up by hand.
# -Pattern <text>: test switch; targets only mintty windows with <text> in their command
# line and leaves the starter window and the watchers alone (reason below).

param(
    [switch]$RemnantsOnly,
    [datetime]$Since = (Get-Date),
    [string]$Pattern = 'remote-control'
)

# Fourth line: window remnants.
#
# The launcher starts every window as  bash -lc "... claude ...; exec bash"  (the
# 'exec bash' keeps the window open after Claude ends, so an error stays readable).
# A FORCED taskkill (/T /F, now only the fallback below) hits mintty ALONE: msys tears the
# Windows process tree apart, /T never reaches the shell inside (reproduced: taskkill
# reports exactly ONE terminated process). Claude dies with the window, the shell runs on
# into its 'exec bash' - an interactive bash on a dead pty. It gets stuck computing its
# first prompt (__git_ps1: two subshells) and never goes away: THREE bash.exe per closed
# window, every time. We once found 85 of them after four days (0.68 GB, hardly any load -
# which is why it only surfaced when memory ran short).
#
# Marks, all three together (a fourth one when run by hand, it is in the function):
#   - bash.exe with a BARE command line (just the path of the exe). A normal Git Bash
#     carries '--login -i', a script carries its name.
#   - the parent process of the topmost link is dead.
#   - created since this script started ($Since). That is the guard against the one case
#     that looks EXACTLY the same at the Windows level: a window in which claude ended on
#     its own and which the human still has open (exec bash is alive, its Windows parent
#     is dead there too). That one came into being BEFORE this run and therefore stays.
# Per chain the TOPMOST link is terminated with /T: at the Windows level the two subshells
# do hang below it as children (unlike mintty -> bash). An msys 'kill' is not enough - the
# middle link of every chain survived both TERM and KILL.
function Remove-WindowRemnants([datetime]$since, [bool]$childRequired) {
    $procs = Get-CimInstance Win32_Process
    $byId  = @{}; foreach ($p in $procs) { $byId[[int]$p.ProcessId] = $p }
    $bare  = @{}
    foreach ($p in $procs) {
        if ($p.Name -ne 'bash.exe') { continue }
        if ($p.CommandLine -notmatch '^\s*"?[^"]*\\bash\.exe"?\s*$') { continue }
        $bare[[int]$p.ProcessId] = $p
    }
    foreach ($p in $bare.Values) {
        # Topmost links only: the parent is not a bare bash.
        if ($bare.ContainsKey([int]$p.ParentProcessId)) { continue }
        if ($p.CreationDate -lt $since) { continue }
        # The parent has to be dead. A reused PID shows in the supposed parent being
        # YOUNGER than its child.
        $par = $byId[[int]$p.ParentProcessId]
        if ($par -and $par.CreationDate -le $p.CreationDate) { continue }
        # ONLY when run by hand (-RemnantsOnly with a freely chosen -Since): the remnant has
        # to have a bare bash as a CHILD (it is stuck in its prompt); a healthy shell at its
        # prompt has none. Measured: without this line a -Since set too early hit the live
        # shell of an open window. In the normal run the mark does NOT apply, and that is
        # measured too: a forced close leaves the chain of three one time and ONE single
        # bash without a child the next - which would stay behind. There the time guard
        # carries alone: whatever appears during this run as a bare bash with a dead parent
        # comes from a window this run has closed.
        if ($childRequired) {
            $pid0  = [int]$p.ProcessId
            $child = @($bare.Values | Where-Object { [int]$_.ParentProcessId -eq $pid0 })
            if ($child.Count -eq 0) { continue }
        }
        Write-Host ("  - window remnant (bash PID {0}, created {1:HH:mm:ss})" -f $p.ProcessId, $p.CreationDate)
        taskkill /PID $p.ProcessId /T /F | Out-Null
    }
}

if ($RemnantsOnly) {
    Remove-WindowRemnants $Since $true
    return
}

# Its own name, not $t0: the third line further down measures its delta with $t0 and
# overwrote the start time - the fourth line would then have taken every remnant for too old.
$scriptStart = Get-Date

$targets = Get-CimInstance Win32_Process -Filter "Name='mintty.exe'" |
    Where-Object { $_.CommandLine -like ('*' + $Pattern + '*') }

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

# Close GENTLY first, force afterwards. 'taskkill' WITHOUT /F sends the window a WM_CLOSE -
# the same as clicking its X, and only with that does the sentence in the file header hold.
# mintty passes it on to its shell as SIGHUP, claude and the shell end on their own, and
# NOTHING is left behind (measured on two probe windows: one with a running program, one
# with a live 'exec bash' at its prompt, 0 remnants both times). The question "Processes are
# running. Close anyway?", for which /F used to stand here right away, is never asked,
# because the launcher starts every window with '-o ConfirmExit=no'.
# The old '/T /F' hit mintty ALONE (msys tears the process tree apart, /T never reaches the
# shell) and left three stuck bash.exe per window - see the fourth line.
foreach ($p in $targets) {
    taskkill /PID $p.ProcessId | Out-Null
}
$waitUntil = (Get-Date).AddSeconds(10)
do {
    Start-Sleep -Milliseconds 500
    $left = @($targets | Where-Object { Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue })
} while ($left.Count -gt 0 -and (Get-Date) -lt $waitUntil)
foreach ($p in $left) {
    # Whoever still stands after ten seconds is forced. That leaves window remnants; the
    # fourth line at the end removes them.
    Write-Host ("  - PID {0} does not respond, forcing" -f $p.ProcessId)
    taskkill /PID $p.ProcessId /T /F | Out-Null
}

# -Pattern is a test switch: with a pattern of your own the script hits probe windows only.
# The starter window and the bridge watchers are NOT part of that - the watcher section
# would examine the watchers of every running session, and that is not a test's business.
# Both lists are emptied below; the rest (third and fourth line) runs as in production.
$windowsOnly = ($Pattern -ne 'remote-control')

# Also close the starter window: the console of the desktop shortcut carries the
# title "Start Claude Sessions"; plus any starter processes still running
# (bash/cmd executing the .sh).
$launcher = @()
$launcher += Get-Process | Where-Object { $_.MainWindowTitle -eq 'Start Claude Sessions' }
$launcher += Get-CimInstance Win32_Process |
    Where-Object { $_.Name -in 'bash.exe','cmd.exe','conhost.exe' -and $_.CommandLine -like '*start-cc-sessions.sh*' } |
    ForEach-Object { Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue }
$launcher = $launcher | Where-Object { $_ } | Sort-Object Id -Unique
if ($windowsOnly) { $launcher = @() }

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
if ($windowsOnly) { $wb = @() }
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

# Third line: orphaned ConPTY consoles (see docs/watcher.md, "A third line").
#
# msys opens a ConPTY for every powershell.exe call from bash (cygwin-console-helper plus a
# headless conhost.exe). If the bash side dies in the middle of the call -- which is exactly
# what the taskkill above does -- the conhost does not exit but spins at ~33 % of a core.
# Eleven of them once held 3.7 of 4 cores for fourteen hours. The conhost is a SIBLING of
# the bash, not a child: /T never reaches it.
#
# Measured as a DELTA here, not as the lifetime average watch-bridge.sh --reap also uses: a
# console that sat quiet for hours and starts spinning this very moment has a lifetime
# average near zero -- precisely the case right after this script. Two samples three seconds
# apart tell it anyway: healthy is 0 %, a spinner is at 33 %. "Parent process dead" stays a
# condition: a console under a live creator belongs to a window and is never touched.
# Done in PowerShell directly, not through watch-bridge.sh -- a bash call from here would
# open yet another ConPTY.
Start-Sleep -Seconds 2   # give the processes just killed time to leave the process list
$procs2 = Get-CimInstance Win32_Process
$alive  = @{}; foreach ($p in $procs2) { $alive[[int]$p.ProcessId] = $true }
$cands  = @($procs2 | Where-Object { $_.Name -eq 'conhost.exe' -and -not $alive.ContainsKey([int]$_.ParentProcessId) })
if ($cands.Count -gt 0) {
    $t0 = Get-Date
    $cpu0 = @{}; foreach ($c in $cands) { $cpu0[[int]$c.ProcessId] = ($c.KernelModeTime + $c.UserModeTime) / 10000000 }
    Start-Sleep -Seconds 3
    $el = ((Get-Date) - $t0).TotalSeconds
    foreach ($c in $cands) {
        $gp = Get-Process -Id $c.ProcessId -ErrorAction SilentlyContinue
        if (-not $gp) { continue }
        $pct = 100 * ($gp.TotalProcessorTime.TotalSeconds - $cpu0[[int]$c.ProcessId]) / $el
        if ($pct -lt 5) { continue }
        Write-Host ("  - orphaned console with sustained load (PID {0}, ~{1:N0} % of a core)" -f $c.ProcessId, $pct)
        Stop-Process -Id $c.ProcessId -Force -ErrorAction SilentlyContinue
    }
}

# Fourth line (function and reasoning at the top of the file). Deliberately last: at least
# two seconds have passed by now (the third line's Start-Sleep); measured, all links of a
# chain appear within the same second as the taskkill.
Remove-WindowRemnants $scriptStart $false

Write-Host "Done. You can shut the machine down now." -ForegroundColor Green
