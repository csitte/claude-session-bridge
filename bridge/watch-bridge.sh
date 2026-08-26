#!/usr/bin/env bash
#
# watch-bridge.sh <session-id> [poll-seconds] — watcher for the session bridge.
# watch-bridge.sh --status [session-id]       — show running watchers (diagnosis).
# watch-bridge.sh --fold <session-id>         — start scan: open threads owned by <id>;
#                                               warns at the end if no watcher delivers.
# watch-bridge.sh --numbers                   — thread numbers used more than once (diagnosis).
# watch-bridge.sh --new-thread <slug> [nr]    — creates threads/<NNN>-<slug>/msgs and prints
#                                               the folder name; [nr] forces a number (a
#                                               deliberate series, e.g. a fan-out).
# Operational docs: docs/watcher.md (arming, busy behaviour, switching it off, start scan).
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
       watch-bridge.sh --fold <session-id>
       watch-bridge.sh --numbers
       watch-bridge.sh --new-thread <slug> [number]
EOF
  exit 64
}

# Resolve the bridge path. $SESSION_BRIDGE_DIR beats everything and is then BINDING
# (no silent fallback to the site paths — otherwise a test would run against the real
# bridge unnoticed). Without the variable, the site block below applies.
bridge=""
resolve_bridge() {
  if [[ -n "${SESSION_BRIDGE_DIR:-}" ]]; then
    bridge="${SESSION_BRIDGE_DIR%/}"
    [[ -d "$bridge/threads" ]] || {
      echo "watch-bridge: SESSION_BRIDGE_DIR='$bridge' has no threads/" >&2; exit 1; }
  else
    local p
    # ---- SITE BLOCK: bridge folder per machine, or just set SESSION_BRIDGE_DIR ----
    for p in "$HOME/session-bridge" "/c/session-bridge"; do
      if [[ -d "$p/threads" ]]; then bridge="$p"; break; fi
    done
  fi
  [[ -n "$bridge" ]] || {
    echo "watch-bridge: no bridge directory found (set SESSION_BRIDGE_DIR)" >&2; exit 1; }
}

