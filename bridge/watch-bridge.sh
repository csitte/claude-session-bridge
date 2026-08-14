#!/usr/bin/env bash
#
# watch-bridge.sh <session-id> [poll-seconds] — watcher for the session bridge.
# watch-bridge.sh --status [session-id]       — show running watchers (diagnosis).
# Operational docs: docs/watcher.md (arming, busy behaviour, switching it off).
#
# Polls <bridge>/threads/*/msgs/ for new .md files and prints ONE line on stdout per
# message addressed `to: <session-id>` (thread slug + sender + file). Intended as the
# command of the harness Monitor primitive: every line becomes a task notification
# that re-invokes the idle session.
#
# `to:` may be a list (`to: app, app-b`) — then every session named reports it.
#
# Rules:
#   - READ ONLY — the write-once property of the bridge stays untouched.
#   - Ignore own posts (`from: <session-id>`).
#   - Ignore `_` directories (_archiv/ lives outside threads/ anyway).
#   - Idempotence: baseline at start — everything that already exists when the watcher
#     starts belongs to the session's start scan; only what appears AFTERWARDS is
#     reported. Restarting the session => new baseline; the start scan catches the rest.
#
#   - `to: all` is DELIBERATELY NOT reported (no twelve-fold simultaneous wakeup);
#     broadcasts are caught by each session's start scan. A written-out list
#     (`to: app, app-b`) is a different thing and IS reported: it is bounded and
#     visible in the file — the sender meant it that way.
#
#   - At start the watcher decides what to do about its own kind: if one already
#     delivers for the same id, THIS arm steps aside (exit 0) and leaves the running
#     delivery alone; if the process found is a silent remnant, it is reaped and this
#     arm takes over. Delivery therefore survives a `/clear` with neither a gap nor a
#     duplicate, and nobody has to disarm anything beforehand.
#     Disable with WATCH_BRIDGE_NO_REAP=1. Background: docs/watcher.md.

set -u

usage() {
  cat >&2 <<'EOF'
usage: watch-bridge.sh <session-id> [poll-seconds]
       watch-bridge.sh --status [session-id]
EOF
  exit 64
}

# --- Inventory of running watchers -------------------------------------------
# One line per process: kind|id|pid|age-seconds|under-claude|started
#   kind  = script  (the watcher itself)
#           wrapper (the shell the harness puts in front; command line contains ` -c `)
#   under-claude applies to wrappers only: if it still hangs under a live claude.exe,
#   delivery is happening. The script process is NOT usable as proof of liveness — by
#   construction it has an already-dead parent (msys fork emulation) and would always
#   look orphaned.
watcher_inventory() {
  command -v powershell.exe >/dev/null 2>&1 || return 0
  local code
  code=$(cat <<'PS_INV'
$all = @{}
Get-CimInstance Win32_Process | ForEach-Object { $all[[int]$_.ProcessId] = $_ }
$now = Get-Date
# First character deliberately excludes "-": otherwise our own `--status` call matches as an id.
$rx  = "watch-bridge\.sh'?\s+'?([A-Za-z0-9._][A-Za-z0-9._-]*)"
foreach ($p in $all.Values) {
  if ($p.Name -ne 'bash.exe') { continue }
  if ($p.CommandLine -notmatch $rx) { continue }
  $id    = $Matches[1]
  $kind  = if ($p.CommandLine -like '* -c *') { 'wrapper' } else { 'script' }
  $under = 0
  if ($kind -eq 'wrapper') {
    $c = $all[[int]$p.ParentProcessId]; $d = 0
    while ($c -and $d -lt 6) {
      if ($c.Name -eq 'claude.exe') { $under = 1; break }
      $c = $all[[int]$c.ParentProcessId]; $d++
    }
  }
  $age = [int]($now - $p.CreationDate).TotalSeconds
  '{0}|{1}|{2}|{3}|{4}|{5}' -f $kind, $id, $p.ProcessId, $age, $under, $p.CreationDate.ToString('MM-dd HH:mm')
}
PS_INV
)
  # PowerShell emits CRLF — the \r has to go or it sticks to the last field.
  powershell.exe -NoProfile -NonInteractive -Command "$code" 2>/dev/null | tr -d '\r'
}

