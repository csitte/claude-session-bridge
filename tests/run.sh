#!/usr/bin/env bash
#
# tests/run.sh — test suite for the bridge watcher and the installer.
#
# Runs entirely against a throw-away bridge in a temp directory. Two safety rails,
# because the watcher is a program that kills processes:
#
#   SESSION_BRIDGE_DIR   is always set, so nothing can reach a real bridge.
#   WATCH_BRIDGE_NO_REAP is forced to 1, so the tests can never terminate a watcher
#                        that belongs to a live session — yours included.
#
# Both are asserted, not just set (see check_safety). A test suite that reaps the
# adopter's watchers would be the worst possible first contact with this repository.
#
# Usage:  bash tests/run.sh          # all
#         bash tests/run.sh watcher  # only the watcher tests
#         bash tests/run.sh install  # only the installer tests
#         bash tests/run.sh newthread # only the --new-thread tests
#         bash tests/run.sh coverage  # only the coverage tests
#
# Requires: bash, sed, awk, grep. `node` only for the allow-rule test (skipped if absent).
# No PowerShell needed: without it the watcher simply skips the process inventory, which
# is why the delivery core is testable on Linux too.

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WATCHER="$ROOT/bridge/watch-bridge.sh"
INSTALLER="$ROOT/bridge/install-watcher.sh"

export WATCH_BRIDGE_NO_REAP=1

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; [[ $# -gt 1 ]] && printf '       %s\n' "$2"; }
head_() { printf '\n== %s\n' "$1"; }

check_safety() {
  [[ "${WATCH_BRIDGE_NO_REAP:-}" == 1 ]] || { echo "REFUSING: WATCH_BRIDGE_NO_REAP is not 1" >&2; exit 2; }
  [[ -n "${SESSION_BRIDGE_DIR:-}" ]]     || { echo "REFUSING: SESSION_BRIDGE_DIR is not set" >&2; exit 2; }
  case "${SESSION_BRIDGE_DIR:-}" in
    "$TMPROOT"*) : ;;
    *) echo "REFUSING: SESSION_BRIDGE_DIR points outside the temp dir" >&2; exit 2 ;;
  esac
}

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

# --------------------------------------------------------------------------
# helpers
# --------------------------------------------------------------------------

new_bridge() { # -> path of a fresh bridge with one thread
  local b="$TMPROOT/bridge.$RANDOM"
  mkdir -p "$b/threads/001-test/msgs" "$b/threads/_hidden/msgs"
  printf '%s' "$b"
}

post() { # $1=bridge $2=name $3=from $4=to [$5=thread]
  local thread="${5:-001-test}"
  printf -- '---\nfrom: %s\nto: %s\ntype: fyi\ndate: 2026-01-01T00:00:00Z\n---\n\nbody\n' \
    "$3" "$4" > "$1/threads/$thread/msgs/$2.md"
}

post_state() { # $1=bridge $2=thread $3=name $4=from $5=sets-owner $6=sets-status
  mkdir -p "$1/threads/$2/msgs"
  printf -- '---\nfrom: %s\nto: someone\ntype: reply\ndate: 2026-01-01T00:00:00Z\nsets-owner: %s\nsets-status: %s\n---\n\nbody\n' \
    "$4" "$5" "$6" > "$1/threads/$2/msgs/$3.md"
}
post_status_only() { # $1=bridge $2=thread $3=name $4=sets-status ('' = no sets-* at all)
  mkdir -p "$1/threads/$2/msgs"
  {
    echo "---"
    echo "from: someone"
    echo "to: anyone"
    echo "type: fyi"
    echo "date: 2026-01-01T00:00:00Z"
    [ -n "$4" ] && echo "sets-status: $4"
    echo "---"
    echo
    echo "body"
  } > "$1/threads/$2/msgs/$3.md"
}

wait_for_lines() { # $1=file $2=count $3=timeout-seconds -> 0 if reached
  local i=0 n
  while [[ $i -lt $(( $3 * 4 )) ]]; do
    # NOTE: `grep -c` exits 1 on zero matches, so a `|| echo 0` fallback would print
    # a SECOND number. Count with wc instead.
    n="$(wc -l < "$1" 2>/dev/null)" || n=0
    [[ "${n:-0}" -ge "$2" ]] && return 0
    sleep 0.25; i=$((i+1))
  done
  return 1
}

# Runs the watcher for one id against $1, posting the messages created by the
# callback $3 after the baseline pass. Prints the reported message file names.
watch_run() { # $1=bridge $2=id $3=poster-fn $4=expected-line-count
  local bridge="$1" id="$2" poster="$3" want="$4"
  local out="$TMPROOT/out.$id.$RANDOM"
  SESSION_BRIDGE_DIR="$bridge" bash "$WATCHER" "$id" 1 > "$out" 2>/dev/null &
  local pid=$!
  sleep 2                      # let the baseline pass complete
  "$poster" "$bridge"
  wait_for_lines "$out" "$want" 8
  sleep 0.5                    # catch a surplus line that should not be there
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  # sorted, space-separated, no trailing blank
  grep -oE '[A-Za-z0-9_-]+\.md' "$out" | sort | paste -sd' ' -
}

assert_eq() { # $1=label $2=want $3=got
  if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "want [$2]  got [$3]"; fi
}

# --------------------------------------------------------------------------
# watcher
# --------------------------------------------------------------------------