# --- Start scan: fold the threads, show the open ones owned by <id> -----------
# The fold the protocol defines (docs/protocol.md, "State is derived, never stored"):
# per file the FIRST `sets-owner:`/`sets-status:` line, filename = chronological order,
# last value per thread wins. Done here in two `grep -r` passes plus one `find` rather
# than a loop over each file: on a cloud-sync folder every single file access triggers a
# fetch round, and a per-file loop took so long that it hit the two-minute tool timeout.
#
# Two completeness checks, because a sync client keeps fetching for minutes after a cold
# start — one of our sessions saw 55 of 72 thread directories on its first `ls` and all of
# them minutes later. A fold in that window misses threads and nobody notices:
# (1) compare the directory count before the grep and after a short settle time — if it
#     changed, fold again; (2) every slug listed in an INDEX.md (if you keep a generated
#     index) must exist under threads/ or _archiv/. Both are advisory: whatever is there is
#     always reported, the warning only says the result is not yet trustworthy.
fold_report() {
  local me="$1" settle="${WATCH_BRIDGE_SETTLE:-5}"
  resolve_bridge
  local n1 n2 pass=0 tmp
  tmp=$(mktemp) || exit 1
  # shellcheck disable=SC2064  # expand $tmp now, not when the trap fires
  trap "rm -f '$tmp'" EXIT

  count_threads() { ls -d "$bridge"/threads/*/ 2>/dev/null | wc -l | tr -d ' '; }
  do_fold() { # -> lines "slug|status|owner|last-file", only owner==me && status!=DONE
    ( cd "$bridge/threads" 2>/dev/null || exit 0
      # Three passes over the tree instead of one per file:
      #   O:./slug/msgs/file:sets-owner: value   (first hit per file, as the fold requires)
      #   S:./slug/msgs/file:sets-status: value
      #   L:./slug/msgs/file                     (all messages -> youngest per thread)
      { grep -rHm1 --include='*.md' '^sets-owner:'  . 2>/dev/null | sed 's/^/O:/'
        grep -rHm1 --include='*.md' '^sets-status:' . 2>/dev/null | sed 's/^/S:/'
        find . -mindepth 3 -maxdepth 3 -path './*/msgs/*.md' 2>/dev/null | sed 's/^/L:/'
      } | tr -d '\r' | awk -v me="$me" '
        { k=substr($0,1,1); rest=substr($0,3)
          if (k=="L") path=rest; else { i=index(rest,":"); path=substr(rest,1,i-1); rest=substr(rest,i+1) }
          n=split(path, p, "/"); slug=p[2]; file=p[n]        # p[1]="." from the leading ./
          if (slug ~ /^_/) next
          if (k=="L") { if (file>last[slug]) last[slug]=file; next }
          i=index(rest,":"); v=substr(rest,i+1); sub(/^[[:space:]]+/,"",v); sub(/[[:space:]]+$/,"",v)
          if (v=="") next
          if (k=="O") { if (file>=fo[slug]) { fo[slug]=file; owner[slug]=v } }
          else        { if (file>=fs[slug]) { fs[slug]=file; status[slug]=v } } }
        END { for (s in last) if (owner[s]==me && status[s]!="DONE")
                printf "%s|%s|%s|%s\n", s, (status[s]==""?"?":status[s]), owner[s], last[s] }' \
      | sort )
  }

  n1=$(count_threads)
  while :; do
    do_fold > "$tmp"
    pass=$((pass+1))
    sleep "$settle"
    n2=$(count_threads)
    [[ "$n2" != "$n1" && $pass -lt 3 ]] || break
    echo "watch-bridge: the thread count changed during the fold ($n1 -> $n2) — the sync client is still fetching, folding again." >&2
    n1=$n2
  done

  # INDEX slugs as a lower bound (advisory: an index is regenerable and may lag).
  local missing="" s idx_n=0
  if [[ -r "$bridge/INDEX.md" ]]; then
    while IFS= read -r s; do
      idx_n=$((idx_n+1))
      [[ -d "$bridge/threads/$s" || -d "$bridge/_archiv/$s" ]] || missing+="${missing:+, }$s"
    done < <(sed -n 's/^| `\([^`]*\)` |.*/\1/p' "$bridge/INDEX.md" | tr -d '\r')
  fi

  local note="stable" idx_note=""
  [[ "$n2" != "$n1" ]] && note="UNSTABLE ($n1 -> $n2)"
  [[ $idx_n -gt 0 ]] && idx_note=" (INDEX lists $idx_n)"
  echo "Bridge fold for '$me': $n2 threads in threads/$idx_note — $note."
  if [[ -n "$missing" ]]; then
    echo "WARNING: listed in INDEX, but in neither threads/ nor _archiv/: $missing"
    echo "         The sync client is probably still fetching — repeat the fold later."
  fi
  local slug st ow last
  if [[ ! -s "$tmp" ]]; then
    echo "no open thread with owner '$me'."
  else
    printf '%-40s %-12s %s\n' "THREAD" "STATUS" "LAST MESSAGE"
    while IFS='|' read -r slug st ow last; do
      printf '%-40s %-12s %s\n' "$slug" "$st" "$last"
    done < "$tmp"
  fi
  arm_hint "$me"
}

# --- Reminder to arm, printed as the LAST line of the fold --------------------
# Field report: one session went two days without a delivery path because two sessions
# in a row ran only the start scan and skipped arming. The second one had called
# `--status` six times and had the leftover line in front of it four times — seen,
# correctly read, never acted on. The fold is the one call every session makes at
# startup and whose output it does read, so a reminder here cannot be missed.
#
# It only appears when something IS wrong: a session that arms first and folds second
# never sees it. That is deliberate — a warning printed on every start becomes
# wallpaper and fails on the day it matters.
arm_hint() { # $1 = id
  case "$(delivery_state "$1")" in
    delivering|unknown) : ;;
    stale)
      echo "ATTENTION: only a silent watcher remnant for '$1' — NOTHING is being delivered."
      echo "           Arm the Monitor tool now; arming clears the remnant by itself." ;;
    none)
      echo "ATTENTION: no watcher for '$1' — without arming, no bridge push arrives."
      echo "           Arm the Monitor tool now (command: docs/watcher.md, or the arm paragraph in CLAUDE.md)." ;;
  esac
}

