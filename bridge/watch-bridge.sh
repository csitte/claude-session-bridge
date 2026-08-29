#!/usr/bin/env bash
#
# watch-bridge.sh <session-id> [poll-seconds] — watcher for the session bridge.
# watch-bridge.sh --status [session-id]       — watchers AND running sessions (diagnosis):
#                                               reports who runs without being armed.
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

# --- Threads with no owner, reported as part of the fold ----------------------
# A message that sets no `sets-owner:` leaves its thread invisible to EVERY fold --
# including the folds of its own participants, because folding matches `owner == me`.
# Field report: one such thread sat unseen for ten days while it was still unresolved,
# and it was found by accident, by counting `ls threads/` against the folded lines.
#
# Worse than invisible: a generated index usually sorts by status through a switch whose
# default branch catches everything unknown, so an empty status lands in the "done"
# bucket. The thread is then not merely missing, it is REPORTED AS FINISHED. That
# optimistic default is the real defect; this check only makes the consequence visible
# at the place every session looks at anyway.
#
# Reported only for `owner == "" AND status != DONE`: an ownerless DONE thread is picked
# up by the housekeeping rule (DONE + 7 days) and heals itself, so reporting it would be
# noise. Reported to EVERY session, not only to participants -- a thread without an owner
# has no session responsible for it by definition; whoever looks first passes the word on.
#
# Its own keyword: WARNING is the sync backlog, ATTENTION the missing arm.
orphan_hint() {
  local tmp="$1" n slug st kind
  grep -q '^X|' "$tmp" || return 0
  n=$(grep -c '^X|' "$tmp")
  echo "NOTE: $n thread(s) without a 'sets-owner' -- invisible to every fold, including their participants':"
  while IFS='|' read -r kind slug st; do
    printf '      %-40s status: %s\n' "$slug" "$st"
  done < <(grep '^X|' "$tmp")
  echo "      Whoever is a participant there sets 'sets-owner' in the next message of that thread."
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
# --- Fifth check: filenames that do not sort -----------------------------------
# Folding and delivery order by the FILENAME, not by `date:` (protocol: "if they
# disagree, the filename wins"). A name outside the pattern
# `YYYY-MM-DDTHHMMSSZ__<from>__<rand>.md` therefore sorts wrongly — and permanently:
# in the field, `20260826T162510Z__…` (dashes forgotten) sorted lexically AFTER
# `2026-08-28T…` (`-` < `0`), won every subsequent fold, and pushed a three-day-old
# state to a reader as current; the DONE message behind it never reached them. The
# error produces a plausible result instead of an abort — which is why a machine
# checks it, not attention.
#
# ONLY the timestamp part is checked: the random suffix is free-form by protocol
# (mostly hex in the field, but also `k4n7`, `c0ld`, `winm`) and does not sort. A
# leftover temp file (`.tmp-…md`) fails the check too and is named — it sorts BEFORE
# everything and never wins, but it is not a message either. The repair is an `mv`
# (content unchanged, write-once kept); every running watcher sees the new name as a
# new file and delivers it once — wanted for a repair, it just should not surprise
# anyone. A quiet line, no upper-case keyword: the finding needs visibility, not
# urgency. `_archiv/` is included: a wrong name comes back on reactivation.
name_hint() {
  local bad n f
  bad=$( cd "$bridge" 2>/dev/null || exit 0
         find threads _archiv -mindepth 3 -maxdepth 3 -path '*/msgs/*.md' -not -path 'threads/_*' 2>/dev/null \
         | tr -d '\r' | grep -v -E '/[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{6}Z__[^/]*\.md$' | sort )
  [[ -n "$bad" ]] || return 0
  n=$(printf '%s\n' "$bad" | wc -l | tr -d ' ')
  echo "Name check: $n file(s) in msgs/ do not start with 'YYYY-MM-DDTHHMMSSZ__' -- folding and push order by the name, not by 'date:':"
  while IFS= read -r f; do printf '            %s\n' "$f"; done <<< "$bad"
  echo "            Repair: mv to the correct name (content unchanged). A temp leftover next to its finished"
  echo "            message is not a message -- ask the author. Running watchers deliver a renamed file once."
}

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
        END { for (s in last) {
                if (owner[s]=="") { if (status[s]!="DONE") orph[++no]=s "|" (status[s]==""?"?":status[s]); continue }
                if (owner[s]==me && status[s]!="DONE")
                  printf "T|%s|%s|%s|%s\n", s, (status[s]==""?"?":status[s]), owner[s], last[s] }
              for (i=1;i<=no;i++) printf "X|%s\n", orph[i] }' \
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
  # BEFORE the thread list, not after: if the id is wrong the whole list belongs
  # to somebody else. In the incident above the session read the foreign inbox and
  # nearly worked in it — a warning underneath would arrive too late.
  checkout_hint "$me"
  # Also BEFORE the list: a wrong name may have flipped exactly the line the
  # reader is about to take at face value.
  name_hint
  local slug st ow last kind
  if ! grep -q '^T|' "$tmp"; then
    echo "no open thread with owner '$me'."
  else
    printf '%-40s %-12s %s\n' "THREAD" "STATUS" "LAST MESSAGE"
    while IFS='|' read -r kind slug st ow last; do
      printf '%-40s %-12s %s\n' "$slug" "$st" "$last"
    done < <(grep '^T|' "$tmp")
  fi
  orphan_hint "$tmp"
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

# --- Coverage: is a session running WITHOUT a watcher? ------------------------
# Of the three states, the dangerous one is not the remnant — it is the LIVE
# session with no watcher: it stops receiving pushes, and from the outside that
# looks exactly like a session that simply is not running. In our fleet three
# sessions sat in that state for a day; they were found only because someone
# checked by hand. It was not machine-detectable: the process inventory sees
# watchers, never sessions.
#
# Since Claude Code shipped native cross-session messaging it keeps a directory
# of running sessions under ~/.claude/sessions/ — one JSON per session with
# `pid`, `cwd`, `name`, `status`. What matters here is that it is a FILE: a
# script can read it, whereas the equivalent tool call cannot be reached from
# inside a script. $CLAUDE_CONFIG_DIR is honoured.
#
# Sessions are matched by `cwd` against the path column of the participant table
# in the bridge README — not by session name, which is a window label and often
# differs from the participant id. The whole path is compared, NEVER as a
# substring: a `grep -F "/repos/app"` matches the row of `app-product` first and
# mis-attributes silently. Same trap as the `to:` list (`app`/`app-b`,
# `mail`/`mail-work`); it caught this very function during development.
#
# Only what could be attributed is reported: a session in a directory the README
# does not list is not a bridge participant and must not raise an alarm. With no
# registry, no README or no PowerShell the check says NOTHING and --status
# behaves exactly as before — the same restraint as `delivery_state`: a warning
# built on half the data is worse than no warning.

# Bridge path without `exit`: --status does not resolve the bridge at all, and it
# must keep working on a machine that has none. Resolution itself stays in
# `resolve_bridge` — duplicating it here would write the site paths a second
# time, and a rule that exists twice gets fixed once. The subshell absorbs its
# `exit 1`.
bridge_soft() {
  [[ -n "${bridge:-}" ]] && { echo "$bridge"; return 0; }
  ( resolve_bridge >/dev/null 2>&1 && echo "$bridge" ) || true
}

# Make paths comparable: JSON-escaped backslashes to slash, collapse repeats,
# lowercase, no trailing slash.
path_norm() { awk '{ gsub(/\\/,"/"); print tolower($0) }' | tr -d '\r' | tr -s '/' | sed 's|/$||'; }

# Participant table of the README -> "id<TAB>path", one line per backticked path
# in the last column. A path is what is absolute: it starts with `/` or with a
# drive letter. That separates paths from the other backticked fields in that
# column (branch names and the like) and holds on BOTH platforms — filtering on
# ":" alone would have found nothing at all under Unix paths.
readme_pathmap() { # $1 = README.md
  awk -F'|' '/^\| `[a-z0-9.-]+` \|/ {
    id=$2; gsub(/[ `]/,"",id)
    n=split($4, parts, "`")
    for (i=2; i<=n; i+=2) {
      p=parts[i]; gsub(/^ +| +$/,"",p)
      if (p ~ /^\// || p ~ /^[A-Za-z]:/) print id "\t" tolower(p)
    }
  }' "$1" | tr -d '\r' | tr -s '/' | sed 's|/$||'
}

live_claude_pids() {
  command -v powershell.exe >/dev/null 2>&1 || return 0
  powershell.exe -NoProfile -NonInteractive -Command \
    '(Get-Process -Name claude -ErrorAction SilentlyContinue).Id' 2>/dev/null | tr -d '\r'
}

# -> lines "participant-id|window-name|pid|status" for every running session that
# can be attributed to a participant id.
session_inventory() {
  local dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/sessions"
  [[ -d "$dir" ]] || return 0
  local br; br="$(bridge_soft)"
  [[ -n "$br" && -r "$br/README.md" ]] || return 0
  local map; map="$(readme_pathmap "$br/README.md")"
  [[ -n "$map" ]] || return 0
  local pids; pids="$(live_claude_pids)"

  local f name pid cwd st id
  for f in "$dir"/*.json; do
    [[ -f "$f" ]] || continue
    pid=$(grep -oE '"pid":[0-9]+' "$f" | head -1 | cut -d: -f2)
    [[ -n "$pid" ]] || continue
    # A stale entry must not raise a false alarm.
    [[ -n "$pids" ]] && { grep -qx "$pid" <<<"$pids" || continue; }
    cwd=$(grep -oE '"cwd":"[^"]*"' "$f" | head -1 | cut -d'"' -f4 | path_norm)
    [[ -n "$cwd" ]] || continue
    id=$(awk -F'\t' -v c="$cwd" '$2==c{print $1; exit}' <<<"$map")
    [[ -n "$id" ]] || continue
    name=$(grep -oE '"name":"[^"]*"' "$f" | head -1 | cut -d'"' -f4)
    st=$(grep -oE '"status":"[^"]*"' "$f" | head -1 | cut -d'"' -f4)
    echo "$id|${name:-?}|$pid|${st:-?}"
  done
}

# $1 = filter id (empty = all), $2 = covered ids (space-separated),
# $3 = cached session_inventory output
coverage_hint() {
  local filter="${1:-}" covered=" ${2:-} " sess="${3:-}"
  [[ -n "$sess" ]] || return 0
  # Without a process inventory it is UNKNOWN whether a watcher runs, so every
  # running session would look unarmed. On a platform without the inventory the
  # report would be reliably wrong; same restraint as delivery_state.
  command -v powershell.exe >/dev/null 2>&1 || return 0
  local id name pid st r
  local -a unarmed=()
  while IFS='|' read -r id name pid st; do
    [[ -n "${id:-}" ]] || continue
    [[ -z "$filter" || "$id" == "$filter" ]] || continue
    [[ "$covered" == *" $id "* ]] && continue
    unarmed+=("$id|$name|$pid")
  done <<<"$sess"
  [[ ${#unarmed[@]} -gt 0 ]] || return 0
  echo "UNARMED: ${#unarmed[@]} running session(s) without a watcher — nothing is delivered there:"
  for r in "${unarmed[@]}"; do
    IFS='|' read -r id name pid <<<"$r"
    printf '         %-16s window "%s", PID %s\n' "$id" "$name" "$pid"
  done
  echo "         Not fixable from outside: that session has to arm the monitor tool itself"
  echo "         (the arming paragraph in its CLAUDE.md) — or it gets restarted."
}

# One directory, two spellings: msys (`/tmp/x`) and Windows
# (`C:/Users/.../Temp/x`) mean the same place but do not look alike, and a
# string comparison then reports a move that never happened. So the RESOLVED
# form is compared — step into it and ask where you are. If the directory no
# longer exists the raw comparison stands; a difference is a finding then
# anyway. Found by a test, not in the field.
#
# A limit, stated plainly: `path_norm` lowercases so the two spellings become
# comparable — on a case-sensitive filesystem the `cd` therefore fails and the
# raw comparison stands. That is the previous behaviour, so nothing regresses,
# but the resolution does not help there.
path_resolve() { # $1 = path -> resolved and normalised
  local p r
  p="$(printf '%s' "$1" | path_norm)"
  r="$(cd "$p" 2>/dev/null && (pwd -W 2>/dev/null || pwd))"
  [[ -n "$r" ]] || r="$p"
  printf '%s' "$r" | path_norm
}

# --- Does the id match the working directory? --------------------------------
# Field report: a background session living in a second checkout of the same repo
# armed and folded under the id of the MAIN checkout. Its arm then correctly
# stepped aside — a watcher for that id was already delivering — so the session
# was SILENT, while `--status` showed "delivering" for the id in question. The
# fold handed it the other session's inbox, and it nearly started working on a
# thread that belonged to someone else. A human noticed; no tool did.
#
# It was not carelessness, it was FOLLOWING THE DOCS: both checkouts share one
# committed CLAUDE.md, and the arming paragraph in it named the main id at every
# occurrence. That is the same class as a warning printed above a recipe that
# demonstrates the trap — the recipe wins. So the fix has two halves: the
# template (see install-watcher.sh, placeholder id) AND this check, which holds
# regardless of what any CLAUDE.md says.
#
# Three sources, in this order:
#
#   1. `.session-id` in the working directory — one line the id, one line the
#      working tree it was issued for. The second line catches what .gitignore
#      cannot prevent: somebody COPIES a tree and the copy claims the original's
#      id. (This convention was invented by one of our participant pairs long
#      before the script could check it.)
#   2. The participant table of the README: does the working directory sit under
#      one of the paths registered for this id?
#   3. Otherwise nothing — no entry, no statement.
#
# Compared with a trailing "/", never as a bare prefix: `.../app/` against
# `.../app-bgd` would otherwise pass, and that is precisely the case at hand.
#
# No abort, just a note: deliberately folding a foreign id is a legitimate
# diagnostic move. The case this targets is the one where NOBODY notices.
checkout_hint() { # $1 = the id it was called with; prints to stdout
  local me="$1" cwd sid sidpath owner base
  cwd="$(path_resolve .)"
  [[ -n "$cwd" ]] || return 0

  if [[ -r .session-id ]]; then
    sid=$(head -1 .session-id 2>/dev/null | tr -d '\r' | tr -d ' ')
    sidpath=$(sed -n 2p .session-id 2>/dev/null | tr -d '')
    [[ -n "$sidpath" ]] && sidpath="$(path_resolve "$sidpath")"
    if [[ -n "$sid" && "$sid" != "$me" ]]; then
      echo "SUSPECT: called as '$me', but .session-id in this directory says '$sid'."
      echo "         Everything below then belongs to '$me', not to this session. Clarify first."
      return 0
    fi
    if [[ -n "$sidpath" && "$sidpath" != "$cwd" ]]; then
      echo "SUSPECT: .session-id was issued for '$sidpath', we are in '$cwd'."
      echo "         Looks like a copied working tree — two sessions under one id cannot be"
      echo "         repaired (write-once). Clarify first, do not guess."
      return 0
    fi
    return 0
  fi

  local br map paths
  br="$(bridge_soft)"
  [[ -n "$br" && -r "$br/README.md" ]] || return 0
  map="$(readme_pathmap "$br/README.md")"
  [[ -n "$map" ]] || return 0
  paths="$(awk -F'\t' -v id="$me" '$1==id{print $2}' <<<"$map")"
  [[ -n "$paths" ]] || return 0          # id not in the table -> no statement

  local p ok=0
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    # Equal OR below — with a trailing slash, or 'app' would match 'app-bgd'.
    [[ "$cwd" == "$p" || "$cwd" == "$p"/* ]] && { ok=1; break; }
  done <<<"$paths"
  [[ $ok -eq 1 ]] && return 0

  owner="$(awk -F'\t' -v c="$cwd" '$2==c{print $1; exit}' <<<"$map")"
  base="${cwd##*/}"
  echo "SUSPECT: id '$me', but we are in '$cwd' — that directory is not registered for '$me'."
  if [[ -n "$owner" ]]; then
    echo "         The participant table maps it to '$owner'. Did you mean '$owner'?"
  else
    echo "         No participant is registered for it. Did you mean '$base'? Otherwise the"
    echo "         path belongs in the participant table of the bridge README."
  fi
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

  # Second source: which sessions are running at all? Only together with it does a
  # remnant become a finding — or, just as usefully, a harmless leftover.
  local sess; sess="$(session_inventory)"
  local -A running=()
  if [[ -n "$sess" ]]; then
    while IFS='|' read -r id r; do
      [[ -n "${id:-}" ]] && running["$id"]=1
    done <<<"$sess"
  fi

  if [[ ${#rows[@]} -eq 0 ]]; then
    echo "no watcher${filter:+ for '$filter'} is running."
  else
    printf '%-16s %-8s %-12s %s\n' "SESSION" "PID" "ARMED" "STATUS"
    for r in "${rows[@]}"; do
      IFS='|' read -r id pid started age <<<"$r"
      if   [[ "$age" -le "$grace" ]];    then st="starting (${age}s)"
      elif [[ -n "${live[$id]:-}" ]];    then st="delivering"
      elif [[ -z "$sess" ]];             then st="REMNANT (silent)"
      elif [[ -n "${running[$id]:-}" ]]; then st="REMNANT (silent) — session IS RUNNING, unarmed"
      else                                    st="REMNANT (silent) — session ended, harmless"; fi
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
  fi

  # An id counts as covered when a watcher delivers OR one is coming up right now.
  local covered=""
  [[ ${#live[@]}  -gt 0 ]] && for id in "${!live[@]}";  do covered+=" $id"; done
  [[ ${#young[@]} -gt 0 ]] && for id in "${!young[@]}"; do covered+=" $id"; done
  coverage_hint "$filter" "$covered" "$sess"
  return 0
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

  if [[ -n "$existing" && -z "$want" ]]; then
    # max+1 can only be taken if the scan saw too little.
    echo "watch-bridge: $num is taken ($existing) although it should be the next free one -- the sync client is probably still catching up. Try again in a moment." >&2
    exit 1
  fi

  mkdir -p "$dir/msgs" || exit 1

  # Create first, talk afterwards. The series message used to be printed before the
  # mkdir; three lines on stderr are enough for a caller's `| head -2` to close the
  # pipe and kill the script with SIGPIPE -- before the directory existed. Hit during
  # development: the thread was missing while the output looked complete. Whatever
  # creates something creates it first and reports second.
  #
  # A fan-out gives every recipient an owner of their own -- right for the question
  # "who acts?". It does not answer "who needs to know?": in the field two sessions
  # sharing one repository answered the same open question independently, each on
  # their own branch, and the merge tool nearly decided instead of the two of them.
  # Separate owners are right; separate sight is not.
  #
  # The note lives HERE rather than as a rule in the protocol: with a single observed
  # case, maintaining a rule in three documents is the worse deal, and a rule you have
  # to copy out loses against the shortcut. The command already knows a fan-out is
  # being created, and its caller is exactly the one who has to act.
  if [[ -n "$existing" ]]; then
    local n_series
    n_series=$(( $(printf '%s\n' "$existing" | tr ',' '\n' | wc -l) + 1 ))
    echo "watch-bridge: number $num is taken ($existing) -- creating it as a deliberate series." >&2
    echo "         NOTE: series $num now spans $n_series threads. Separate owners mean separate" >&2
    echo "         sight -- name the sibling threads of the series in every message you send," >&2
    echo "         or the recipients will answer the same question independently." >&2
  fi
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