test_watcher() {
  head_ "watcher: addressing"

  local b; b="$(new_bridge)"
  export SESSION_BRIDGE_DIR="$b"; check_safety

  # Present before the watcher starts -> belongs to the start scan, must stay silent.
  post "$b" 000-baseline other "app"
  # In a _ directory -> never reported.
  post "$b" 000-hidden other "app" _hidden

  posts() {
    local b="$1"
    post "$b" 100-single    other       "app"
    post "$b" 110-list      other       "app, app-b"
    post "$b" 120-tight     other       "app-b,app-product"
    post "$b" 130-prefix    other       "app-product"
    post "$b" 140-mailwork  other       "mail-work"
    post "$b" 150-all       other       "all"
    post "$b" 160-all-list  other       "all, app"
    post "$b" 170-self      app         "app, app-b"
    post "$b" 180-spaces    other       "  app-b ,  mail "
  }

  assert_eq "app: single, list, all-in-list — not app-b/app-product/mail-work, not own post" \
    "100-single.md 110-list.md 160-all-list.md" \
    "$(watch_run "$b" app posts 3)"

  b="$(new_bridge)"; export SESSION_BRIDGE_DIR="$b"; check_safety
  post "$b" 000-baseline other "app-b"
  # 170-self is from `app`, so for app-b it is a perfectly normal message — only the
  # sender itself skips it (proven by the app case above).
  assert_eq "app-b: list, tight list, whitespace, and app's message to the group" \
    "110-list.md 120-tight.md 170-self.md 180-spaces.md" \
    "$(watch_run "$b" app-b posts 4)"

  b="$(new_bridge)"; export SESSION_BRIDGE_DIR="$b"; check_safety
  assert_eq "app-product: only its own, never via the 'app' prefix" \
    "120-tight.md 130-prefix.md" \
    "$(watch_run "$b" app-product posts 2)"

  b="$(new_bridge)"; export SESSION_BRIDGE_DIR="$b"; check_safety
  assert_eq "mail: never gets mail-work's message (substring trap)" \
    "180-spaces.md" \
    "$(watch_run "$b" mail posts 1)"

  b="$(new_bridge)"; export SESSION_BRIDGE_DIR="$b"; check_safety
  assert_eq "mail-work: its own only" \
    "140-mailwork.md" \
    "$(watch_run "$b" mail-work posts 1)"

  head_ "watcher: co-recipients in the notification"
  b="$(new_bridge)"; export SESSION_BRIDGE_DIR="$b"; check_safety
  only_list() { post "$1" 200-group other "app, app-b, mail"; }
  local out="$TMPROOT/out.group"
  SESSION_BRIDGE_DIR="$b" bash "$WATCHER" app 1 > "$out" 2>/dev/null &
  local pid=$!; sleep 2; only_list "$b"; wait_for_lines "$out" 1 8; kill $pid 2>/dev/null; wait $pid 2>/dev/null
  if grep -q "also to: app-b, mail" "$out"; then ok "names the other recipients"
  else bad "names the other recipients" "$(cat "$out")"; fi
  if grep -qv "also to:.*\ball\b" "$out"; then ok "does not invent recipients"; fi

  head_ "watcher: a name that arrives before its content"
  b="$(new_bridge)"; export SESSION_BRIDGE_DIR="$b"; check_safety
  # A synced folder can publish the file NAME first and its content a moment later.
  # The watcher has to look at such a file again instead of ticking it off unread:
  # once its name is in `seen` it is never read again, so the message is lost for
  # good -- and nothing anywhere reports that it happened. The junk file in the same
  # pass guards the other side: a file that never gains frontmatter is not a message
  # and must not be delivered just because it is looked at repeatedly.
  posts_late() {
    local b="$1"
    : > "$b/threads/001-test/msgs/200-late.md"                 # name only, no content
    printf 'not a message at all\n' > "$b/threads/001-test/msgs/220-junk.md"
    sleep 2                                                    # at least one pass sees both
    post "$b" 200-late   other "app"                           # content arrives now
    post "$b" 210-normal other "app"
  }
  assert_eq "empty on first sight is read again; a file without frontmatter never is delivered" \
    "200-late.md 210-normal.md" \
    "$(watch_run "$b" app posts_late 2)"

  head_ "watcher: bridge path resolution"
  SESSION_BRIDGE_DIR="$TMPROOT/does-not-exist" bash "$WATCHER" app 1 >/dev/null 2>&1
  assert_eq "invalid SESSION_BRIDGE_DIR aborts (no silent fallback)" "1" "$?"
  bash "$WATCHER" >/dev/null 2>&1
  assert_eq "no arguments -> usage, exit 64" "64" "$?"
  SESSION_BRIDGE_DIR="$b" bash "$WATCHER" --status app >/dev/null 2>&1
  assert_eq "--status exits 0 even with nothing running" "0" "$?"

  # A second arm of the same id is `starting`, not a duplicate, until it is older than
  # the grace period — the survivor is the OLDER process, so a false "duplicate" invites
  # killing the wrong one. Needs the process inventory, hence PowerShell only; both
  # branches are forced through the grace value instead of waiting.
  if command -v powershell.exe >/dev/null 2>&1; then
    SESSION_BRIDGE_DIR="$b" WATCH_BRIDGE_NO_REAP=1 bash "$WATCHER" t156 2 >/dev/null 2>&1 &
    p1=$!
    SESSION_BRIDGE_DIR="$b" WATCH_BRIDGE_NO_REAP=1 bash "$WATCHER" t156 2 >/dev/null 2>&1 &
    p2=$!
    st="$(bash "$WATCHER" --status t156 2>/dev/null)"
    if printf '%s
' "$st" | grep -q '^t156 .*starting'        && printf '%s
' "$st" | grep -q '^note:.*t156.*re-check'        && ! printf '%s
' "$st" | grep -q 'DUPLICATE'; then
      ok "--status: a young second arm is 'starting' with a note, not a duplicate"
    else bad "--status: a young second arm is 'starting' with a note, not a duplicate" "$st"; fi
    st="$(WATCH_BRIDGE_START_GRACE=-1 bash "$WATCHER" --status t156 2>/dev/null)"
    if [[ "$(printf '%s
' "$st" | grep -c '^t156 ')" == 2 ]]        && printf '%s
' "$st" | grep -q "^DUPLICATE: 't156' has 2"        && ! printf '%s
' "$st" | grep -q 'starting'; then
      ok "--status: two arms past the grace period are a DUPLICATE"
    else bad "--status: two arms past the grace period are a DUPLICATE" "$st"; fi
    kill "$p1" "$p2" 2>/dev/null; wait "$p1" "$p2" 2>/dev/null
  else
    printf '  skip no process inventory without PowerShell — --status branches not testable here
'
  fi

  head_ "watcher: start scan (--fold)"
  b="$(new_bridge)"; export SESSION_BRIDGE_DIR="$b"; check_safety
  export WATCH_BRIDGE_SETTLE=0     # no need to wait for a sync client in a temp dir

  # 001-open : handed to app, still open                    -> listed for app
  post_state "$b" 001-open  100-a other app   OPEN
  # a later message WITHOUT sets-* must move the "last message" column but not the state
  post "$b" 900-late other "app" 001-open
  # 002-moved: app had it, then handed it on                -> listed for other, not app
  post_state "$b" 002-moved 100-a other app   OPEN
  post_state "$b" 002-moved 200-b app   other OPEN
  # 003-done : app owns it, but the thread is closed        -> listed for nobody
  post_state "$b" 003-done  100-a other app   OPEN
  post_state "$b" 003-done  200-b other app   DONE
  # _hidden  : underscore directories are never folded
  post_state "$b" _hidden   100-a other app   OPEN

  local fold
  fold="$(bash "$WATCHER" --fold app 2>/dev/null)"
  assert_eq "--fold: only open threads owned by the id (not handed on, not DONE, not _)" \
    "001-open" \
    "$(printf '%s\n' "$fold" | awk '/^[0-9]/ {print $1}' | sort | paste -sd' ' -)"
  if printf '%s\n' "$fold" | grep -qE '^001-open +OPEN +900-late\.md'; then
    ok "--fold shows the youngest message, state unchanged by a message without sets-*"
  else bad "--fold shows the youngest message, state unchanged by a message without sets-*" "$fold"; fi

  assert_eq "--fold follows a handoff to the new owner" \
    "002-moved" \
    "$(bash "$WATCHER" --fold other 2>/dev/null | awk '/^[0-9]/ {print $1}' | sort | paste -sd' ' -)"

  bash "$WATCHER" --fold nobody 2>/dev/null | grep -q "no open thread with owner 'nobody'" \
    && ok "--fold says so plainly when nothing is owned" \
    || bad "--fold says so plainly when nothing is owned"
  bash "$WATCHER" --fold nobody >/dev/null 2>&1
  assert_eq "--fold exits 0 on an empty result" "0" "$?"
  bash "$WATCHER" --fold >/dev/null 2>&1
  assert_eq "--fold without an id -> usage, exit 64" "64" "$?"

  # An INDEX slug with no directory means the sync client has not finished fetching.
  printf '# Index\n\n| thread | status |\n|---|---|\n| `001-open` | OPEN |\n| `999-missing` | OPEN |\n' \
    > "$b/INDEX.md"
  bash "$WATCHER" --fold app 2>/dev/null | grep -q 'WARNING.*999-missing' \
    && ok "--fold warns about an INDEX slug that has not arrived" \
    || bad "--fold warns about an INDEX slug that has not arrived"
  rm -f "$b/INDEX.md"

  # The arming reminder is the last line — and platform-dependent by design: without a
  # process inventory (no PowerShell) the state is `unknown` and nothing is printed.
  # Both branches are asserted, so neither platform silently skips the check.
  fold="$(bash "$WATCHER" --fold app 2>/dev/null)"
  if command -v powershell.exe >/dev/null 2>&1; then
    if printf '%s\n' "$fold" | tail -2 | grep -q "ATTENTION.*'app'"; then
      ok "--fold reminds you to arm when nothing delivers (last line)"
    else bad "--fold reminds you to arm when nothing delivers (last line)" "$fold"; fi
  else
    if printf '%s\n' "$fold" | grep -q 'ATTENTION'; then
      bad "--fold stays quiet without a process inventory" "$fold"
    else ok "--fold stays quiet without a process inventory"; fi
  fi
  # Whatever the platform, the reminder must not disturb the payload: the thread list is
  # still parseable and the exit code is unchanged.
  assert_eq "--fold: the reminder does not disturb the thread list" \
    "001-open" \
    "$(printf '%s\n' "$fold" | awk '/^[0-9]/ {print $1}' | sort | paste -sd' ' -)"
  bash "$WATCHER" --fold app >/dev/null 2>&1
  assert_eq "--fold still exits 0 with the reminder printed" "0" "$?"

  head_ "watcher: threads without an owner (invisible to every fold)"
  b="$(new_bridge)"; export SESSION_BRIDGE_DIR="$b"; check_safety
  export WATCH_BRIDGE_SETTLE=0
  # 001-mine    : owned and open                          -> in the thread list, not in the note
  post_state "$b" 001-mine 100-a other app OPEN
  # 010-nostate : no sets-* field at all (the field case)  -> reported, status '?'
  post_status_only "$b" 010-nostate 100-a ""
  # 011-open    : has a status, but never an owner        -> reported
  post_status_only "$b" 011-open    100-a OPEN
  # 012-done    : ownerless but DONE                      -> NOT reported, housekeeping takes it
  post_status_only "$b" 012-done    100-a DONE
  fold="$(bash "$WATCHER" --fold app 2>/dev/null)"
  assert_eq "--fold reports ownerless threads that are not DONE" \
    "010-nostate 011-open" \
    "$(printf '%s\n' "$fold" | sed -n 's/^ *\(01[0-9]-[a-z]*\) *status:.*/\1/p' | sort | paste -sd' ' -)"
  if printf '%s\n' "$fold" | grep -q "^NOTE: 2 thread(s) without a 'sets-owner'"; then
    ok "--fold names the count under its own keyword"
  else bad "--fold names the count under its own keyword" "$fold"; fi
  if printf '%s\n' "$fold" | grep -qE '^ +012-done'; then   # anchored: the name check lists fixture PATHS (threads/012-done/msgs/…), the owner note lists SLUGS
    bad "--fold stays quiet about an ownerless DONE thread" "$fold"
  else ok "--fold stays quiet about an ownerless DONE thread"; fi
  if printf '%s\n' "$fold" | grep -qE '^ +010-nostate +status: \?$'; then
    ok "a thread without any sets-* field shows status '?'"
  else bad "a thread without any sets-* field shows status '?'" "$fold"; fi
  assert_eq "--fold: the owner check does not disturb the thread list" \
    "001-mine" \
    "$(printf '%s\n' "$fold" | awk '/^[0-9]/ {print $1}' | sort | paste -sd' ' -)"
  bash "$WATCHER" --fold app >/dev/null 2>&1
  assert_eq "--fold still exits 0 with the owner note printed" "0" "$?"
  # ... and it stays silent when every thread has an owner
  b="$(new_bridge)"; export SESSION_BRIDGE_DIR="$b"; check_safety
  post_state "$b" 001-mine 100-a other app OPEN
  if bash "$WATCHER" --fold app 2>/dev/null | grep -q 'NOTE:'; then
    bad "--fold prints no owner note when there is nothing to report"
  else ok "--fold prints no owner note when there is nothing to report"; fi

  head_ "watcher: filenames that do not sort (the name is what folds)"
  b="$(new_bridge)"; export SESSION_BRIDGE_DIR="$b"; check_safety
  # 001-mine: handed to app on the 1st, closed by app on the 3rd ...
  post_state "$b" 001-mine 2026-01-01T000000Z__other__a1 other app   OPEN
  post_state "$b" 001-mine 2026-01-03T000000Z__app__b2   app   other DONE
  # ... but a message from the 2nd with a compact stamp (dashes forgotten) sorts
  # AFTER the 3rd ('-' < '0') and re-opens the thread in every fold — the field case.
  post_state "$b" 001-mine 20260102T000000Z__other__c3   other app   OPEN
  # a temp leftover next to its finished message: sorts first, never wins, not a message
  post_state "$b" 001-mine .tmp-other-c3                 other app   OPEN
  # an archived thread is checked too (a wrong name comes back on reactivation) ...
  mkdir -p "$b/_archiv/000-old/msgs"
  printf -- '---\nfrom: x\nto: y\ntype: fyi\ndate: 2026-01-01T00:00:00Z\nsets-status: DONE\n---\n\nbody\n' \
    > "$b/_archiv/000-old/msgs/badname.md"
  # ... an underscore directory under threads/ is not (never folded either)
  post "$b" badname app other _hidden
  fold="$(bash "$WATCHER" --fold app 2>/dev/null)"
  if printf '%s\n' "$fold" | grep -q '^Name check: 3 file(s)'; then
    ok "--fold counts the files whose name does not start with the timestamp pattern"
  else bad "--fold counts the files whose name does not start with the timestamp pattern" "$fold"; fi
  assert_eq "--fold names them with their path (compact stamp, temp leftover, archived)" \
    "_archiv/000-old/msgs/badname.md threads/001-mine/msgs/.tmp-other-c3.md threads/001-mine/msgs/20260102T000000Z__other__c3.md" \
    "$(printf '%s\n' "$fold" | sed -n 's/^ \{12\}\([^ ]*msgs\/[^ ]*\)$/\1/p' | sort | paste -sd' ' -)"
  if printf '%s\n' "$fold" | grep -q '_hidden'; then
    bad "--fold: the name check skips underscore directories under threads/" "$fold"
  else ok "--fold: the name check skips underscore directories under threads/"; fi
  # the reason the check exists: the wrong name has flipped the state the list shows
  if printf '%s\n' "$fold" | grep -qE '^001-mine +OPEN +20260102T000000Z__other__c3\.md'; then
    ok "a compact stamp wins the fold over a younger, well-formed DONE (the defect)"
  else bad "a compact stamp wins the fold over a younger, well-formed DONE (the defect)" "$fold"; fi
  nc="$(printf '%s\n' "$fold" | grep -n '^Name check:' | cut -d: -f1)"
  tl="$(printf '%s\n' "$fold" | grep -n '^001-mine' | cut -d: -f1)"
  if [[ -n "$nc" && -n "$tl" && "$nc" -lt "$tl" ]]; then
    ok "--fold prints the name check ABOVE the thread list"
  else bad "--fold prints the name check ABOVE the thread list" "$fold"; fi
  bash "$WATCHER" --fold app >/dev/null 2>&1
  assert_eq "--fold still exits 0 with the name check printed" "0" "$?"
  # the repair is a rename, content unchanged — and it heals the fold
  mv "$b/threads/001-mine/msgs/20260102T000000Z__other__c3.md" "$b/threads/001-mine/msgs/2026-01-02T000000Z__other__c3.md"
  fold="$(bash "$WATCHER" --fold app 2>/dev/null)"
  if printf '%s\n' "$fold" | grep -q "no open thread with owner 'app'"; then
    ok "after the rename the younger DONE wins again"
  else bad "after the rename the younger DONE wins again" "$fold"; fi
  if printf '%s\n' "$fold" | grep -q '^Name check: 2 file(s)'; then
    ok "the renamed file drops out of the name check, the other two stay"
  else bad "the renamed file drops out of the name check, the other two stay" "$fold"; fi
  # ... and silence when every name is well-formed (the random suffix is free-form)
  b="$(new_bridge)"; export SESSION_BRIDGE_DIR="$b"; check_safety
  post_state "$b" 001-mine 2026-01-01T000000Z__other__k4n7 other app OPEN
  if bash "$WATCHER" --fold app 2>/dev/null | grep -q 'Name check'; then
    bad "--fold prints no name check when every name is well-formed"
  else ok "--fold prints no name check when every name is well-formed"; fi

  # --- stamp check: right form, wrong value (the name lies ahead of the write time) ---
  # the defect: a message stamped in the future beats a younger, well-formed DONE
  b="$(new_bridge)"; export SESSION_BRIDGE_DIR="$b"; check_safety
  post_state "$b" 001-mine 2026-01-02T000000Z__other__f1 other app OPEN     # stamped 02T00:00 ...
  touch -d '2026-01-01T20:00:00Z' "$b/threads/001-mine/msgs/2026-01-02T000000Z__other__f1.md"  # ... written 01T20:00
  post_state "$b" 001-mine 2026-01-01T210000Z__app__d1 app other DONE       # younger, correct, sets DONE
  touch -d '2026-01-01T21:00:00Z' "$b/threads/001-mine/msgs/2026-01-01T210000Z__app__d1.md"
  fold="$(bash "$WATCHER" --fold app 2>/dev/null)"
  if printf '%s\n' "$fold" | grep -qE '^001-mine +OPEN +2026-01-02T000000Z__other__f1\.md'; then
    ok "a stamp from the future wins the fold over a younger, well-formed DONE (the defect)"
  else bad "a stamp from the future wins the fold over a younger, well-formed DONE (the defect)" "$fold"; fi
  if printf '%s\n' "$fold" | grep -q '^Stamp check: 1 file(s)'; then
    ok "--fold counts the file whose name lies ahead of its mtime"
  else bad "--fold counts the file whose name lies ahead of its mtime" "$fold"; fi
  if printf '%s\n' "$fold" | grep -qF 'threads/001-mine/msgs/2026-01-02T000000Z__other__f1.md  (+4.0 h, written 2026-01-01T200000Z)'; then
    ok "--fold names the file with its lead and the name it should have had"
  else bad "--fold names the file with its lead and the name it should have had" "$fold"; fi
  sc="$(printf '%s\n' "$fold" | grep -n '^Stamp check:' | cut -d: -f1)"
  tl="$(printf '%s\n' "$fold" | grep -n '^001-mine' | cut -d: -f1)"
  if [[ -n "$sc" && -n "$tl" && "$sc" -lt "$tl" ]]; then
    ok "--fold prints the stamp check ABOVE the thread list"
  else bad "--fold prints the stamp check ABOVE the thread list" "$fold"; fi
  bash "$WATCHER" --fold app >/dev/null 2>&1
  assert_eq "--fold still exits 0 with the stamp check printed" "0" "$?"
  # the repair is a rename to the name derived from the write time — and it heals the fold
  mv "$b/threads/001-mine/msgs/2026-01-02T000000Z__other__f1.md" "$b/threads/001-mine/msgs/2026-01-01T200000Z__other__f1.md"
  fold="$(bash "$WATCHER" --fold app 2>/dev/null)"
  if printf '%s\n' "$fold" | grep -q "no open thread with owner 'app'"; then
    ok "after the rename the younger DONE wins again"
  else bad "after the rename the younger DONE wins again" "$fold"; fi
  if printf '%s\n' "$fold" | grep -q 'Stamp check'; then
    bad "the renamed file drops out of the stamp check" "$fold"
  else ok "the renamed file drops out of the stamp check"; fi
  # a superseded file (younger sets-owner AND sets-status behind it) decides nothing — not reported
  b="$(new_bridge)"; export SESSION_BRIDGE_DIR="$b"; check_safety
  post_state "$b" 001-mine 2026-01-02T000000Z__other__f1 other app OPEN
  touch -d '2026-01-01T20:00:00Z' "$b/threads/001-mine/msgs/2026-01-02T000000Z__other__f1.md"
  post_state "$b" 001-mine 2026-01-03T000000Z__app__d2 app other DONE
  if bash "$WATCHER" --fold app 2>/dev/null | grep -q 'Stamp check'; then
    bad "a file superseded by a younger message with sets-* is not reported"
  else ok "a file superseded by a younger message with sets-* is not reported"; fi
  # ... but it IS reported while it still supplies the folded owner (younger message sets status only)
  post_status_only "$b" 001-mine 2026-01-04T000000Z__app__d3 OPEN
  rm "$b/threads/001-mine/msgs/2026-01-03T000000Z__app__d2.md"
  if bash "$WATCHER" --fold app 2>/dev/null | grep -q '^Stamp check: 1 file(s)'; then
    ok "a file that still supplies the folded owner is reported although it is not the last one"
  else bad "a file that still supplies the folded owner is reported although it is not the last one"; fi
  # a synced copy carries a LATER mtime at most (download time): never a hit
  b="$(new_bridge)"; export SESSION_BRIDGE_DIR="$b"; check_safety
  post_state "$b" 001-mine 2026-01-01T000000Z__other__k4n7 other app OPEN   # mtime = now, long after the stamp
  if bash "$WATCHER" --fold app 2>/dev/null | grep -q 'Stamp check'; then
    bad "an mtime later than the stamp (synced copy) is not a finding"
  else ok "an mtime later than the stamp (synced copy) is not a finding"; fi
  # _archiv/ is not folded any more — not checked
  mkdir -p "$b/_archiv/000-old/msgs"
  printf -- '---\nfrom: other\nto: app\ntype: fyi\ndate: 2026-01-01T00:00:00Z\n---\n\nbody\n' > "$b/_archiv/000-old/msgs/2026-01-02T000000Z__other__a1.md"
  touch -d '2026-01-01T20:00:00Z' "$b/_archiv/000-old/msgs/2026-01-02T000000Z__other__a1.md"
  if bash "$WATCHER" --fold app 2>/dev/null | grep -q 'Stamp check'; then
    bad "the stamp check skips _archiv/"
  else ok "the stamp check skips _archiv/"; fi
  # the threshold: 5 min by default, WATCH_BRIDGE_STAMP_SLACK (seconds) overrides
  post_state "$b" 001-mine 2026-01-01T000200Z__other__s1 other app OPEN     # 2 min ahead of its write time
  touch -d '2026-01-01T00:00:00Z' "$b/threads/001-mine/msgs/2026-01-01T000200Z__other__s1.md"
  if bash "$WATCHER" --fold app 2>/dev/null | grep -q 'Stamp check'; then
    bad "a lead under the 5-minute threshold is not reported"
  else ok "a lead under the 5-minute threshold is not reported"; fi
  if WATCH_BRIDGE_STAMP_SLACK=60 bash "$WATCHER" --fold app 2>/dev/null | grep -q '^Stamp check: 1 file(s)'; then
    ok "WATCH_BRIDGE_STAMP_SLACK lowers the threshold"
  else bad "WATCH_BRIDGE_STAMP_SLACK lowers the threshold"; fi

  unset WATCH_BRIDGE_SETTLE
}

# --------------------------------------------------------------------------
# installer
# --------------------------------------------------------------------------

new_proj() { # $1=optional "bridge-section" -> path
  local p="$TMPROOT/proj.$RANDOM"; mkdir -p "$p"
  if [[ "${1:-}" == "bridge-section" ]]; then
    printf '# Demo\n\nText.\n\n## Bridge\n\nScan at start.\n\n## Other\n\nTail.\n' > "$p/CLAUDE.md"
  else
    printf '# Demo\n\nText only.\n' > "$p/CLAUDE.md"
  fi
  printf '%s' "$p"
}

test_install() {
  head_ "installer: placement and idempotence"
  local b; b="$(new_bridge)"; export SESSION_BRIDGE_DIR="$b"; check_safety

  local p; p="$(new_proj bridge-section)"
  bash "$INSTALLER" app "$p" >/dev/null 2>&1
  if [[ "$(grep -c 'Bridge push (watcher)' "$p/CLAUDE.md")" == 1 ]]; then ok "paragraph inserted once"
  else bad "paragraph inserted once"; fi
  # must land inside the Bridge section, i.e. before "## Other"
  local para other
  para="$(grep -n 'Bridge push (watcher)' "$p/CLAUDE.md" | cut -d: -f1)"
  other="$(grep -n '^## Other' "$p/CLAUDE.md" | cut -d: -f1)"
  if [[ "$para" -lt "$other" ]]; then ok "inserted at the end of the bridge section"
  else bad "inserted at the end of the bridge section" "paragraph $para, ## Other $other"; fi

  local before; before="$(md5sum < "$p/CLAUDE.md")"
  bash "$INSTALLER" app "$p" >/dev/null 2>&1
  if [[ "$before" == "$(md5sum < "$p/CLAUDE.md")" ]]; then ok "second run changes nothing"
  else bad "second run changes nothing"; fi

  p="$(new_proj)"
  bash "$INSTALLER" app "$p" >/dev/null 2>&1
  if grep -q 'Bridge push (watcher)' "$p/CLAUDE.md"; then ok "file without a bridge section: appended"
  else bad "file without a bridge section: appended"; fi

  head_ "installer: dry-run and update"
  p="$(new_proj bridge-section)"
  before="$(md5sum < "$p/CLAUDE.md")"
  bash "$INSTALLER" -n app "$p" >/dev/null 2>&1
  if [[ "$before" == "$(md5sum < "$p/CLAUDE.md")" ]]; then ok "-n leaves the file untouched"
  else bad "-n leaves the file untouched"; fi

  bash "$INSTALLER" app "$p" >/dev/null 2>&1
  # Mark the paragraph's own first line, so this stays valid when the wording changes.
  sed -i '/^\*\*Bridge push (watcher):\*\*/s/$/ OUTDATED/' "$p/CLAUDE.md"
  bash "$INSTALLER" app "$p" 2>&1 | grep -q 'differs from the current wording' \
    && ok "outdated paragraph is detected, not silently replaced" \
    || bad "outdated paragraph is detected, not silently replaced"
  bash "$INSTALLER" -u app "$p" >/dev/null 2>&1
  if ! grep -q OUTDATED "$p/CLAUDE.md" && [[ "$(grep -c 'Bridge push (watcher)' "$p/CLAUDE.md")" == 1 ]]; then
    ok "-u replaces it, no duplicate"
  else bad "-u replaces it, no duplicate"; fi

  # Additions written BELOW the paragraph must survive an update.
  printf '\nOur own note below the paragraph.\n' >> "$p/CLAUDE.md"
  bash "$INSTALLER" -u app "$p" >/dev/null 2>&1
  grep -q 'Our own note below the paragraph.' "$p/CLAUDE.md" \
    && ok "-u keeps additions below the paragraph" \
    || bad "-u keeps additions below the paragraph"

  head_ "installer: CRLF files keep their line endings"
  p="$(new_proj bridge-section)"
  sed -i 's/$/\r/' "$p/CLAUDE.md"
  bash "$INSTALLER" app "$p" >/dev/null 2>&1
  if grep -qU $'\r' "$p/CLAUDE.md" && ! grep -qU $'[^\r]$' "$p/CLAUDE.md"; then
    ok "every line still ends with CR"
  else
    bad "every line still ends with CR" "$(grep -cU $'[^\r]$' "$p/CLAUDE.md") line(s) without CR"
  fi
  bash "$INSTALLER" app "$p" 2>&1 | grep -q 'is current' \
    && ok "CRLF paragraph is recognised as current (no endless rewrite)" \
    || bad "CRLF paragraph is recognised as current (no endless rewrite)"

  head_ "installer: unknown session id"
  printf '# Bridge\n\n| id | session |\n|---|---|\n| `app` | demo |\n' > "$b/README.md"
  p="$(new_proj)"
  bash "$INSTALLER" nosuchid "$p" >/dev/null 2>&1
  assert_eq "unknown id aborts (typo protection)" "1" "$?"
  bash "$INSTALLER" -f nosuchid "$p" >/dev/null 2>&1
  assert_eq "-f forces it through" "0" "$?"
  rm -f "$b/README.md"

  head_ "installer: shared CLAUDE.md (several checkouts, one file)"
  d="$TMPROOT/shared.$RANDOM"; mkdir -p "$d"
  printf '# P\n\n## Bridge\n\nx\n' > "$d/CLAUDE.md"

  bash "$INSTALLER" -f -s app "$d" >/dev/null 2>&1
  if grep -qF 'watch-bridge.sh $(head -1 .session-id)' "$d/CLAUDE.md"; then
    ok "-s writes the .session-id expression instead of the id"
  else bad "-s writes the .session-id expression instead of the id" "$(sed -n '1,30p' "$d/CLAUDE.md")"; fi
  if grep -qE 'watch-bridge\.sh app( |$)' "$d/CLAUDE.md"; then
    bad "-s leaves no fixed id as a command argument" "$(grep -n 'watch-bridge.sh app' "$d/CLAUDE.md")"
  else ok "-s leaves no fixed id as a command argument"; fi

  # The point of the whole exercise: a plain -u must not undo it.
  out="$(bash "$INSTALLER" -f -u app "$d" 2>&1)"
  if printf '%s\n' "$out" | grep -q 'keeping the shared variant'; then
    ok "-u without -s recognises the shared variant"
  else bad "-u without -s recognises the shared variant" "$out"; fi
  if grep -qF 'watch-bridge.sh $(head -1 .session-id)' "$d/CLAUDE.md"; then
    ok "-u without -s does NOT write the fixed id back"
  else bad "-u without -s does NOT write the fixed id back" "$(sed -n '1,30p' "$d/CLAUDE.md")"; fi
  if printf '%s\n' "$out" | grep -q 'is current — unchanged'; then
    ok "the shared paragraph is idempotent"
  else bad "the shared paragraph is idempotent" "$out"; fi

  # Converting an existing fixed paragraph, and the fixed form staying idempotent.
  d2="$TMPROOT/fixed.$RANDOM"; mkdir -p "$d2"
  printf '# P\n\n## Bridge\n\nx\n' > "$d2/CLAUDE.md"
  bash "$INSTALLER" -f app "$d2" >/dev/null 2>&1
  out="$(bash "$INSTALLER" -f -u app "$d2" 2>&1)"
  if printf '%s\n' "$out" | grep -q 'is current — unchanged'; then
    ok "the fixed paragraph stays idempotent"
  else bad "the fixed paragraph stays idempotent" "$out"; fi
  bash "$INSTALLER" -f -s -u app "$d2" >/dev/null 2>&1
  if grep -qF 'watch-bridge.sh $(head -1 .session-id)' "$d2/CLAUDE.md"; then
    ok "-s -u converts a fixed paragraph to the shared form"
  else bad "-s -u converts a fixed paragraph to the shared form" "$(sed -n '1,30p' "$d2/CLAUDE.md")"; fi
  if [[ "$(grep -c 'Bridge push (watcher)' "$d2/CLAUDE.md")" == "1" ]]; then
    ok "conversion replaces the paragraph, it does not add a second one"
  else bad "conversion replaces the paragraph, it does not add a second one" \
       "$(grep -c 'Bridge push (watcher)' "$d2/CLAUDE.md")"; fi

  head_ "installer: allow-rules"
  if command -v node >/dev/null 2>&1; then
    p="$(new_proj)"
    bash "$INSTALLER" app "$p" >/dev/null 2>&1
    if [[ -f "$p/.claude/settings.local.json" ]] \
       && grep -q 'watch-bridge.sh:\*' "$p/.claude/settings.local.json"; then
      ok "allow-rules written"
    else bad "allow-rules written"; fi
    local n; n="$(grep -c 'watch-bridge.sh:\*' "$p/.claude/settings.local.json")"
    bash "$INSTALLER" app "$p" >/dev/null 2>&1
    assert_eq "allow-rules are not duplicated" "$n" "$(grep -c 'watch-bridge.sh:\*' "$p/.claude/settings.local.json")"
  else
    printf '  skip node not available — allow-rule tests skipped\n'
  fi
}

# --------------------------------------------------------------------------
# number assignment (--numbers)
# --------------------------------------------------------------------------

# --numbers reads the AUTHOR out of the file name, so these messages need real ones:
# <timestamp>__<author>__<rand>.md
post_named() { # $1=bridge $2=area(threads|_archiv) $3=slug $4=timestamp $5=author
  mkdir -p "$1/$2/$3/msgs"
  printf -- '---\nfrom: %s\nto: someone\ntype: fyi\ndate: 2026-01-01T00:00:00Z\n---\n\nbody\n' \
    "$5" > "$1/$2/$3/msgs/$4__$5__ab12.md"
}

test_new_thread() {
  head_ "watcher: handing out a thread number (--new-thread)"
  local b; b="$(new_bridge)"; export SESSION_BRIDGE_DIR="$b"; check_safety
  mkdir -p "$b/_archiv/151-archived/msgs" "$b/threads/069-fanout-a/msgs"

  # The archived thread carries the highest number. A scan that reads threads/ only
  # hands out a number that is already taken -- that is how most collisions in the
  # live bridge happened, not by two sessions racing.
  assert_eq "next free number counts the archive too" "152-demo" \
    "$(WATCH_BRIDGE_SETTLE=0 bash "$WATCHER" --new-thread demo)"
  assert_eq "the thread folder is created with msgs/" "yes" \
    "$([[ -d "$b/threads/152-demo/msgs" ]] && echo yes || echo no)"

  # A deliberate series (a fan-out to several recipients under one number) has to stay
  # possible, and 069 must not be read as octal.
  assert_eq "a forced number creates a second thread under it" "069-fanout-b" \
    "$(WATCH_BRIDGE_SETTLE=0 bash "$WATCHER" --new-thread fanout-b 69 2>/dev/null)"

  WATCH_BRIDGE_SETTLE=0 bash "$WATCHER" --new-thread 007-wrong >/dev/null 2>&1
  assert_eq "a slug that already carries a number is refused" "2" "$?"

  bash "$WATCHER" --new-thread >/dev/null 2>&1
  assert_eq "--new-thread without a slug -> usage, exit 64" "64" "$?"
  # --- the fan-out note, and the order it is printed in ---------------------
  b="$(new_bridge)"; export SESSION_BRIDGE_DIR="$b"; check_safety
  export WATCH_BRIDGE_SETTLE=0
  mkdir -p "$b/threads/007-first/msgs"

  out="$(bash "$WATCHER" --new-thread second 007 2>&1)"
  if printf '%s\n' "$out" | grep -q 'NOTE: series 007 now spans 2 threads'; then
    ok "a series prints the sibling-threads note with the right count"
  else bad "a series prints the sibling-threads note with the right count" "$out"; fi

  out="$(bash "$WATCHER" --new-thread third 007 2>&1)"
  if printf '%s\n' "$out" | grep -q 'spans 3 threads'; then
    ok "the count grows with the series"
  else bad "the count grows with the series" "$out"; fi

  out="$(bash "$WATCHER" --new-thread solo 2>&1)"
  if printf '%s\n' "$out" | grep -q 'NOTE: series'; then
    bad "an ordinary thread gets no series note" "$out"
  else ok "an ordinary thread gets no series note"; fi

  # The note is three lines on stderr. Printed BEFORE the mkdir, a caller truncating
  # the output closes the pipe and SIGPIPE kills the script before the directory
  # exists -- that happened during development, silently. Whether SIGPIPE actually
  # lands is a race, though: a runtime test for it stayed green with the order broken,
  # so it guarded nothing. We assert the ORDER IN THE SOURCE instead -- structural
  # rather than behavioural, and said out loud rather than dressed up.
  if awk '/^  mkdir -p "\$dir\/msgs"/ {m=NR} /NOTE: series/ {n=NR}
          END {exit !(m && n && m < n)}' "$WATCHER"; then
    ok "the mkdir comes before the series note (creating precedes reporting)"
  else bad "the mkdir comes before the series note (creating precedes reporting)"; fi

  unset WATCH_BRIDGE_SETTLE
  unset SESSION_BRIDGE_DIR
}

test_numbers() {
  head_ "watcher: duplicate thread numbers (--numbers)"
  local b="$TMPROOT/numbers.$RANDOM"
  mkdir -p "$b/threads" "$b/_archiv"
  export SESSION_BRIDGE_DIR="$b"; check_safety

  # A quiet bridge: one number, one thread.
  post_named "$b" threads 010-quiet 20260101T000000Z app
  bash "$WATCHER" --numbers 2>/dev/null | grep -q 'no number used twice' \
    && ok "--numbers says so plainly when nothing is duplicated" \
    || bad "--numbers says so plainly when nothing is duplicated"

  # A deliberate fan-out: same number, same author, seconds apart -> SERIES, not a defect.
  post_named "$b" threads 020-fanout-app  20260102T090000Z app
  post_named "$b" threads 020-fanout-site 20260102T090003Z app
  local out; out="$(bash "$WATCHER" --numbers 2>/dev/null)"
  if printf '%s\n' "$out" | grep -qE '^020  SERIES .*2 threads, 1 author'; then
    ok "--numbers calls a one-author fan-out a SERIES"
  else bad "--numbers calls a one-author fan-out a SERIES" "$out"; fi

  # A real collision, with one of the two already archived: the number stays taken.
  post_named "$b" threads 030-first  20260103T080000Z app
  post_named "$b" _archiv 030-second 20260103T140000Z site
  out="$(bash "$WATCHER" --numbers 2>/dev/null)"
  if printf '%s\n' "$out" | grep -qE '^030  COLLISION .*2 threads, 2 author'; then
    ok "--numbers finds a collision across threads/ and _archiv/"
  else bad "--numbers finds a collision across threads/ and _archiv/" "$out"; fi
  if printf '%s\n' "$out" | grep -q '2 numbers used more than once: 1 collision(s), 1 pure series'; then
    ok "--numbers counts collisions and series separately"
  else bad "--numbers counts collisions and series separately" "$out"; fi

  bash "$WATCHER" --numbers >/dev/null 2>&1
  assert_eq "--numbers exits 0" "0" "$?"
  unset SESSION_BRIDGE_DIR
}

# --------------------------------------------------------------------------

# --------------------------------------------------------------------------
# coverage: a running session with no watcher
# --------------------------------------------------------------------------
# Two branches that must be tested separately, because the check is deliberately
# platform-dependent: with a process inventory it reports, without one it has to
# stay silent (it cannot know whether a watcher runs, so every session would look
# unarmed). The silent branch is the one CI on Linux exercises; the reporting
# branch needs PowerShell and is skipped elsewhere — stated, not swallowed.

has_inventory() { command -v powershell.exe >/dev/null 2>&1; }

# A README with a participant table, which is what the cwd is matched against.
# $2 optionally prefixes the paths with a real directory, for the tests that
# actually chdir into them: the script compares RESOLVED paths, so the table has
# to carry the same spelling the shell reports from inside (on Windows that is
# the drive-letter form, not the msys one).
write_readme() { # $1=bridge [$2=real base directory]
  local pre=""
  [[ -n "${2:-}" ]] && pre="$(cd "$2" && { pwd -W 2>/dev/null || pwd; })"
  cat > "$1/README.md" <<MD
# example bridge

| id | session | repo / working dir |
|---|---|---|
| \`app-product\` | product side | \`$pre/repos/app-product\` (\`main\`) |
| \`app\` | the application | \`$pre/repos/app\` (\`main\`) |
| \`mail\` | inbox | \`$pre/repos/mail\` |
MD
}

# One session entry, shaped like the real registry (JSON, escaped backslashes
# allowed — both spellings must normalise to the same path).
write_session() { # $1=registry-dir $2=pid $3=cwd $4=name
  mkdir -p "$1/sessions"
  printf '{"pid":%s,"sessionId":"t","cwd":"%s","name":"%s","kind":"interactive","status":"shell"}\n' \
    "$2" "$3" "$4" > "$1/sessions/$2.json"
}

# A pid the check will accept as alive: on a machine with running claude
# processes it has to be one of them, otherwise the liveness filter is skipped
# anyway and any number does.
usable_pid() {
  local p=""
  has_inventory && p="$(powershell.exe -NoProfile -NonInteractive -Command \
    '(Get-Process -Name claude -ErrorAction SilentlyContinue).Id' 2>/dev/null | tr -d '\r' | head -1)"
  printf '%s' "${p:-4242}"
}

test_coverage() {
  local b reg out pid
  head_ "watcher: coverage (running session without a watcher)"
  b="$(new_bridge)"; export SESSION_BRIDGE_DIR="$b"; check_safety
  write_readme "$b"
  reg="$TMPROOT/cfg.$RANDOM"
  pid="$(usable_pid)"

  if has_inventory; then
    write_session "$reg" "$pid" '/repos/app' 'Some Window Name'
    out="$(CLAUDE_CONFIG_DIR="$reg" bash "$WATCHER" --status 2>/dev/null)"
    if printf '%s\n' "$out" | grep -q '^UNARMED: 1 running session'; then
      ok "a running session with no watcher is reported"
    else bad "a running session with no watcher is reported" "$out"; fi
    if printf '%s\n' "$out" | grep -q 'app .*window "Some Window Name"'; then
      ok "the report names the participant id and the window"
    else bad "the report names the participant id and the window" "$out"; fi

    # The whole path is compared: '/repos/app' must not match the row of
    # 'app-product', whose path merely starts with it. The table lists
    # 'app-product' FIRST on purpose — that is what makes this test able to fail.
    # With the shorter id first, any prefix match would still land on the right
    # row by accident and the test would guard nothing (it did, until a mutation
    # run showed it staying green while the comparison was broken).
    if printf '%s\n' "$out" | grep -q 'app-product'; then
      bad "paths are matched whole, not as a substring" "$out"
    else ok "paths are matched whole, not as a substring"; fi

    # Escaped backslashes normalise to the same path as forward slashes.
    rm -rf "$reg"
    write_session "$reg" "$pid" '\\repos\\app' 'Backslash Window'
    out="$(CLAUDE_CONFIG_DIR="$reg" bash "$WATCHER" --status 2>/dev/null)"
    if printf '%s\n' "$out" | grep -q '^UNARMED'; then
      ok "a backslash cwd normalises to the same path"
    else bad "a backslash cwd normalises to the same path" "$out"; fi

    # A directory the README does not list is not a participant.
    rm -rf "$reg"
    write_session "$reg" "$pid" '/repos/something-else' 'Stranger'
    out="$(CLAUDE_CONFIG_DIR="$reg" bash "$WATCHER" --status 2>/dev/null)"
    if printf '%s\n' "$out" | grep -q 'UNARMED'; then
      bad "a session outside the participant table raises no alarm" "$out"
    else ok "a session outside the participant table raises no alarm"; fi

    # No README, no check — adding one later switches the check on, exactly like
    # the id validation in install-watcher.sh.
    rm -rf "$reg"; write_session "$reg" "$pid" '/repos/app' 'App'
    rm -f "$b/README.md"
    out="$(CLAUDE_CONFIG_DIR="$reg" bash "$WATCHER" --status 2>/dev/null)"
    if printf '%s\n' "$out" | grep -q 'UNARMED'; then
      bad "without a README the check stays off" "$out"
    else ok "without a README the check stays off"; fi
    write_readme "$b"
  else
    printf '  skip %s\n' "reporting branch needs a process inventory (PowerShell)"
  fi

  # The silent branch: no process inventory means no statement, even though the
  # registry clearly shows a running session. PATH is emptied of PowerShell to
  # reach this branch on a machine that has one.
  rm -rf "$reg"; write_session "$reg" "$pid" '/repos/app' 'App'
  out="$(PATH=/usr/bin:/bin CLAUDE_CONFIG_DIR="$reg" bash "$WATCHER" --status 2>/dev/null)"
  if printf '%s\n' "$out" | grep -q 'UNARMED'; then
    bad "without a process inventory the check says nothing" "$out"
  else ok "without a process inventory the check says nothing"; fi

  CLAUDE_CONFIG_DIR="$reg" bash "$WATCHER" --status >/dev/null 2>&1
  assert_eq "--status still exits 0 with the coverage check in place" "0" "$?"
  unset SESSION_BRIDGE_DIR
}

# --------------------------------------------------------------------------

# --------------------------------------------------------------------------
# the id against the working directory
# --------------------------------------------------------------------------
# The failure this guards against is invisible from every angle but this one:
# a session in a second checkout arms under the main checkout's id, its arm
# steps aside because that id is already served, and `--status` reports the id
# as delivering while the session gets nothing.

test_checkout() {
  local b out here
  head_ "watcher: id against working directory"
  b="$(new_bridge)"; export SESSION_BRIDGE_DIR="$b"; check_safety
  export WATCH_BRIDGE_SETTLE=0
  here="$TMPROOT/wt.$RANDOM"
  mkdir -p "$here/repos/app" "$here/repos/app-bgd" "$here/repos/app-product" "$here/elsewhere"
  write_readme "$b" "$here"  # app-product before app — the ordering that matters

  # A directory registered for the id: silent.
  out="$(cd "$here/repos/app" && SESSION_BRIDGE_DIR="$b" bash "$WATCHER" --fold app 2>/dev/null)"
  if printf '%s\n' "$out" | grep -q 'SUSPECT'; then
    bad "no note when the id matches its registered directory" "$out"
  else ok "no note when the id matches its registered directory"; fi

  # A subdirectory of it: still silent.
  mkdir -p "$here/repos/app/src/deep"
  out="$(cd "$here/repos/app/src/deep" && SESSION_BRIDGE_DIR="$b" bash "$WATCHER" --fold app 2>/dev/null)"
  if printf '%s\n' "$out" | grep -q 'SUSPECT'; then
    bad "no note from a subdirectory of the registered path" "$out"
  else ok "no note from a subdirectory of the registered path"; fi

  # The incident: a sibling checkout whose name merely starts with the id.
  out="$(cd "$here/repos/app-bgd" && SESSION_BRIDGE_DIR="$b" bash "$WATCHER" --fold app 2>/dev/null)"
  if printf '%s\n' "$out" | grep -q "^SUSPECT: id 'app'"; then
    ok "a sibling checkout starting with the id is flagged"
  else bad "a sibling checkout starting with the id is flagged" "$out"; fi
  if printf '%s\n' "$out" | grep -q "mean 'app-bgd'"; then
    ok "the note proposes the directory name as the likely id"
  else bad "the note proposes the directory name as the likely id" "$out"; fi

  # The note must come BEFORE the thread list, or it is read too late.
  post_state "$b" 001-test 100-a other app OPEN
  out="$(cd "$here/repos/app-bgd" && SESSION_BRIDGE_DIR="$b" bash "$WATCHER" --fold app 2>/dev/null)"
  if [[ "$(printf '%s\n' "$out" | grep -n 'SUSPECT' | head -1 | cut -d: -f1)" \
        -lt "$(printf '%s\n' "$out" | grep -n '^THREAD' | head -1 | cut -d: -f1)" ]]; then
    ok "the note is printed above the thread list"
  else bad "the note is printed above the thread list" "$out"; fi

  # A directory registered for ANOTHER participant: name that participant.
  out="$(cd "$here/repos/app-product" && SESSION_BRIDGE_DIR="$b" bash "$WATCHER" --fold app 2>/dev/null)"
  if printf '%s\n' "$out" | grep -q "maps it to 'app-product'"; then
    ok "a directory owned by another participant names that participant"
  else bad "a directory owned by another participant names that participant" "$out"; fi

  # An id that is not in the table at all: no statement.
  out="$(cd "$here/elsewhere" && SESSION_BRIDGE_DIR="$b" bash "$WATCHER" --fold not-a-participant 2>/dev/null)"
  if printf '%s\n' "$out" | grep -q 'SUSPECT'; then
    bad "an unregistered id produces no statement" "$out"
  else ok "an unregistered id produces no statement"; fi

  # .session-id wins over the table and is checked in both halves.
  printf 'app\n%s\n' "$here/elsewhere" > "$here/elsewhere/.session-id"
  out="$(cd "$here/elsewhere" && SESSION_BRIDGE_DIR="$b" bash "$WATCHER" --fold mail 2>/dev/null)"
  if printf '%s\n' "$out" | grep -q "says 'app'"; then
    ok ".session-id naming a different id is flagged"
  else bad ".session-id naming a different id is flagged" "$out"; fi

  printf 'app\n%s\n' "$here/repos/app" > "$here/elsewhere/.session-id"
  out="$(cd "$here/elsewhere" && SESSION_BRIDGE_DIR="$b" bash "$WATCHER" --fold app 2>/dev/null)"
  if printf '%s\n' "$out" | grep -q 'copied working tree'; then
    ok ".session-id issued for another tree is flagged (the copy case)"
  else bad ".session-id issued for another tree is flagged (the copy case)" "$out"; fi

  printf 'app\n%s\n' "$here/elsewhere" > "$here/elsewhere/.session-id"
  out="$(cd "$here/elsewhere" && SESSION_BRIDGE_DIR="$b" bash "$WATCHER" --fold app 2>/dev/null)"
  if printf '%s\n' "$out" | grep -q 'SUSPECT'; then
    bad "a consistent .session-id silences the table check" "$out"
  else ok "a consistent .session-id silences the table check"; fi

  unset WATCH_BRIDGE_SETTLE SESSION_BRIDGE_DIR
}

# --------------------------------------------------------------------------
# launcher
# --------------------------------------------------------------------------

test_launcher() {
  head_ "launcher: is a session already running? (registry, exact match, live pid only)"
  local cfg="$TMPROOT/cfg.$RANDOM"; mkdir -p "$cfg/sessions"
  reg() { # $1=file $2=pid ('' = no pid field) $3=cwd tail under D:\work $4=name
    if [[ -n "$2" ]]; then
      printf '{"pid":%s,"cwd":"D:\\\\work\\\\%s","name":"%s","status":"idle"}' "$2" "$3" "$4"
    else
      printf '{"cwd":"D:\\\\work\\\\%s","name":"%s","status":"idle"}' "$3" "$4"
    fi > "$cfg/sessions/$1.json"
  }
  reg dead  4242 deadproj deadproj      # pid not alive: a leftover from a reboot
  reg live  1717 liveproj liveproj      # alive
  reg nopid ''   nopid    nopid         # no pid field at all
  reg pfx   1717 app      appx          # prefix traps: cwd D:\work\app, name appx
  local out
  run() { # $1=name $2=dir [$3=CC_LIVE_PIDS override] [$4=config dir override]
    ( export CLAUDE_CONFIG_DIR="${4-$cfg}" CC_LIVE_PIDS="${3-1717}"
      # shellcheck source=/dev/null
      source "$ROOT/launcher/_lib.sh"
      cc_session_running "$1" "$2" && echo running || echo not )
  }
  assert_eq "a live entry matched by name counts as running"        "running" "$(run liveproj /d/work/liveproj)"
  assert_eq "a live entry matched by cwd alone counts as running"    "running" "$(run other /d/work/liveproj)"
  assert_eq "a dead pid is a leftover and does not count"            "not"     "$(run deadproj /d/work/deadproj)"
  assert_eq "an entry without a pid field does not count"            "not"     "$(run nopid /d/work/nopid)"
  assert_eq "cwd is matched whole: app does not cover app-product"   "not"     "$(run app /d/work/app-product)"
  assert_eq "name is matched whole: app does not cover appx"         "not"     "$(run app /d/work/somewhere)"
  assert_eq "after a reboot (no claude alive) nothing counts"        "not"     "$(run liveproj /d/work/liveproj '')"
  assert_eq "the injected pid list decides, not the file"            "running" "$(run deadproj /d/work/deadproj 4242)"
  assert_eq "no registry at all -> not running (start proceeds)"     "not"     "$(run liveproj /d/work/liveproj 1717 "$TMPROOT/none.$RANDOM")"
}

# --------------------------------------------------------------------------
# launcher: pull before the start
# --------------------------------------------------------------------------

test_pull() {
  head_ "launcher: pull from 'vps' before the start (fast-forward only, never fatal)"
  local root="$TMPROOT/pull.$RANDOM"; mkdir -p "$root"
  local G="git -c user.name=t -c user.email=t@t -c init.defaultBranch=main"
  $G init -q --bare "$root/bare.git"   # $G: the bare HEAD must name the same default branch
  $G init -q "$root/a"
  ( cd "$root/a" && echo one > f && $G add f && $G commit -qm one && git remote add vps "$root/bare.git" && git push -q vps HEAD:main )
  git clone -q "$root/bare.git" "$root/b"; ( cd "$root/b" && git remote rename origin vps )
  ( cd "$root/a" && echo two > f && $G commit -qam two && git push -q vps HEAD:main )
  pull() { # $1=dir [$2=CC_NO_PULL] [$3=CC_PULL_REMOTE] -> stderr lines + "rc=N"
    ( export CC_NO_PULL="${2:-0}" CC_PULL_REMOTE="${3:-}"
      # shellcheck source=/dev/null
      source "$ROOT/launcher/_lib.sh"
      cc_pull_before_start proj "$1" 2>&1; echo "rc=$?" )
  }
  local out
  out="$(pull "$root/b")"
  assert_eq "a fast-forward pull catches up" "two" "$(cat "$root/b/f")"
  if printf '%s\n' "$out" | grep -q 'caught up'; then ok "... and says so"; else bad "... and says so" "$out"; fi
  out="$(pull "$root/b")"
  if printf '%s\n' "$out" | grep -q '^\[pull\]'; then bad "nothing to pull -> silent" "$out"; else ok "nothing to pull -> silent"; fi
  # local changes in the way: reported, not fatal, tree untouched
  ( cd "$root/a" && echo three > f && $G commit -qam three && git push -q vps HEAD:main )
  echo local > "$root/b/f"
  out="$(pull "$root/b")"
  assert_eq "a pull that would overwrite local changes leaves the tree alone" "local" "$(cat "$root/b/f")"
  if printf '%s\n' "$out" | grep -q 'NOT pulled'; then ok "... and reports it"; else bad "... and reports it" "$out"; fi
  if printf '%s\n' "$out" | grep -q '^rc=0$'; then ok "... and returns 0 (the pull never decides about the start)"; else bad "... and returns 0" "$out"; fi
  git -C "$root/b" checkout -q -- f
  out="$(pull "$root/b" 1)"
  assert_eq "CC_NO_PULL=1 skips the pull" "two" "$(cat "$root/b/f")"
  assert_eq "... silently" "rc=0" "$out"
  # a clone with an upstream but no CC_PULL_REMOTE: the upstream is used
  git clone -q "$root/bare.git" "$root/c"
  ( cd "$root/a" && echo four > f && $G commit -qam four && git push -q vps HEAD:main )
  pull "$root/c" >/dev/null
  assert_eq "without CC_PULL_REMOTE the upstream is used" "four" "$(cat "$root/c/f")"
  # CC_PULL_REMOTE wins where it exists, and is ignored where it does not
  ( cd "$root/a" && echo five > f && $G commit -qam five && git push -q vps HEAD:main )
  pull "$root/b" 0 vps >/dev/null
  assert_eq "CC_PULL_REMOTE names the remote to use" "five" "$(cat "$root/b/f")"
  ( cd "$root/a" && echo six > f && $G commit -qam six && git push -q vps HEAD:main )
  pull "$root/c" 0 nosuch >/dev/null
  assert_eq "an unknown CC_PULL_REMOTE falls back to the upstream" "six" "$(cat "$root/c/f")"
  # neither: said, not pulled
  $G init -q "$root/d"; ( cd "$root/d" && echo x > f && $G add f && $G commit -qm x )
  out="$(pull "$root/d")"
  if printf '%s\n' "$out" | grep -q 'no upstream'; then ok "no upstream and no CC_PULL_REMOTE -> said, not pulled"; else bad "no upstream and no CC_PULL_REMOTE -> said, not pulled" "$out"; fi
  # not a repo: silent
  mkdir -p "$root/e"
  assert_eq "not a repo -> silent, rc 0" "rc=0" "$(pull "$root/e")"
}

# --------------------------------------------------------------------------
# link-memory: profile memory -> repo, linked
# --------------------------------------------------------------------------

test_linkmemory() {
  head_ "link-memory: profile memory moves into the repo, profile path becomes a link"
  local LM="$ROOT/launcher/link-memory.sh"
  local cfg="$TMPROOT/lmcfg.$RANDOM"; mkdir -p "$cfg"
  local repo="$TMPROOT/lmrepo.$RANDOM"; mkdir -p "$repo"
  # the slug the way Claude Code derives it (Windows form under msys, every non-alnum -> '-')
  local native slug mem out rc
  native="$(cygpath -w "$repo" 2>/dev/null || printf '%s' "$repo")"
  slug="$(printf '%s' "$native" | sed 's/[^A-Za-z0-9]/-/g')"
  mem="$cfg/projects/$slug/memory"
  mkdir -p "$mem"; echo idx > "$mem/MEMORY.md"; echo a > "$mem/a.md"
  rc=0; out="$(CLAUDE_CONFIG_DIR="$cfg" bash "$LM" -n "$repo" 2>&1)" || rc=$?
  assert_eq "-n: exit 0" "0" "$rc"
  assert_eq "-n changes nothing" "" "$(ls -A "$repo")"
  if printf '%s\n' "$out" | grep -qF '[move] 2 file(s) into the target'; then ok "-n announces the move"; else bad "-n announces the move" "$out"; fi
  rc=0; out="$(CLAUDE_CONFIG_DIR="$cfg" bash "$LM" "$repo" 2>&1)" || rc=$?
  assert_eq "link: exit 0" "0" "$rc"
  assert_eq "the files moved into the repo" "MEMORY.md a.md" "$(ls -A "$repo/memory" | LC_ALL=C sort | paste -sd' ' -)"
  assert_eq "ls through the link shows the repo" "MEMORY.md a.md" "$(ls -A "$mem" | LC_ALL=C sort | paste -sd' ' -)"
  echo b > "$mem/b.md"
  assert_eq "a write through the link lands in the repo" "b" "$(cat "$repo/memory/b.md")"
  rc=0; out="$(CLAUDE_CONFIG_DIR="$cfg" bash "$LM" "$repo" 2>&1)" || rc=$?
  if [[ $rc -eq 0 ]] && printf '%s\n' "$out" | grep -q 'already linked'; then ok "second run: already linked, exit 0"; else bad "second run: already linked, exit 0" "$out"; fi
  # same file, different content on both sides -> abort, nothing touched
  local cfg2="$TMPROOT/lmcfg2.$RANDOM" mem2; mem2="$cfg2/projects/$slug/memory"; mkdir -p "$mem2"
  echo other > "$mem2/a.md"; echo idx > "$mem2/MEMORY.md"
  rc=0; out="$(CLAUDE_CONFIG_DIR="$cfg2" bash "$LM" "$repo" 2>&1)" || rc=$?
  assert_eq "conflict -> exit 1" "1" "$rc"
  assert_eq "conflict -> profile untouched" "other idx" "$(cat "$mem2/a.md" "$mem2/MEMORY.md" | paste -sd' ' -)"
  assert_eq "conflict -> repo untouched" "a" "$(cat "$repo/memory/a.md")"
  if printf '%s\n' "$out" | grep -q 'a.md'; then ok "conflict names the file"; else bad "conflict names the file" "$out"; fi
  # no profile memory at all -> created and linked
  local cfg3="$TMPROOT/lmcfg3.$RANDOM"; mkdir -p "$cfg3"
  CLAUDE_CONFIG_DIR="$cfg3" bash "$LM" "$repo" >/dev/null 2>&1
  assert_eq "missing profile memory -> link created" "MEMORY.md a.md b.md" "$(ls -A "$cfg3/projects/$slug/memory" | LC_ALL=C sort | paste -sd' ' -)"
  # the index differs on both sides (the normal case for a second machine): merged, not a conflict
  local cfg4="$TMPROOT/lmcfg4.$RANDOM" mem4; mem4="$cfg4/projects/$slug/memory"; mkdir -p "$mem4"
  printf 'idx\n- [nb](nb.md) only here\n' > "$mem4/MEMORY.md"; echo nb > "$mem4/nb.md"; echo a > "$mem4/a.md"
  rc=0; out="$(CLAUDE_CONFIG_DIR="$cfg4" bash "$LM" "$repo" 2>&1)" || rc=$?
  assert_eq "index merge: exit 0" "0" "$rc"
  if printf '%s\n' "$out" | grep -q '^\[index\] MEMORY.md differs on both sides -- 1 line(s)'; then ok "index merge is announced with the line count"; else bad "index merge is announced with the line count" "$out"; fi
  assert_eq "index merge: repo lines first, then the profile-only line" "idx - [nb](nb.md) only here" "$(paste -sd' ' "$repo/memory/MEMORY.md")"
  assert_eq "index merge: the profile-only file moved as well" "nb" "$(cat "$repo/memory/nb.md")"
  assert_eq "index merge: no backup left behind" "" "$(ls "$repo/memory" | grep pre-link)"
  rc=0; out="$(CLAUDE_CONFIG_DIR="$cfg4" bash "$LM" "$repo" 2>&1)" || rc=$?
  if [[ $rc -eq 0 ]] && printf '%s\n' "$out" | grep -q 'already linked'; then ok "index merge: second run already linked"; else bad "index merge: second run already linked" "$out"; fi

  # --cloud: the target is <SESSION_MEMORY_DIR>/<id>, the repo stays untouched
  local cloud="$TMPROOT/lmcloud.$RANDOM"; mkdir -p "$cloud"
  local cfg5="$TMPROOT/lmcfg5.$RANDOM" repo5 slug5 mem5
  repo5="$TMPROOT/lmrepo5.$RANDOM"; mkdir -p "$repo5"
  slug5="$(printf '%s' "$(cygpath -w "$repo5" 2>/dev/null || printf '%s' "$repo5")" | sed 's/[^A-Za-z0-9]/-/g')"
  mem5="$cfg5/projects/$slug5/memory"; mkdir -p "$mem5"; echo idx > "$mem5/MEMORY.md"
  rc=0; out="$(CLAUDE_CONFIG_DIR="$cfg5" bash "$LM" --cloud "$repo5" 2>&1)" || rc=$?
  assert_eq "--cloud without SESSION_MEMORY_DIR: refused, not guessed" "1" "$rc"
  if printf '%s\n' "$out" | grep -q 'no sync folder configured'; then ok "... and says how to configure it"; else bad "... and says how to configure it" "$out"; fi
  rc=0; out="$(SESSION_MEMORY_DIR="$cloud" CLAUDE_CONFIG_DIR="$cfg5" bash "$LM" --cloud "$repo5" 2>&1)" || rc=$?
  assert_eq "--cloud: exit 0" "0" "$rc"
  assert_eq "--cloud: the id defaults to the directory name" "MEMORY.md" "$(ls -A "$cloud/${repo5##*/}" 2>/dev/null)"
  assert_eq "--cloud: nothing lands in the repo" "" "$(ls -A "$repo5")"
  assert_eq "--cloud: ls through the link shows the cloud folder" "MEMORY.md" "$(ls -A "$mem5")"
  if printf '%s\n' "$out" | grep -q 'no commit'; then ok "--cloud: the closing line says no commit is needed"; else bad "--cloud: the closing line says no commit is needed" "$out"; fi
  # .session-id (line 1) names the folder; --name overrides it
  local cfg6="$TMPROOT/lmcfg6.$RANDOM" repo6
  repo6="$TMPROOT/lmrepo6.$RANDOM"; mkdir -p "$repo6"; printf 'app-x\n/some/tree\n' > "$repo6/.session-id"
  SESSION_MEMORY_DIR="$cloud" CLAUDE_CONFIG_DIR="$cfg6" bash "$LM" --cloud "$repo6" >/dev/null 2>&1
  if [[ -d "$cloud/app-x" ]]; then ok "--cloud: line 1 of .session-id names the folder"; else bad "--cloud: line 1 of .session-id names the folder" "$(ls "$cloud")"; fi
  local cfg7="$TMPROOT/lmcfg7.$RANDOM"
  SESSION_MEMORY_DIR="$cloud" CLAUDE_CONFIG_DIR="$cfg7" bash "$LM" --cloud --name custom "$repo6" >/dev/null 2>&1
  if [[ -d "$cloud/custom" ]]; then ok "--cloud --name wins over .session-id"; else bad "--cloud --name wins over .session-id" "$(ls "$cloud")"; fi
  # the id is lower-cased whatever its source -- two machines must not create two folders
  local cfg8="$TMPROOT/lmcfg8.$RANDOM"
  SESSION_MEMORY_DIR="$cloud" CLAUDE_CONFIG_DIR="$cfg8" bash "$LM" --cloud --name MiXeD "$repo6" >/dev/null 2>&1
  if [[ -d "$cloud/mixed" ]]; then ok "--name is lower-cased"; else bad "--name is lower-cased" "$(ls "$cloud")"; fi
  local cfg9="$TMPROOT/lmcfg9.$RANDOM" repo9
  repo9="$TMPROOT/Capitalised.$RANDOM"; mkdir -p "$repo9"
  SESSION_MEMORY_DIR="$cloud" CLAUDE_CONFIG_DIR="$cfg9" bash "$LM" --cloud "$repo9" >/dev/null 2>&1
  if [[ -d "$cloud/$(printf '%s' "${repo9##*/}" | tr 'A-Z' 'a-z')" ]]; then
    ok "a capitalised directory name is lower-cased too"
  else bad "a capitalised directory name is lower-cased too" "$(ls "$cloud")"; fi
  local cfg10="$TMPROOT/lmcfg10.$RANDOM" repo10
  repo10="$TMPROOT/lmrepo10.$RANDOM"; mkdir -p "$repo10"; printf 'App-X\n' > "$repo10/.session-id"
  SESSION_MEMORY_DIR="$cloud" CLAUDE_CONFIG_DIR="$cfg10" bash "$LM" --cloud "$repo10" >/dev/null 2>&1
  if [[ -d "$cloud/app-x" ]]; then ok "a capitalised .session-id is lower-cased too"; else bad "a capitalised .session-id is lower-cased too" "$(ls "$cloud")"; fi
  rc=0; SESSION_MEMORY_DIR="$cloud" CLAUDE_CONFIG_DIR="$cfg7" bash "$LM" --name custom "$repo6" >/dev/null 2>&1 || rc=$?
  assert_eq "--name without --cloud is a usage error" "64" "$rc"
  # a link that points elsewhere (repo -> cloud switch) is refused, nothing touched
  rc=0; out="$(SESSION_MEMORY_DIR="$cloud" CLAUDE_CONFIG_DIR="$cfg" bash "$LM" --cloud "$repo" 2>&1)" || rc=$?
  assert_eq "a link to another target is refused" "1" "$rc"
  if printf '%s\n' "$out" | grep -q '\-\-relink'; then ok "... and the message names --relink"; else bad "... and the message names --relink" "$out"; fi

  # --- --relink case 1: repo mode -> cloud mode, old target inside the repo ---
  local cfgR="$TMPROOT/rlcfg.$RANDOM" repoR slugR memR cloudR
  repoR="$TMPROOT/rlrepo.$RANDOM"; mkdir -p "$repoR/memory"; cloudR="$TMPROOT/rlcloud.$RANDOM"; mkdir -p "$cloudR"
  echo idx > "$repoR/memory/MEMORY.md"; echo a > "$repoR/memory/a.md"
  slugR="$(printf '%s' "$(cygpath -w "$repoR" 2>/dev/null || printf '%s' "$repoR")" | sed 's/[^A-Za-z0-9]/-/g')"
  memR="$cfgR/projects/$slugR/memory"; mkdir -p "$(dirname "$memR")"
  CLAUDE_CONFIG_DIR="$cfgR" bash "$LM" "$repoR" >/dev/null 2>&1     # repo mode first
  rc=0; out="$(SESSION_MEMORY_DIR="$cloudR" CLAUDE_CONFIG_DIR="$cfgR" bash "$LM" --relink --cloud --name proj "$repoR" 2>&1)" || rc=$?
  assert_eq "--relink repo->cloud: exit 0" "0" "$rc"
  assert_eq "--relink moved the files to the new target" "MEMORY.md a.md" "$(ls -A "$cloudR/proj" | LC_ALL=C sort | paste -sd' ' -)"
  assert_eq "--relink: ls through the link shows the new target" "MEMORY.md a.md" "$(ls -A "$memR" | LC_ALL=C sort | paste -sd' ' -)"
  assert_eq "--relink: the old folder inside the repo is moved aside" "memory.pre-link" "$(ls -A "$repoR" | LC_ALL=C sort | paste -sd' ' -)"
  if printf '%s\n' "$out" | grep -q 'check-ignore'; then ok "--relink names the ignore-rule cross-check"; else bad "--relink names the ignore-rule cross-check" "$out"; fi
  rc=0; out="$(SESSION_MEMORY_DIR="$cloudR" CLAUDE_CONFIG_DIR="$cfgR" bash "$LM" --relink --cloud --name proj "$repoR" 2>&1)" || rc=$?
  if [[ $rc -eq 0 ]] && printf '%s\n' "$out" | grep -q 'already linked'; then ok "--relink is idempotent"; else bad "--relink is idempotent" "$out"; fi

  # --- --relink case 2: shared memory -- the other session's folder is NOT touched ---
  local cfgT="$TMPROOT/rlcfg2.$RANDOM" repoT slugT memT other cloudT
  repoT="$TMPROOT/rlrepo2.$RANDOM"; mkdir -p "$repoT"; cloudT="$TMPROOT/rlcloud2.$RANDOM"; mkdir -p "$cloudT"
  other="$TMPROOT/rlother.$RANDOM"; mkdir -p "$other"; echo idx > "$other/MEMORY.md"; echo x > "$other/x.md"
  slugT="$(printf '%s' "$(cygpath -w "$repoT" 2>/dev/null || printf '%s' "$repoT")" | sed 's/[^A-Za-z0-9]/-/g')"
  memT="$cfgT/projects/$slugT/memory"; mkdir -p "$(dirname "$memT")"
  if [[ "$(uname -s)" == MINGW* || "$(uname -s)" == MSYS* ]]; then
    powershell.exe -NoProfile -NonInteractive -Command \
      "New-Item -ItemType Junction -Path '$(cygpath -w "$memT")' -Target '$(cygpath -w "$other")' | Out-Null" >/dev/null 2>&1
  else
    ln -s "$other" "$memT"
  fi
  rc=0; out="$(SESSION_MEMORY_DIR="$cloudT" CLAUDE_CONFIG_DIR="$cfgT" bash "$LM" --relink --cloud --name shared "$repoT" 2>&1)" || rc=$?
  assert_eq "--relink shared: exit 0" "0" "$rc"
  assert_eq "--relink shared: files copied to the common folder" "MEMORY.md x.md" "$(ls -A "$cloudT/shared" | LC_ALL=C sort | paste -sd' ' -)"
  assert_eq "--relink shared: the other session's memory is untouched" "MEMORY.md x.md" "$(ls -A "$other" | LC_ALL=C sort | paste -sd' ' -)"
  if [[ -e "$other.pre-link" ]]; then bad "--relink shared: nothing outside the repo is renamed" "$other.pre-link exists"
  else ok "--relink shared: nothing outside the repo is renamed"; fi
  if printf '%s\n' "$out" | grep -q 'left untouched'; then ok "... and it says so"; else bad "... and it says so" "$out"; fi
  # --relink without an existing link is a harmless no-op
  local cfgU="$TMPROOT/rlcfg3.$RANDOM" repoU
  repoU="$TMPROOT/rlrepo3.$RANDOM"; mkdir -p "$repoU"
  rc=0; SESSION_MEMORY_DIR="$cloudT" CLAUDE_CONFIG_DIR="$cfgU" bash "$LM" --relink --cloud --name fresh "$repoU" >/dev/null 2>&1 || rc=$?
  assert_eq "--relink without an existing link: harmless" "0" "$rc"
}

# --------------------------------------------------------------------------
# memory stamp + launcher display
# --------------------------------------------------------------------------

test_stamp() {
  head_ "memory: the wrap stamp and what the launcher makes of it"
  local LM="$ROOT/launcher/link-memory.sh"
  local cfg="$TMPROOT/stcfg.$RANDOM" repo slug mem out
  repo="$TMPROOT/strepo.$RANDOM"; mkdir -p "$repo"
  slug="$(printf '%s' "$(cygpath -w "$repo" 2>/dev/null || printf '%s' "$repo")" | sed 's/[^A-Za-z0-9]/-/g')"
  mem="$cfg/projects/$slug/memory"; mkdir -p "$mem"
  echo idx > "$mem/MEMORY.md"; echo a > "$mem/a.md"; echo b > "$mem/b.md"
  state() { # -> the launcher's lines for this project
    ( export CLAUDE_CONFIG_DIR="$cfg"
      # shellcheck source=/dev/null
      source "$ROOT/launcher/_lib.sh"
      cc_memory_state proj "$repo" 2>&1 )
  }
  assert_eq "no stamp -> the launcher says nothing" "" "$(state)"
  CLAUDE_CONFIG_DIR="$cfg" bash "$LM" --stamp "$repo" >/dev/null
  assert_eq "the stamp does not count itself" "3" "$(cut -d' ' -f3 < "$mem/.last-wrap")"
  assert_eq "one line, three fields" "3" "$(wc -w < "$mem/.last-wrap" | tr -d ' ')"
  assert_eq "the stamp is UTC in the protocol format" "0" \
    "$(cut -d' ' -f2 < "$mem/.last-wrap" | grep -cvE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$')"
  assert_eq "own host, complete -> still silent" "" "$(state)"
  # the case the count exists for: the stamp arrived, the files did not
  rm "$mem/a.md" "$mem/b.md"
  out="$(state)"
  if printf '%s\n' "$out" | grep -qF '[memory] proj: 3 file(s) expected, 1 present'; then
    ok "shortfall is reported with both numbers"
  else bad "shortfall is reported with both numbers" "$out"; fi
  if printf '%s\n' "$out" | grep -q 'reads the memory ONCE at start'; then
    ok "... and names what to do about it"
  else bad "... and names what to do about it" "$out"; fi
  # more files than stamped is normal local work, not a finding
  echo a > "$mem/a.md"; echo b > "$mem/b.md"; echo c > "$mem/c.md"
  assert_eq "more files than stamped is not a finding" "" "$(state)"
  # a stamp from the other machine gets one informational line
  printf 'other-host 2026-08-30T07:11:51Z 4\n' > "$mem/.last-wrap"
  out="$(state)"
  if printf '%s\n' "$out" | grep -q '^\[memory\] proj: state from other-host'; then
    ok "a stamp from another host is shown"
  else bad "a stamp from another host is shown" "$out"; fi
  # a garbled stamp must not produce noise or an error
  printf 'garbage\n' > "$mem/.last-wrap"
  assert_eq "a garbled stamp is ignored, not reported" "" "$(state)"
  printf 'host 2026-08-30T07:11:51Z notanumber\n' > "$mem/.last-wrap"
  assert_eq "a non-numeric count is ignored" "" "$(state)"
  # the stamp is per-machine and must not travel into the target on a move
  local cfgS="$TMPROOT/stcfg2.$RANDOM" repoS slugS memS cloudS
  repoS="$TMPROOT/strepo3.$RANDOM"; mkdir -p "$repoS"; cloudS="$TMPROOT/stcloud.$RANDOM"; mkdir -p "$cloudS"
  slugS="$(printf '%s' "$(cygpath -w "$repoS" 2>/dev/null || printf '%s' "$repoS")" | sed 's/[^A-Za-z0-9]/-/g')"
  memS="$cfgS/projects/$slugS/memory"; mkdir -p "$memS"
  echo idx > "$memS/MEMORY.md"; printf 'somehost 2026-08-30T07:11:51Z 1\n' > "$memS/.last-wrap"
  SESSION_MEMORY_DIR="$cloudS" CLAUDE_CONFIG_DIR="$cfgS" bash "$LM" --cloud --name m "$repoS" >/dev/null 2>&1
  assert_eq "the stamp does not travel into the target" "MEMORY.md" "$(ls -A "$cloudS/m" | LC_ALL=C sort | paste -sd' ' -)"
  # --stamp on a project without a linked memory: says so, exit 0
  local repo2; repo2="$TMPROOT/strepo2.$RANDOM"; mkdir -p "$repo2"
  rc=0; out="$(CLAUDE_CONFIG_DIR="$cfg" bash "$LM" --stamp "$repo2" 2>&1)" || rc=$?
  assert_eq "--stamp without a linked memory: exit 0" "0" "$rc"
  if printf '%s\n' "$out" | grep -q 'nothing to stamp'; then ok "... and says so"; else bad "... and says so" "$out"; fi
}

case "${1:-all}" in
  watcher) test_watcher ;;
  stamp) test_stamp ;;
  install) test_install ;;
  numbers) test_numbers ;;
  newthread) test_new_thread ;;
  coverage) test_coverage ;;
  checkout) test_checkout ;;
  launcher) test_launcher ;;
  pull) test_pull ;;
  linkmemory) test_linkmemory ;;
  all)     test_watcher; test_coverage; test_checkout; test_numbers; test_new_thread; test_install; test_launcher; test_pull; test_linkmemory; test_stamp ;;
  *) echo "usage: run.sh [watcher|coverage|checkout|numbers|newthread|install|launcher|pull|linkmemory|stamp|all]" >&2; exit 64 ;;
esac

printf '\n%s\n' "----------------------------------------"
printf 'passed: %d   failed: %d\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