# --- Diagnosis: who is running, and are they delivering? ----------------------
status_report() {
  local filter="${1:-}"
  local kind id pid age under started st r
  local -A live=()
  local -a rows=()
  while IFS='|' read -r kind id pid age under started; do
    [[ -n "${kind:-}" && -n "${id:-}" ]] || continue
    [[ -z "$filter" || "$id" == "$filter" ]] || continue
    if [[ "$kind" == wrapper ]]; then
      [[ "$under" == 1 ]] && live["$id"]=1
    else
      rows+=("$id|$pid|$started")
    fi
  done < <(watcher_inventory)

  if [[ ${#rows[@]} -eq 0 ]]; then
    echo "no watcher${filter:+ for '$filter'} is running."
    return 0
  fi
  printf '%-16s %-8s %-12s %s\n' "SESSION" "PID" "ARMED" "STATUS"
  for r in "${rows[@]}"; do
    IFS='|' read -r id pid started <<<"$r"
    if [[ -n "${live[$id]:-}" ]]; then st="delivering"; else st="REMNANT (silent)"; fi
    printf '%-16s %-8s %-12s %s\n' "$id" "$pid" "$started" "$st"
  done
}

case "${1:-}" in
  --status|-s) status_report "${2:-}"; exit 0 ;;
  ""|-h|--help) usage ;;
esac

me="$1"
poll="${2:-5}"

# --- What is already running: step aside or clean up --------------------------
# A watcher survives the end of its session structurally (msys tears the process tree
# apart, and it is attached to no console) — `taskkill /T` never reaches it. But it
# also survives a `/clear` and KEEPS DELIVERING into the fresh context (observed by
# two sessions independently). The two cases need different answers:
#
#   still delivering -> this arm steps aside. No duplicate delivery, and above all no
#                       gap of the kind that disarming before `/clear` tears open.
#   silent remnant   -> reap it and take over.
#
# "Old" means older than 30 s: this arm's own wrapper processes are only seconds old
# and must not be counted.
handle_existing() {
  [[ -z "${WATCH_BRIDGE_NO_REAP:-}" ]] || return 0
  local kind id pid age under started
  local delivering=0 script_pid=""
  local -a stale=()
  while IFS='|' read -r kind id pid age under started; do
    [[ "${id:-}" == "$me" ]] || continue
    [[ "${age:-0}" -gt 30 ]] || continue
    [[ "$kind" == wrapper && "$under" == 1 ]] && delivering=1
    [[ "$kind" == script ]] && script_pid="$pid"
    stale+=("$pid")
  done < <(watcher_inventory)

  if [[ $delivering -eq 1 ]]; then
    # Deliberately stdout: this is the only notification this arm produces, and it
    # explains to the fresh context why its monitor ends immediately.
    echo "watch-bridge: a watcher for '$me' is already delivering (PID ${script_pid:-?}) —" \
         "this arm ends, delivery continues unchanged."
    exit 0
  fi

  [[ ${#stale[@]} -gt 0 ]] || return 0
  local list; list=$(IFS=,; echo "${stale[*]}")
  powershell.exe -NoProfile -NonInteractive \
    -Command "Stop-Process -Id $list -Force -ErrorAction SilentlyContinue" >/dev/null 2>&1
  echo "watch-bridge: removed silent remnant of '$me' (PID $list)" >&2
}
handle_existing

# Resolve the bridge path. $SESSION_BRIDGE_DIR beats everything and is then BINDING
# (no silent fallback to the site paths — otherwise a test would run against the real
# bridge unnoticed). Without the variable, the site block below applies.
bridge=""
if [[ -n "${SESSION_BRIDGE_DIR:-}" ]]; then
  bridge="${SESSION_BRIDGE_DIR%/}"
  [[ -d "$bridge/threads" ]] || {
    echo "watch-bridge: SESSION_BRIDGE_DIR='$bridge' has no threads/" >&2; exit 1; }
else
  # ---- SITE BLOCK: edit for your machines, or just set SESSION_BRIDGE_DIR ----
  for p in "$HOME/session-bridge" "/c/session-bridge"; do
    if [[ -d "$p/threads" ]]; then bridge="$p"; break; fi
  done
fi
[[ -n "$bridge" ]] || {
  echo "watch-bridge: no bridge directory found (set SESSION_BRIDGE_DIR)" >&2; exit 1; }

# Pull a frontmatter field from the first 15 lines (CR-tolerant, trimmed).
fm_field() { # $1=field $2=file
  sed -n "1,15s/^$1:[[:space:]]*//p" "$2" | head -1 | tr -d '\r' | sed 's/[[:space:]]*$//'
}

# Am I addressed? `to:` may be a list: `to: app, app-b`.
# Compare TOKEN-exact, never as a substring: participant ids grow prefixes of each
# other — `app` / `app-b` / `app-product` and `mail` / `mail-work` — and a substring
# test would deliver `to: mail-work` to `mail` as well.
# `all` falls through this check by itself (it is nobody's id) and therefore stays
# unpushed, including as part of a list.
addressed() { # $1=to-field
  local t
  # shellcheck disable=SC2086  # word splitting is the point: split the list on commas
  for t in ${1//,/ }; do
    [[ "$t" == "$me" ]] && return 0
  done
  return 1
}

shopt -s nullglob
declare -A seen
baseline=1
while true; do
  for f in "$bridge"/threads/*/msgs/*.md; do
    [[ -n "${seen[$f]:-}" ]] && continue
    seen["$f"]=1
    [[ $baseline -eq 1 ]] && continue
    slug="$(basename "$(dirname "$(dirname "$f")")")"
    [[ "$slug" == _* ]] && continue
    from="$(fm_field from "$f")"
    to="$(fm_field to "$f")"
    [[ "$from" == "$me" ]] && continue
    addressed "$to" || continue
    # Name the co-recipients: the session should know the others got the same
    # message — otherwise everyone answers a group message with the same thing.
    # Who holds the ball is still said by `sets-owner`.
    others=""
    # shellcheck disable=SC2086  # deliberate word splitting, as in addressed()
    for t in ${to//,/ }; do
      [[ "$t" == "$me" ]] || others+="${others:+, }$t"
    done
    echo "Bridge message for '$me'${others:+ (also to: $others)}:" \
         "thread '$slug', from '$from' — $(basename "$f")"
  done
  baseline=0
  sleep "$poll"
done
