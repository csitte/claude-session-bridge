# session-manager.ps1 — UI for managing the autostart list of Claude sessions.
#
# Shows every project from projects.<host>.conf as a checkbox list:
#   checked   = selected  ->  started by "Start all active"
#   unchecked = not selected  ->  stays in the list, starts only on its own
#   "RUN" marker before the name = a Claude session really is running for it
#     (source: ~/.claude/sessions/ with a LIVE pid, not the window title -- see
#     Get-RunningSessions).
# "Save" writes ONLY the local file autostart.<host>.local - the config is not touched
# any more. Reason: the checkboxes are a convenience for the fleet start and change all
# the time; their state is no signal, and in the shared repo every toggle produced a
# commit that arrived on the other machine as intent. The LIST (name, path, extra args,
# instructions=) stays versioned. If the local file is missing, the #off state of the
# config counts as a one-time seed.
# Plus: "Start all active" (= start-cc.cmd) and "Start selected"
# (= start-one.sh, works for disabled entries too).
#
# Interaction (deliberately separated so that starting does not change the autostart):
#   click on a row          = select it (for "Start selected") — toggles NOTHING
#   space / "Toggle autostart" = flip the autostart checkbox of the selected row
#
# Launch: double click session-manager.cmd or a desktop shortcut.
#
# Deliberately ASCII-only in code and UI TEXT -- and here is why, because the rule is
# easy to dismiss without it: this file is UTF-8 WITHOUT a BOM, and Windows PowerShell
# 5.1 then reads it as ANSI. An em dash (E2 80 94) decodes into three CP1252 characters,
# and the third one (0x94) is a closing quotation mark, which PowerShell accepts as a
# string delimiter.
#
# Measured, and the detail matters:
#   "double quotes"  -> the string ENDS at that byte, the rest of the line becomes code,
#                       and the file no longer parses. 2 parse errors under 5.1, 0 under 7.
#   'single quotes'  -> parses fine and merely MANGLES the text at runtime. Quieter, and
#                       therefore easier to ship.
#   # comments       -> harmless. That is why comments here may contain such characters
#                       while strings must not, and why the rule looks arbitrary.
#
# Note that PowerShell 7 reads the file as UTF-8 and sees none of this, so checking the
# parser with pwsh proves nothing about this class; ci.yml runs the 5.1 parser as well.

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$ScriptDir = $PSScriptRoot
$GitBash   = 'C:\Program Files\Git\bin\bash.exe'
$HostName  = ($env:COMPUTERNAME).ToLower()
$ConfPath  = Join-Path $ScriptDir "projects.$HostName.conf"
# Autostart selection: local, not in the repo. The list stays in the config, only the
# checkmarks live here. If the file is missing, the #off state of the config is the seed.
$AutostartPath = Join-Path $ScriptDir "autostart.$HostName.local"

if (-not (Test-Path $ConfPath)) {
    [System.Windows.Forms.MessageBox]::Show(
        "No config for host '$HostName':`n$ConfPath",
        'Session Manager', 'OK', 'Error') | Out-Null
    exit 1
}

# --- Reading/writing the config --------------------------------------------

# One entry = line  <indent>"name|path[|extra[|instructions=key]]"  or  <indent>#off "..."
$script:RxOn  = '^(\s*)"(.*)"\s*$'
$script:RxOff = '^(\s*)#off\s+"(.*)"\s*$'

function Read-AutostartNames {
    # Returns $null when there is no local selection yet - that is NOT the same as
    # "nothing selected" and has to stay distinguishable.
    if (-not (Test-Path $AutostartPath)) { return $null }
    $names = New-Object System.Collections.Generic.List[string]
    foreach ($line in [System.IO.File]::ReadAllLines($AutostartPath)) {
        $t = $line
        $h = $t.IndexOf('#')
        if ($h -ge 0) { $t = $t.Substring(0, $h) }
        $t = $t.Trim()
        if ($t) { $names.Add($t) | Out-Null }
    }
    return $names
}