# --- Check number assignment: thread numbers used more than once --------------
# Threads are numbered by taking the highest existing number + 1 at write time
# (docs/protocol.md, "New topic"). Two sessions writing minutes apart can pick the same
# number, and the fold does not care — but humans do, because a number is how a thread is
# referred to in conversation.
#
# Reports every three-digit number carried by more than one thread, and separates two
# cases that a plain `uniq -d` throws together:
#
#   SERIES    — several threads of the same number by the SAME author: the documented
#               fan-out (one thread per recipient). Correct, not a defect.
#   COLLISION — threads of the same number by DIFFERENT authors: two sessions picked the
#               same number independently.
#
# The distinction is made by AUTHOR, not by slug. A name heuristic (first slug segment)
# was wrong in testing: two unrelated threads can share a leading segment. Measured over
# every duplicated number in a real bridge, the author is exact: every genuine collision
# has different authors, the one deliberate fan-out had exactly one author (11 threads in
# 3 seconds). The per-author time span is printed for that reason — it makes a fan-out
# recognisable at a glance.
#
# One pass over the tree (find), not an `ls` per thread: on a cloud-sync folder every
# access costs a fetch round (same lesson as --fold). `_archiv/` is included, because a
# number stays taken after the thread is archived.
numbers_report() {
  resolve_bridge
  ( cd "$bridge" 2>/dev/null || exit 0
    find threads _archiv -mindepth 3 -maxdepth 3 -path '*/msgs/*.md' 2>/dev/null
  ) | tr -d '\r' | awk -F/ '
    { dir=$1; slug=$2; file=$4
      if (slug !~ /^[0-9][0-9][0-9]-/) next
      if (!(slug in first) || file < first[slug]) { first[slug]=file; where[slug]=dir }
    }
    END {
      for (s in first) {
        num=substr(s,1,3); f=first[s]
        ts=f; sub(/__.*/,"",ts)
        who=f; sub(/^[^_]*__/,"",who); sub(/__.*/,"",who)
        n[num]++
        if (!((num SUBSEP who) in seen)) { seen[num SUBSEP who]=1; authors[num]=authors[num] " " who; na[num]++ }
        cnt[num SUBSEP who]++
        if (!((num SUBSEP who) in lo) || ts < lo[num SUBSEP who]) lo[num SUBSEP who]=ts
        if (!((num SUBSEP who) in hi) || ts > hi[num SUBSEP who]) hi[num SUBSEP who]=ts
      }
      c=0
      for (x in n) if (n[x] > 1) { c++; k[c]=x }
      for (i=1; i<=c; i++) for (j=i+1; j<=c; j++) if (k[j] < k[i]) { t=k[i]; k[i]=k[j]; k[j]=t }
      col=0; ser=0; both=""
      for (i=1; i<=c; i++) { x=k[i]
        q=split(authors[x], a, " ")
        has=0
        for (j=1; j<=q; j++) if (cnt[x SUBSEP a[j]] > 1) has=1
        verdict = (na[x]==1 ? "SERIES" : (has ? "COLL+SERIES" : "COLLISION"))
        if (na[x]==1) ser++; else col++
        # Only the mixed cases: a deliberate series sharing its number with an outsider.
        # A pure series is already covered by the series count.
        if (has && na[x] > 1) both = both " " x
        printf "%s  %-12s %2d threads, %d author(s)\n", x, verdict, n[x], na[x]
        for (j=1; j<=q; j++) {
          span = (lo[x SUBSEP a[j]]==hi[x SUBSEP a[j]] ? lo[x SUBSEP a[j]] \
                  : lo[x SUBSEP a[j]] " .. " hi[x SUBSEP a[j]])
          printf "      %-16s %2dx  %s\n", a[j], cnt[x SUBSEP a[j]], span
        }
      }
      if (c==0) { print "no number used twice."; exit }
      printf "\n%d numbers used more than once: %d collision(s), %d pure series.\n", c, col, ser
      if (both != "") printf "Contains a deliberate series next to the collision:%s\n", both
    }'
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

# --- Delivery state of a single id --------------------------------------------
# Answers: delivering | stale | none | unknown.
#   unknown = no process inventory available (no PowerShell, e.g. Linux/CI). Nothing is
#   warned about in that case: a warning that is reliably wrong on an entire platform is
#   worse than no warning.
delivery_state() { # $1 = id
  command -v powershell.exe >/dev/null 2>&1 || { echo unknown; return 0; }
  local want="$1" kind id pid age under started
  local seen_script=0 delivering=0
  while IFS='|' read -r kind id pid age under started; do
    [[ "${id:-}" == "$want" ]] || continue
    [[ "$kind" == script ]] && seen_script=1
    [[ "$kind" == wrapper && "$under" == 1 ]] && delivering=1
  done < <(watcher_inventory)
  if   [[ $delivering -eq 1 ]]; then echo delivering
  elif [[ $seen_script -eq 1 ]]; then echo stale
  else echo none; fi
}

# --- Diagnosis: who is running, and are they delivering? ----------------------
# The exit code is ALWAYS 0, even when a silent remnant is listed. Making a remnant exit
# non-zero was proposed and rejected: a fleet overview calls `--status` without an id and
# READS the inventory — a failure exit would turn the very diagnosis that surfaces the
# problem into what looks like a broken tool call. The reminder lives in `--fold`
# (arm_hint) instead, where it fires earlier anyway.
#
# A young arm is reported as `starting`, not `delivering`: in its first seconds an arm
# inspects the inventory and steps aside if one already delivers — or it builds its
# baseline. From the outside both look like a second delivering watcher, and the reflex
# on a reported duplicate is to kill the NEWER one — which is the dying arm, while the
# older one is the survivor. The grace period is generous because the inventory can
# take well over a few seconds under load. Two rows for one id get a comment line.
status_report() {
  local filter="${1:-}" grace="${WATCH_BRIDGE_START_GRACE:-90}"
  local kind id pid age under started st r
  local -A live=() count=() young=()
  local -a rows=()
  while IFS='|' read -r kind id pid age under started; do
    [[ -n "${kind:-}" && -n "${id:-}" ]] || continue
    [[ -z "$filter" || "$id" == "$filter" ]] || continue
    if [[ "$kind" == wrapper ]]; then
      [[ "$under" == 1 ]] && live["$id"]=1
    else
      rows+=("$id|$pid|$started|${age:-0}")
      count["$id"]=$(( ${count[$id]:-0} + 1 ))
      [[ "${age:-0}" -le "$grace" ]] && young["$id"]=1
    fi
  done < <(watcher_inventory)

  if [[ ${#rows[@]} -eq 0 ]]; then
    echo "no watcher${filter:+ for '$filter'} is running."
    return 0
  fi
  printf '%-16s %-8s %-12s %s\n' "SESSION" "PID" "ARMED" "STATUS"
  for r in "${rows[@]}"; do
    IFS='|' read -r id pid started age <<<"$r"
    if   [[ "$age" -le "$grace" ]];   then st="starting (${age}s)"
    elif [[ -n "${live[$id]:-}" ]];   then st="delivering"
    else                                   st="REMNANT (silent)"; fi
    printf '%-16s %-8s %-12s %s\n' "$id" "$pid" "$started" "$st"
  done
  # Two rows for one id are a finding only once both are old.
  for id in "${!count[@]}"; do
    [[ ${count[$id]} -gt 1 ]] || continue
    if [[ -n "${young[$id]:-}" ]]; then
      echo "note: '$id' has an arm younger than ${grace}s — probably stepping aside right now." \
           "Not a duplicate; re-check in a minute with --status $id."
    else
      echo "DUPLICATE: '$id' has ${count[$id]} old watchers — every message arrives that many times."
    fi
  done
}

# --- Handing out a thread number: --new-thread -------------------------------
# The leverage is NOT the lock, it is looking properly. Measured across every
# duplicated number in a live bridge: only two pairs were less than five minutes
# apart, the rest hours to days. Those did not come from a race but from the second
# session not SEEING the first -- it looked at `threads/` only (most threads had been
# moved to `_archiv/` by then), or the sync client had not caught up. Hence: read
# both folders, and settle first, exactly as --fold does. The lock covers the two
# real races; it lives LOCALLY, not in the bridge, so no helper files appear there.
new_thread() { # $1=slug [$2=number, for a deliberate series]
  local slug="${1:-}" want="${2:-}" settle="${WATCH_BRIDGE_SETTLE:-5}"
  resolve_bridge

  case "$slug" in
    "" | */*)
      echo "watch-bridge: slug missing or contains '/'." >&2; exit 2 ;;
    [0-9][0-9][0-9]-*)
      echo "watch-bridge: the number is handed out, not passed in -- for a deliberate series give it as the second argument." >&2
      exit 2 ;;
  esac

  count_all() { ls -d "$bridge"/threads/*/ "$bridge"/_archiv/*/ 2>/dev/null | wc -l | tr -d ' '; }
  max_num()   { ls -d "$bridge"/threads/*/ "$bridge"/_archiv/*/ 2>/dev/null \
                | sed 's#/$##; s#.*/##' \
                | awk '/^[0-9][0-9][0-9]-/ { n = substr($0,1,3) + 0; if (n > m) m = n } END { print m + 0 }'; }

  # Settle first: a highest-number that is too low because the sync client is still
  # catching up is precisely the cause this command exists to remove.
  local n1 n2 pass=0
  n1="$(count_all)"
  while :; do
    sleep "$settle"
    n2="$(count_all)"
    pass=$((pass+1))
    [[ "$n2" == "$n1" ]] && break
    if [[ $pass -ge 3 ]]; then
      echo "watch-bridge: WARNING: folder count will not settle ($n1 -> $n2) -- sync still running; the number may be too low." >&2
      break
    fi
    echo "watch-bridge: folder count changed ($n1 -> $n2) -- sync still running, another pass." >&2
    n1="$n2"
  done

  local lock="${TMPDIR:-/tmp}/watch-bridge-newthread.lock" i=0
  # Clear the remains of a crashed run after a minute.
  [[ -d "$lock" ]] && [[ -n "$(find "$lock" -maxdepth 0 -mmin +1 2>/dev/null)" ]] && rmdir "$lock" 2>/dev/null
  until mkdir "$lock" 2>/dev/null; do
    i=$((i+1))
    [[ $i -ge 50 ]] && { echo "watch-bridge: could not take the lock '$lock'." >&2; exit 1; }
    sleep 0.1
  done
  # shellcheck disable=SC2064
  trap "rmdir '$lock' 2>/dev/null" EXIT

  local num
  if [[ -n "$want" ]]; then
    case "$want" in
      *[!0-9]* | "") echo "watch-bridge: '$want' is not a number." >&2; exit 2 ;;
    esac
    num="$(printf '%03d' "$((10#$want))")"
  else
    num="$(printf '%03d' "$(( $(max_num) + 1 ))")"
  fi

  local d existing=""
  for d in "$bridge"/threads/"$num"-*/ "$bridge"/_archiv/"$num"-*/; do
    [[ -d "$d" ]] || continue
    existing+="${existing:+, }$(basename "$d")"
  done

  local dir="$bridge/threads/$num-$slug"
  [[ -d "$dir" ]] && { echo "watch-bridge: '$num-$slug' already exists." >&2; exit 1; }

  if [[ -n "$existing" ]]; then
    if [[ -n "$want" ]]; then
      echo "watch-bridge: number $num is taken ($existing) -- creating it as a deliberate series." >&2
    else
      # max+1 can only be taken if the scan saw too little.
      echo "watch-bridge: $num is taken ($existing) although it should be the next free one -- the sync client is probably still catching up. Try again in a moment." >&2
      exit 1
    fi
  fi

  mkdir -p "$dir/msgs" || exit 1
  echo "$num-$slug"
}

case "${1:-}" in
  --status|-s) status_report "${2:-}"; exit 0 ;;
  --fold|--scan) [[ -n "${2:-}" ]] || usage; fold_report "$2"; exit 0 ;;
  --numbers) numbers_report; exit 0 ;;
  --new-thread) [[ -n "${2:-}" ]] || usage; new_thread "$2" "${3:-}"; exit 0 ;;
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