function Read-Conf {
    $raw   = [System.IO.File]::ReadAllText($ConfPath)
    $lines = $raw -split "`r?`n"
    $entries = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $enabled = $null
        if     ($lines[$i] -match $script:RxOff) { $enabled = $false }
        elseif ($lines[$i] -match $script:RxOn)  { $enabled = $true }
        else { continue }
        $indent = $Matches[1]; $inner = $Matches[2]
        $parts = $inner.Split('|', 4)
        $entries.Add([pscustomobject]@{
            LineIndex = $i
            Indent    = $indent
            Inner     = $inner
            Name      = $parts[0]
            Dir       = if ($parts.Count -ge 2) { $parts[1] } else { '' }
            Extra     = if ($parts.Count -ge 3) { $parts[2] } else { '' }
            Enabled   = $enabled
        })
    }
    # The checkmark comes from the LOCAL selection, no longer from the #off prefix. If the
    # file is missing, the parsed #off state stands - that is the seed, and Save writes it
    # down. So the bash side and the UI see the same thing the first time.
    $sel = Read-AutostartNames
    if ($null -ne $sel) {
        foreach ($e in $entries) { $e.Enabled = ($sel -contains $e.Name) }
    }
    return @{ Lines = $lines; Entries = $entries }
}

function Save-Autostart($conf, $checkedNames) {
    # Writes ONLY the local selection. The config is not touched any more: the checkbox
    # state is a convenience, not a signal, and in the shared repo every toggle produced a
    # commit that arrived on the other machine as intent.
    $out = New-Object System.Collections.Generic.List[string]
    $out.Add('# Local autostart selection for the fleet start - NOT in the repo.') | Out-Null
    $out.Add('# One project name per line; "#" starts a comment.') | Out-Null
    $out.Add('# Starting a single project (start-one.sh) always works, also for projects not selected.') | Out-Null
    $out.Add('# Last saved ' + [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ') + ' by the session manager.') | Out-Null
    foreach ($e in $conf.Entries) {
        $on = ($checkedNames -contains $e.Name)
        $e.Enabled = $on
        if ($on) { $out.Add($e.Name) | Out-Null }
    }
    $text = ($out -join "`n") + "`n"
    [System.IO.File]::WriteAllText($AutostartPath, $text,
        (New-Object System.Text.UTF8Encoding($false)))
}

# --- UI --------------------------------------------------------------------

$form = New-Object System.Windows.Forms.Form
$form.Text          = "Claude Sessions - $HostName  ($(Split-Path -Leaf $ConfPath))"
$form.StartPosition = 'CenterScreen'
$form.Size          = New-Object System.Drawing.Size(720, 520)
$form.MinimumSize   = New-Object System.Drawing.Size(560, 360)

$list = New-Object System.Windows.Forms.CheckedListBox
# CheckOnClick=$false: clicking a row only SELECTS it (for starting), it does NOT flip
# the autostart checkbox. Flipping is deliberately done by space or "Toggle autostart".
$list.CheckOnClick = $false
$list.IntegralHeight = $false
$list.Font = New-Object System.Drawing.Font('Consolas', 10)
$list.Dock = 'Fill'

$status = New-Object System.Windows.Forms.Label
$status.Dock = 'Bottom'
$status.Height = 26
$status.TextAlign = 'MiddleLeft'

$panel = New-Object System.Windows.Forms.FlowLayoutPanel
$panel.Dock = 'Bottom'
$panel.Height = 42
$panel.Padding = New-Object System.Windows.Forms.Padding(6, 6, 6, 0)

function New-Btn($text, $width) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text
    $b.Width = $width
    $b.Height = 30
    return $b
}
$btnSave    = New-Btn 'Save' 90
$btnStart   = New-Btn 'Start all active' 140
$btnOne     = New-Btn 'Start selected' 130
$btnToggle  = New-Btn 'Toggle autostart' 130
$btnReload  = New-Btn 'Reload' 90
$panel.Controls.AddRange(@($btnSave, $btnStart, $btnOne, $btnToggle, $btnReload))

$form.Controls.Add($list)
$form.Controls.Add($panel)
$form.Controls.Add($status)

$script:Conf = $null

function Format-Item($e, $running) {
    $mark = if ($running) { 'RUN ' } else { '    ' }
    $extraMark = if ($e.Extra) { '  [+args]' } else { '' }
    return ('{0}{1,-16} {2}{3}' -f $mark, $e.Name, $e.Dir, $extraMark)
}

# Detecting running sessions: read the registry of running sessions, not the window
# titles. The title belongs to the WINDOW, not to the session, and `exec bash` keeps the
# window open after claude has exited -- measured once at 16 windows against 15 sessions,
# so the marker claimed a session that was gone.
#
# An entry only counts with a LIVE pid: the registry file disappears only on a clean
# exit, so after a crash or a forced reboot the entries of the aborted sessions are still
# there. The process name must be 'claude', otherwise a reused pid counts. An EMPTY
# process list means "nothing is running" -- after a reboot that is the truth, not a
# broken check. One Get-Process per timer tick costs milliseconds.
#
# Duplicated on purpose: cc_session_running in _lib.sh answers the same question for the
# launcher. Calling bash once per timer tick (every 3 s) would block the UI, so the logic
# exists twice -- named at both ends so a change to one is not made in isolation.
function Get-RunningSessions {
    $dir = Join-Path $(if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR }
                       else { Join-Path $HOME '.claude' }) 'sessions'
    if (-not (Test-Path $dir)) { return @() }
    $live = @{}
    foreach ($p in @(Get-Process -Name claude -ErrorAction SilentlyContinue)) { $live[[int]$p.Id] = $true }
    try {
        return @(Get-ChildItem -Path $dir -Filter '*.json' -ErrorAction SilentlyContinue |
                 ForEach-Object {
                     try { Get-Content $_.FullName -Raw | ConvertFrom-Json } catch { }
                 } |
                 Where-Object { $_ -and $_.pid -and $live.ContainsKey([int]$_.pid) } |
                 ForEach-Object {
                     [pscustomobject]@{
                         Name = ('' + $_.name).ToLower()
                         Cwd  = ('' + $_.cwd).Replace('\', '/').TrimEnd('/').ToLower()
                     }
                 })
    } catch { return @() }
}

# Is a session running for this config entry? See the duplication note above.
#
# The config carries msys paths (/d/work/x), the registry Windows paths (D:\work\x).
# Without the rewrite the cwd branch would be dead and only the name would ever match --
# and a comparison that never matches looks like one that finds nothing. In _lib.sh that
# conversion is done by cygpath -m.
#
# Compared whole, never as a prefix: otherwise 'app' counts as running as soon as
# 'app-product' does.
function Test-EntryRunning($e, $sessions) {
    $n = ('' + $e.Name).ToLower()
    $d = ('' + $e.Dir).Replace('\', '/').TrimEnd('/').ToLower()
    $d = $d -replace '^/([a-z])/', '$1:/'
    foreach ($s in $sessions) {
        if ($d -and $s.Cwd -eq $d) { return $true }
        if ($n -and $s.Name -eq $n) { return $true }
    }
    return $false
}

# Updates ONLY the RUN markers (item texts) — checkboxes and selection stay untouched.
# Rewrites an item only if its text really changes (avoids flicker).
function Refresh-Running {
    if (-not $script:Conf) { return }
    $running = Get-RunningSessions
    for ($i = 0; $i -lt $list.Items.Count; $i++) {
        $e = $script:Conf.Entries[$i]
        $isRun = Test-EntryRunning $e $running
        $newText = Format-Item $e $isRun
        if ($list.Items[$i] -ne $newText) {
            $wasChecked = $list.GetItemChecked($i)
            $list.Items[$i] = $newText
            if ($wasChecked -ne $list.GetItemChecked($i)) {
                $list.SetItemChecked($i, $wasChecked)
            }
        }
    }
}

function Get-CheckedNames {
    $names = @()
    for ($i = 0; $i -lt $list.Items.Count; $i++) {
        if ($list.GetItemChecked($i)) { $names += $script:Conf.Entries[$i].Name }
    }
    return $names
}

function Update-Status {
    $n = (Get-CheckedNames).Count
    $status.Text = "  $n of $($list.Items.Count) in autostart | click = select, space/button = autostart, 'RUN' = running"
}

function Load-List {
    $script:Conf = Read-Conf
    $running = Get-RunningSessions
    $list.Items.Clear()
    foreach ($e in $script:Conf.Entries) {
        $isRun = Test-EntryRunning $e $running
        $list.Items.Add((Format-Item $e $isRun), $e.Enabled) | Out-Null
    }
    Update-Status
}

function Test-Dirty {
    for ($i = 0; $i -lt $list.Items.Count; $i++) {
        if ($list.GetItemChecked($i) -ne $script:Conf.Entries[$i].Enabled) { return $true }
    }
    return $false
}

$btnSave.Add_Click({
    Save-Autostart $script:Conf (Get-CheckedNames)
    Update-Status
    $status.Text = "  Saved: $AutostartPath"
})

$btnStart.Add_Click({
    if (Test-Dirty) { Save-Autostart $script:Conf (Get-CheckedNames) }
    Start-Process -FilePath (Join-Path $ScriptDir 'start-cc.cmd') -WorkingDirectory $ScriptDir
})

$btnOne.Add_Click({
    if ($list.SelectedIndex -lt 0) {
        $status.Text = '  Please select a project in the list first (click it).'
        return
    }
    $name = $script:Conf.Entries[$list.SelectedIndex].Name
    $posixDir = $ScriptDir -replace '\\', '/'
    # Note: Start-Process -ArgumentList does NOT quote for you — the command has to be
    # wrapped in "" explicitly, otherwise bash -lc receives only the first word ('cd')
    # and the rest evaporates as positional parameters.
    $bashCmd = 'cd ''' + $posixDir + ''' && ./start-one.sh ''' + $name + ''''
    Start-Process -FilePath $GitBash -WindowStyle Minimized `
        -ArgumentList @('-lc', ('"' + $bashCmd + '"'))
    $status.Text = "  Starting '$name' ..."
})

$btnToggle.Add_Click({
    $i = $list.SelectedIndex
    if ($i -lt 0) {
        $status.Text = '  Please select a row first (click it), then toggle autostart.'
        return
    }
    $list.SetItemChecked($i, -not $list.GetItemChecked($i))
    Update-Status
})

$btnReload.Add_Click({ Load-List })

$list.Add_ItemCheck({
    # ItemCheck fires BEFORE the change — refresh the status just after it.
    # During the initial fill (Load-List) the window handle does not exist yet;
    # BeginInvoke would throw -> skip it, Load-List calls Update-Status itself
    # at the end.
    if ($form.IsHandleCreated) {
        $form.BeginInvoke([Action]{ Update-Status }) | Out-Null
    }
})

$form.Add_FormClosing({
    param($sender, $e)
    if (Test-Dirty) {
        $r = [System.Windows.Forms.MessageBox]::Show(
            'Save unsaved changes to the autostart list?',
            'Session Manager', 'YesNoCancel', 'Question')
        if ($r -eq 'Yes')    { Save-Autostart $script:Conf (Get-CheckedNames) }
        if ($r -eq 'Cancel') { $e.Cancel = $true }
    }
})

# Keep the RUN markers live: mirror the open mintty windows into the list every 3 s.
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 3000
$timer.Add_Tick({ Refresh-Running })

Load-List
$timer.Start()
[void]$form.ShowDialog()
$timer.Stop()