resolve_bridge

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
declare -A retry

# How often a file that is not readable yet is looked at again before the watcher
# gives up on it. A synced folder (Drive, Dropbox, a network share) can publish the
# NAME before the content has arrived; ticking such a file off on first sight loses
# the message for good -- the name sits in `seen` and is never read again. Seen in
# production exactly once, and it is invisible when it happens: the watcher ran, the
# messages before and after arrived, and the one in between was never reported.
# Generous by default, because a cold sync client can take minutes to catch up.
retry_max="${WATCH_BRIDGE_RETRIES:-40}"

baseline=1
while true; do
  for f in "$bridge"/threads/*/msgs/*.md; do
    [[ -n "${seen[$f]:-}" ]] && continue
    # Baseline first, and without reading it: whatever exists at startup belongs to
    # the session's start scan, whether or not it happens to be readable right now.
    # Otherwise a cold sync client would report half the bridge as it catches up.
    if [[ $baseline -eq 1 ]]; then seen["$f"]=1; continue; fi
    slug="$(basename "$(dirname "$(dirname "$f")")")"
    if [[ "$slug" == _* ]]; then seen["$f"]=1; continue; fi
    from="$(fm_field from "$f")"
    to="$(fm_field to "$f")"
    # Not one frontmatter field readable => so far there is only the name. Do not
    # tick it off; look again next pass.
    if [[ -z "$from" && -z "$to" ]]; then
      n=$(( ${retry[$f]:-0} + 1 ))
      if [[ $n -lt $retry_max ]]; then retry["$f"]=$n; continue; fi
    fi
    seen["$f"]=1
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
