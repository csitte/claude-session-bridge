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

# slug_of — the profile-directory name Claude Code derives from a working directory, the way
# link-memory.sh derives it: **canonicalise first** (`cd … && pwd -P`), then the Windows form,
# then every non-alphanumeric character becomes '-'.
#
# The canonicalisation is the whole point. Taking `cygpath -w` of the raw path instead looked
# identical on one machine and diverged on CI: there `mktemp -d` returns a path under `/tmp`
# whose Windows form carries the 8.3 SHORT name of the user directory, while `pwd -P` yields
# the long one. The fixture then created the profile under `C--Users-RUNNER-1-…` while the
# script looked under `C--Users-runneradmin-…` — 28 tests failed against a script that was
# working correctly, and a real migration on the same platform had already proven it.
# A fixture that computes a value differently from the code under test does not test it.
# winpath_of — the Windows spelling of a directory, canonicalised first. A participant table
# written from the raw path can carry the 8.3 short name while the script resolves the long
# one; the fixture must describe the same reality the code under test sees.
winpath_of() { local p; p="$(cd "$1" 2>/dev/null && pwd -P)" || p="$1"; cygpath -w "$p" 2>/dev/null || printf '%s' "$p"; }

slug_of() { # $1 = directory (must exist)
  local p; p="$(cd "$1" 2>/dev/null && pwd -P)" || p="$1"
  printf '%s' "$(cygpath -w "$p" 2>/dev/null || printf '%s' "$p")" | sed 's/[^A-Za-z0-9]/-/g'
}

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
  # An OPEN thread carries no expiry -- somebody has to act on it.
  if printf '%s\n' "$fold" | grep -q 'archive-ripe'; then
    bad "an open thread gets no archive date (it needs a person, not time)" "$fold"
  else ok "an open thread gets no archive date (it needs a person, not time)"; fi
  # ... and a DONE one does: the line then says it expires instead of standing forever.
  # Filtering DONE away would have swallowed this check's own founding case, so it is
  # annotated, not hidden. Own fixture on purpose: adding a message to the bridge above
  # would change which file decides the fold and quietly invalidate the assertions before
  # it -- that mistake was made once already today.
  local bd="$(new_bridge)"
  ( export SESSION_BRIDGE_DIR="$bd"; check_safety
    # the shape seen in the field: the future-stamped message is itself the one setting DONE
    post_state "$bd" 001-done 2026-01-02T000000Z__other__q1 other app DONE
    touch -d '2026-01-01T20:00:00Z' "$bd/threads/001-done/msgs/2026-01-02T000000Z__other__q1.md"
    bash "$WATCHER" --fold app 2>/dev/null ) > "$TMPROOT/donefold.txt"
  if grep -q 'DONE -- archive-ripe from 09.01.' "$TMPROOT/donefold.txt"; then
    ok "a DONE thread's line carries its archive date (last message + 7 days)"
  else bad "a DONE thread's line carries its archive date (last message + 7 days)" "$(cat "$TMPROOT/donefold.txt")"; fi
  export SESSION_BRIDGE_DIR="$b"
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

  # --- duplicate thread numbers: reported only while two of them are still open ---
  # new_bridge ships a `001-test`; it has to go here, or the fixture itself carries a
  # duplicate number and the silence assertions below can never hold. (It did on the first
  # run -- the detector was right and the fixture was wrong.)
  b="$(new_bridge)"; export SESSION_BRIDGE_DIR="$b"; check_safety
  rm -rf "$b/threads/001-test"
  post_state "$b" 001-mine 2026-01-01T000000Z__other__a1 other app OPEN
  # two folders sharing a number, both open -> reported
  post_state "$b" 200-alpha 2026-01-01T000000Z__x__b1 x someone OPEN
  post_state "$b" 200-beta  2026-01-02T000000Z__y__b2 y someone OPEN
  fold="$(bash "$WATCHER" --fold app 2>/dev/null)"
  if printf '%s\n' "$fold" | grep -q '^Thread number: handed out twice'; then
    ok "--fold reports a number used by two open threads"
  else bad "--fold reports a number used by two open threads" "$fold"; fi
  assert_eq "--fold names both folders with their oldest message" "200-alpha 200-beta" \
    "$(printf '%s\n' "$fold" | sed -n 's/^ \{14\}\(200-[a-z]*\) .*/\1/p' | LC_ALL=C sort | paste -sd' ' -)"
  if printf '%s\n' "$fold" | grep -q 'oldest message: 2026-01-01T000000Z__x__b1'; then
    ok "... so the later one is recognisable"
  else bad "... so the later one is recognisable" "$fold"; fi
  nc="$(printf '%s\n' "$fold" | grep -n '^Thread number:' | cut -d: -f1)"
  tl="$(printf '%s\n' "$fold" | grep -n '^001-mine' | cut -d: -f1)"
  if [[ -n "$nc" && -n "$tl" && "$nc" -lt "$tl" ]]; then
    ok "--fold prints the number check ABOVE the thread list"
  else bad "--fold prints the number check ABOVE the thread list" "$fold"; fi
  # one of the two closed -> the number is unambiguous enough, no line
  post_state "$b" 200-beta 2026-01-03T000000Z__y__b3 y someone DONE
  if bash "$WATCHER" --fold app 2>/dev/null | grep -q '^Thread number:'; then
    bad "a duplicate number with only one open thread is not reported"
  else ok "a duplicate number with only one open thread is not reported"; fi
  # a duplicate that lives in _archiv/ is history, not a finding
  mkdir -p "$b/_archiv/200-old/msgs"
  printf -- '---\nfrom: z\nto: app\ntype: fyi\ndate: 2026-01-01T00:00:00Z\n---\n\nbody\n' > "$b/_archiv/200-old/msgs/2026-01-01T000000Z__z__c1.md"
  if bash "$WATCHER" --fold app 2>/dev/null | grep -q '^Thread number:'; then
    bad "an archived duplicate is not reported"
  else ok "an archived duplicate is not reported"; fi
  # no duplicates at all -> silent
  b="$(new_bridge)"; export SESSION_BRIDGE_DIR="$b"; check_safety
  rm -rf "$b/threads/001-test"
  post_state "$b" 001-mine 2026-01-01T000000Z__other__a1 other app OPEN
  if bash "$WATCHER" --fold app 2>/dev/null | grep -q '^Thread number:'; then
    bad "--fold stays silent when every number is unique"
  else ok "--fold stays silent when every number is unique"; fi

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
    "$(WATCH_BRIDGE_SETTLE=0 bash "$WATCHER" --new-thread demo --title "A demo thread")"
  assert_eq "the thread folder is created with msgs/" "yes" \
    "$([[ -d "$b/threads/152-demo/msgs" ]] && echo yes || echo no)"

  # --- the cover sheet -------------------------------------------------------
  # 64 of 102 threads in a live bridge had none, because writing it was a prose step
  # after the command. Now the command writes it: only what it knows (title, created),
  # deliberately no participants: field.
  assert_eq "the cover sheet is written with the title" "title: A demo thread" \
    "$(grep '^title:' "$b/threads/152-demo/thread.md")"
  assert_eq "the cover sheet carries created: as a UTC date" "yes" \
    "$(grep -Eq '^created: [0-9]{4}-[0-9]{2}-[0-9]{2}$' "$b/threads/152-demo/thread.md" && echo yes || echo no)"
  assert_eq "the cover sheet is a closed front-matter block" "---" \
    "$(tail -n 1 "$b/threads/152-demo/thread.md")"
  if grep -q 'participants' "$b/threads/152-demo/thread.md"; then
    bad "no participants: field -- the command cannot know them" "$(cat "$b/threads/152-demo/thread.md")"
  else ok "no participants: field -- the command cannot know them"; fi

  # A deliberate series (a fan-out to several recipients under one number) has to stay
  # possible, and 069 must not be read as octal. The number stays positional; the
  # title may come as --title=… as well, and in any order.
  assert_eq "a forced number creates a second thread under it" "069-fanout-b" \
    "$(WATCH_BRIDGE_SETTLE=0 bash "$WATCHER" --new-thread fanout-b --title="Fan-out, part b" 69 2>/dev/null)"
  assert_eq "--title may precede the slug" "153-title-first" \
    "$(WATCH_BRIDGE_SETTLE=0 bash "$WATCHER" --new-thread --title "Title first" title-first 2>/dev/null)"
  assert_eq "surrounding whitespace and CR are stripped from the title" "title: Trimmed" \
    "$(WATCH_BRIDGE_SETTLE=0 bash "$WATCHER" --new-thread trimmed --title $'  Trimmed \r' >/dev/null 2>&1; grep '^title:' "$b/threads/154-trimmed/thread.md")"

  WATCH_BRIDGE_SETTLE=0 bash "$WATCHER" --new-thread 007-wrong --title "x" >/dev/null 2>&1
  assert_eq "a slug that already carries a number is refused" "2" "$?"

  bash "$WATCHER" --new-thread >/dev/null 2>&1
  assert_eq "--new-thread without a slug -> usage, exit 64" "64" "$?"
  bash "$WATCHER" --new-thread --title "no slug" >/dev/null 2>&1
  assert_eq "--new-thread with a title but no slug -> usage, exit 64" "64" "$?"

  # --- the title is mandatory, and the failure is loud --------------------------
  # The signature was chosen for the STALE READER: somebody who still follows an old
  # document and types the fan-out form `--new-thread <slug> 069`. With the title as
  # a second positional argument, 069 would silently become the title and the fan-out
  # would be broken exactly where the number is the whole point. With --title the
  # command refuses, creates nothing, and prints the new form with the caller's own
  # arguments -- one step instead of three documents.
  local before; before="$(ls -d "$b"/threads/*/ | wc -l | tr -d ' ')"
  out="$(WATCH_BRIDGE_SETTLE=0 bash "$WATCHER" --new-thread watcher-arm 069 2>&1)"; rc=$?
  assert_eq "the old fan-out form without a title -> usage, exit 64" "64" "$rc"
  if printf '%s\n' "$out" | grep -qF -- '--new-thread watcher-arm --title "<title>" 069'; then
    ok "the message shows the new form with the caller's slug and number"
  else bad "the message shows the new form with the caller's slug and number" "$out"; fi
  assert_eq "nothing is created when the title is missing" "no" \
    "$(ls -d "$b"/threads/*watcher-arm* >/dev/null 2>&1 && echo yes || echo no)"

  # The positional form `<slug> "<title>"` from an old proposal: the title is there,
  # in the wrong place. Hand it back in the right place.
  out="$(WATCH_BRIDGE_SETTLE=0 bash "$WATCHER" --new-thread positional "My title" 2>&1)"; rc=$?
  assert_eq "a positional title -> usage, exit 64" "64" "$rc"
  if printf '%s\n' "$out" | grep -qF -- '--new-thread positional --title "My title"'; then
    ok "the message moves the positional title behind --title"
  else bad "the message moves the positional title behind --title" "$out"; fi

  WATCH_BRIDGE_SETTLE=0 bash "$WATCHER" --new-thread blank --title "   " >/dev/null 2>&1
  assert_eq "a whitespace-only title is refused (exit 64)" "64" "$?"
  WATCH_BRIDGE_SETTLE=0 bash "$WATCHER" --new-thread twolines --title $'two\nlines' >/dev/null 2>&1
  assert_eq "a multi-line title is refused (exit 2)" "2" "$?"
  WATCH_BRIDGE_SETTLE=0 bash "$WATCHER" --new-thread unknown --nr 5 --title "x" >/dev/null 2>&1
  assert_eq "an unknown option -> usage, exit 64" "64" "$?"
  WATCH_BRIDGE_SETTLE=0 bash "$WATCHER" --new-thread nan --title "x" 12a >/dev/null 2>&1
  assert_eq "a non-numeric number with a title present is refused (exit 2)" "2" "$?"
  assert_eq "none of the refused calls created a folder" "$before" \
    "$(ls -d "$b"/threads/*/ | wc -l | tr -d ' ')"
  # --- the fan-out note, and the order it is printed in ---------------------
  b="$(new_bridge)"; export SESSION_BRIDGE_DIR="$b"; check_safety
  export WATCH_BRIDGE_SETTLE=0
  mkdir -p "$b/threads/007-first/msgs"

  out="$(bash "$WATCHER" --new-thread second --title "second" 007 2>&1)"
  if printf '%s\n' "$out" | grep -q 'NOTE: series 007 now spans 2 threads'; then
    ok "a series prints the sibling-threads note with the right count"
  else bad "a series prints the sibling-threads note with the right count" "$out"; fi

  out="$(bash "$WATCHER" --new-thread third --title "third" 007 2>&1)"
  if printf '%s\n' "$out" | grep -q 'spans 3 threads'; then
    ok "the count grows with the series"
  else bad "the count grows with the series" "$out"; fi

  out="$(bash "$WATCHER" --new-thread solo --title "solo" 2>&1)"
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
  # The cover sheet belongs to creating, not to reporting: mkdir, thread.md, then talk.
  if awk '/^  mkdir -p "\$dir\/msgs"/ {m=NR} /> "\$dir\/thread.md"/ {t=NR} /NOTE: series/ {n=NR}
          END {exit !(m && t && n && m < t && t < n)}' "$WATCHER"; then
    ok "the cover sheet is written after the mkdir and before the series note"
  else bad "the cover sheet is written after the mkdir and before the series note"; fi

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

  # Standing INSIDE the bridge the check has no basis -- the working directory is not a
  # project tree at all. It used to fire there and send the reader off to have a `msgs`
  # folder added to the participant table: work created for a third party who cannot
  # resolve it. And it hits exactly the timestamp repairs, which are done in `msgs/`.
  out="$(cd "$b/threads/001-test/msgs" && SESSION_BRIDGE_DIR="$b" bash "$WATCHER" --fold app 2>&1)"
  if printf '%s\n' "$out" | grep -q 'SUSPECT'; then
    bad "inside the bridge the id check stays quiet" "$out"
  else ok "inside the bridge the id check stays quiet"; fi
  if printf '%s\n' "$out" | grep -q 'you are inside the bridge'; then
    ok "... and says why instead of staying silent"
  else bad "... and says why instead of staying silent" "$out"; fi
  if printf '%s\n' "$out" | grep -qi 'participant table'; then
    bad "... and sends nobody to the registry for a msgs folder" "$out"
  else ok "... and sends nobody to the registry for a msgs folder"; fi

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
# launcher: resume only when there is something to resume
# --------------------------------------------------------------------------

test_resume() {
  head_ "launcher: --continue only with a transcript, --fresh, and the session name"
  local cfg="$TMPROOT/rscfg.$RANDOM" bin="$TMPROOT/rsbin.$RANDOM"
  local withtx="$TMPROOT/rswith.$RANDOM" without="$TMPROOT/rswithout.$RANDOM"
  mkdir -p "$cfg/sessions" "$bin" "$withtx" "$without"
  mkdir -p "$cfg/projects/$(slug_of "$withtx")"
  : > "$cfg/projects/$(slug_of "$withtx")/session.jsonl"

  has() { # $1 = directory -> yes/no
    ( export CLAUDE_CONFIG_DIR="$cfg"
      # shellcheck source=/dev/null
      source "$ROOT/launcher/_lib.sh"
      cc_has_transcript "$1" && echo yes || echo no )
  }
  assert_eq "a directory holding a .jsonl is resumable"     "yes" "$(has "$withtx")"
  assert_eq "a directory without one is not"                "no"  "$(has "$without")"
  assert_eq "a directory that does not exist is not"        "no"  "$(has "$TMPROOT/rsgone.$RANDOM")"

  # What cc_launch really puts on the command line. mintty is replaced by a stub on PATH;
  # `wait` inside the subshell makes the background start deterministic -- without it this
  # would be a race and the test would pass or fail by timing.
  cat > "$bin/mintty" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$MINTTY_LOG"
STUB
  chmod +x "$bin/mintty"

  launch() { # $1 = directory [$2 = CC_FRESH] -> the command line mintty was called with
    local log="$TMPROOT/rslog.$RANDOM"
    ( export CLAUDE_CONFIG_DIR="$cfg" PATH="$bin:$PATH" MINTTY_LOG="$log"
      export CC_LIVE_PIDS='' CC_NO_PULL=1 CC_FRESH="${2:-0}" CC_FORCE=0
      # shellcheck source=/dev/null
      source "$ROOT/launcher/_lib.sh"
      cc_launch "proj|$1" >/dev/null 2>&1
      wait )
    cat "$log" 2>/dev/null
  }
  # `--` before the pattern: it starts with a dash, and grep would read it as an option.
  assert_eq "a resumable directory is started with --continue" "1" "$(launch "$withtx"   | grep -c -- '--continue')"
  assert_eq "no transcript -> --continue is left out"          "0" "$(launch "$without"  | grep -c -- '--continue')"
  assert_eq "--fresh drops it even with a transcript"          "0" "$(launch "$withtx" 1 | grep -c -- '--continue')"
  # Not cosmetic: cc_session_running compares the registry `name` field, and without
  # --name that comparison can never match -- only the cwd branch would carry the guard.
  assert_eq "the session is always given its config name"      "1" "$(launch "$without"  | grep -c -- '--name "proj"')"
  # The check must be able to go red, or it guards nothing: a stub that records nothing
  # must not look like a pass.
  assert_eq "an empty recording is not mistaken for a match"   "0" "$(printf '' | grep -c -- '--continue')"
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
# launcher: the autostart selection is local
# --------------------------------------------------------------------------

# A copy of the launcher scripts in a scratch directory: _lib.sh derives CC_SCRIPT_DIR from
# its own location, so the config, the selection file and the scripts have to sit together.
# The mintty call is REPLACED IN THE COPY rather than stubbed on PATH -- `bash -lc` re-reads
# the profile and resets PATH, so a PATH stub does not reach a child login shell; a test
# relying on it once opened thirteen real windows. The copy is checked afterwards: if a
# real `mintty` call survived the rewrite, the test refuses to run.
launcher_copy() { # $1 = target dir -> writes _lib.sh + start-cc-sessions.sh + a mintty stub
  local d="$1"
  mkdir -p "$d/bin"
  cp "$ROOT/launcher/_lib.sh" "$ROOT/launcher/start-cc-sessions.sh" "$d/"
  sed -i 's|^  mintty -o ConfirmExit=no|  "$CC_TEST_MINTTY" -o ConfirmExit=no|' "$d/_lib.sh"
  grep -q 'CC_TEST_MINTTY' "$d/_lib.sh" || { echo "REFUSING: mintty call not replaced in the copy" >&2; exit 2; }
  grep -q '^  mintty ' "$d/_lib.sh" && { echo "REFUSING: a real mintty call is left in the copy" >&2; exit 2; }
  # The stub records the project name (after --Title) and the WHOLE command line: only
  # the latter can show whether a text reached the start prompt.
  cat > "$d/bin/mintty-stub" <<'STUB'
#!/usr/bin/env bash
prev=""; for a in "$@"; do [[ "$prev" == "--Title" ]] && echo "$a" >> "$CC_TEST_MARKER"; prev="$a"; done
printf '%s\n' "$*" >> "$CC_TEST_MARKER.args"
exit 0
STUB
  chmod +x "$d/bin/mintty-stub"
}

# fleet_start — runs the copied start-cc-sessions.sh and waits for the stub to have
# recorded $2 starts. cc_launch backgrounds the window and the starter disowns it, so
# the stub outlives the script; waiting on the CONDITION rather than a clock keeps the
# test deterministic.
fleet_start() { # $1 = launcher copy dir, $2 = expected starts, $3 = marker, [$4 = extra env]
  : > "$3"; : > "$3.args"
  ( export CC_TEST_MINTTY="$1/bin/mintty-stub" CC_TEST_MARKER="$3" HOSTNAME=testhost
    export CC_NO_PULL=1 CC_LIVE_PIDS='' CLAUDE_CONFIG_DIR="$1/profile"
    [[ -n "${4:-}" ]] && export "$4"
    cd "$1" && bash ./start-cc-sessions.sh >"$1/out.txt" 2>&1 </dev/null )
  FLEET_RC=$?
  local i=0
  while [[ "$(wc -l < "$3")" -lt "$2" && $i -lt 100 ]]; do sleep 0.05; i=$((i+1)); done
  return 0
}

test_autostart() {
  head_ "launcher: the autostart selection is local, seeded once from the config"
  local W="$TMPROOT/as.$RANDOM"; mkdir -p "$W/profile/sessions" "$W/p/alpha" "$W/p/beta" "$W/p/gamma" "$W/p/delta"
  launcher_copy "$W"
  cat > "$W/projects.testhost.conf" <<CONF
# header comment
projects=(
  "alpha|$W/p/alpha|--add-dir \"/x y\""
  #off "beta|$W/p/beta"
  "gamma|$W/p/gamma||instructions=g"
  #off "delta|$W/p/delta"
)
CONF
  local cfg="$W/projects.testhost.conf" sel="$W/autostart.testhost.local"

  lib() { # runs a snippet with the copied _lib.sh sourced
    ( export HOSTNAME=testhost
      # shellcheck source=/dev/null
      source "$W/_lib.sh"; eval "$1" )
  }
  assert_eq "cc_resolve_autostart derives the local file from the config name" "$sel" "$(lib "cc_resolve_autostart '$cfg'")"

  local all; all="$(lib "cc_all_entries '$cfg'")"
  assert_eq "cc_all_entries sees active AND #off entries, in file order" \
    "alpha beta gamma delta" "$(printf '%s\n' "$all" | cut -d'|' -f1 | paste -sd' ' -)"
  assert_eq "... with the extra args intact"   "alpha|$W/p/alpha|--add-dir \"/x y\"" "$(printf '%s\n' "$all" | sed -n 1p)"
  assert_eq "... and the fourth field intact"  "gamma|$W/p/gamma||instructions=g"    "$(printf '%s\n' "$all" | sed -n 3p)"

  # Seeding: the first call creates the file from the ACTIVE lines -- exactly what would
  # have started before -- and says so. Behaviour-preserving by construction.
  [[ -f "$sel" ]] && bad "no selection file before the first run" || ok "no selection file before the first run"
  local out; out="$(lib "cc_autostart_names '$cfg' 2>&1 >/dev/null")"
  if printf '%s\n' "$out" | grep -q 'local selection created'; then ok "the first run seeds the file and says so"; else bad "the first run seeds the file and says so" "$out"; fi
  [[ -f "$sel" ]] && ok "... the file now exists" || bad "... the file now exists"
  assert_eq "... holding exactly the active entries" "alpha gamma" "$(lib "cc_autostart_names '$cfg' 2>/dev/null" | paste -sd' ' -)"
  assert_eq "... which is what sourcing the array would have given" \
    "$(lib "projects=(); source '$cfg'; printf '%s\n' \"\${projects[@]%%|*}\"" | paste -sd' ' -)" \
    "$(lib "cc_autostart_names '$cfg' 2>/dev/null" | paste -sd' ' -)"
  assert_eq "the second run seeds nothing and is silent" "" "$(lib "cc_autostart_names '$cfg' 2>&1 >/dev/null")"

  # Editing the local file changes the selection without touching the config.
  local before; before="$(md5sum < "$cfg")"
  printf 'beta\r\n\n# just a comment\n   \ndelta\n' >> "$sel"
  assert_eq "names added locally are selected (CRLF, blanks and comments tolerated)" \
    "alpha gamma beta delta" "$(lib "cc_autostart_names '$cfg' 2>/dev/null" | paste -sd' ' -)"
  assert_eq "... and the config is untouched" "$before" "$(md5sum < "$cfg")"
  : > "$sel"
  assert_eq "an empty selection is an empty list" "" "$(lib "cc_autostart_names '$cfg' 2>/dev/null")"
  rm -f "$sel"

  # End to end through the fleet start.
  fleet_start "$W" 2 "$W/m1"
  assert_eq "the fleet start starts exactly the seeded selection"  "alpha gamma" "$(sort "$W/m1" | paste -sd' ' -)"
  if grep -q 'local selection created' "$W/out.txt"; then ok "... and reports the seeding"; else bad "... and reports the seeding" "$(cat "$W/out.txt")"; fi
  [[ -f "$sel" ]] && ok "... the selection file lies next to the config" || bad "... the selection file lies next to the config"
  if grep -q 'autostart' "$cfg"; then bad "... the config was not touched"; else ok "... the config was not touched"; fi
  assert_eq "... and the summary names the selection" "1" "$(grep -c 'selection: 2 of 4' "$W/out.txt")"

  printf 'beta\n' >> "$sel"
  fleet_start "$W" 3 "$W/m2"
  assert_eq "a name added to the selection starts too, in FILE order" "alpha beta gamma" "$(paste -sd' ' - < "$W/m2")"

  : > "$sel"
  fleet_start "$W" 0 "$W/m3"
  [[ -s "$W/m3" ]] && bad "an empty selection starts nothing" "$(cat "$W/m3")" || ok "an empty selection starts nothing"
  if grep -q 'no project is selected' "$W/out.txt"; then ok "... and says so loudly"; else bad "... and says so loudly" "$(cat "$W/out.txt")"; fi
  [[ "$FLEET_RC" -ne 0 ]] && ok "... with a non-zero exit, so the starter console stays open" || bad "... with a non-zero exit" "rc=$FLEET_RC"

  # The .gitignore keeps the selection out of the repository -- an ignore rule that
  # silently does nothing looks exactly like one that works, so ask git.
  if git -C "$ROOT" check-ignore -q launcher/autostart.testhost.local 2>/dev/null; then
    ok "launcher/autostart.<host>.local is ignored by git"
  else bad "launcher/autostart.<host>.local is ignored by git"; fi
}

# --------------------------------------------------------------------------
# launcher: --add-dir repos are pulled too
# --------------------------------------------------------------------------

test_addedrepos() {
  head_ "launcher: directories passed with --add-dir are pulled before the start"
  local root="$TMPROOT/ar.$RANDOM"; mkdir -p "$root/plain" "$root/with space"
  local G="git -c user.name=t -c user.email=t@t -c init.defaultBranch=main"
  $G init -q --bare "$root/bare.git"
  $G init -q "$root/author"
  ( cd "$root/author" && echo v1 > f && $G add f && $G commit -qm v1 && git remote add origin "$root/bare.git" && git push -q origin HEAD:main )
  git clone -q "$root/bare.git" "$root/sibling"
  ( cd "$root/author" && echo v2 > f && $G commit -qam v2 && git push -q origin HEAD:main )

  behind() { git -C "$1" fetch -q origin 2>/dev/null; git -C "$1" rev-list --count HEAD..origin/main 2>/dev/null; }
  added() { # $1 = extra field [$2 = CC_NO_PULL] -> stderr + rc
    ( export CC_NO_PULL="${2:-0}"
      # shellcheck source=/dev/null
      source "$ROOT/launcher/_lib.sh"
      cc_pull_added_repos proj "$1" 2>&1; echo "rc=$?" )
  }
  assert_eq "fixture: the sibling repo is one commit behind" "1" "$(behind "$root/sibling")"

  local out; out="$(added "--add-dir $root/sibling")"
  assert_eq "--add-dir on a repo: it is pulled"           "0"  "$(behind "$root/sibling")"
  assert_eq "... and the file is current"                 "v2" "$(cat "$root/sibling/f")"
  if printf '%s\n' "$out" | grep -q 'proj:sibling.*caught up'; then ok "... reported under the project name and the repo"; else bad "... reported under the project name and the repo" "$out"; fi

  assert_eq "--add-dir on a plain folder: silent, rc 0" "rc=0" "$(added "--add-dir $root/plain")"
  assert_eq "a quoted path with a space is split correctly" "rc=0" "$(added "--add-dir \"$root/with space\"")"

  git -C "$root/sibling" reset -q --hard HEAD~1
  added "--add-dir \"$root/with space\" --add-dir $root/sibling --add-dir $root/plain" >/dev/null
  assert_eq "several --add-dir, mixed: the repo among them is caught" "0" "$(behind "$root/sibling")"

  git -C "$root/sibling" reset -q --hard HEAD~1
  assert_eq "CC_NO_PULL=1: silent"        "rc=0" "$(added "--add-dir $root/sibling" 1)"
  assert_eq "... and nothing pulled"       "1"    "$(behind "$root/sibling")"

  assert_eq "no extra field: silent, rc 0" "rc=0" "$(added "")"
  # A syntax error inside `eval` tears down the enclosing shell before `|| return 0` can
  # act -- called directly the function returned 0, in a command substitution 1. The
  # check therefore has to run in $( ), or it tests nothing.
  assert_eq "a broken extra field (unbalanced quote): silent, rc 0" "rc=0" "$(added '--add-dir "unbalanced')"

  git -C "$root/sibling" reset -q --hard HEAD~1 2>/dev/null || true
  added "--add-dir=$root/sibling" >/dev/null
  assert_eq "the --add-dir=<path> form is caught too" "0" "$(behind "$root/sibling")"

  # Through cc_launch: the function is only worth anything if the launcher calls it. A
  # mutation that drops the call leaves every direct test above green.
  local W="$TMPROOT/are.$RANDOM"; mkdir -p "$W/profile/sessions" "$W/p/alpha"
  launcher_copy "$W"
  cat > "$W/projects.testhost.conf" <<CONF
projects=(
  "alpha|$W/p/alpha|--add-dir $root/sibling"
)
CONF
  git -C "$root/sibling" reset -q --hard HEAD~1
  assert_eq "fixture: behind again" "1" "$(behind "$root/sibling")"
  ( export CC_TEST_MINTTY="$W/bin/mintty-stub" CC_TEST_MARKER="$W/m" HOSTNAME=testhost
    export CC_LIVE_PIDS='' CLAUDE_CONFIG_DIR="$W/profile"
    cd "$W" && bash ./start-cc-sessions.sh >"$W/out.txt" 2>&1 </dev/null )
  assert_eq "cc_launch pulls the --add-dir repo before the start" "0" "$(behind "$root/sibling")"
  if grep -q 'alpha:sibling.*caught up' "$W/out.txt"; then ok "... and the start log says so"; else bad "... and the start log says so" "$(cat "$W/out.txt")"; fi
}

# --------------------------------------------------------------------------
# launcher: instructions kept outside the project repo
# --------------------------------------------------------------------------

# A real repo pair (bare + author + clone), because the whole point is the HISTORY: the
# baseline asks whether the working-tree file matches any version the clone has ever seen.
instructions_fixture() { # $1 = root -> author clone at $1/author, launcher clone at $1/clone
  local r="$1" G="git -c user.name=t -c user.email=t@t -c init.defaultBranch=main"
  mkdir -p "$r"
  $G init -q --bare "$r/bare.git"
  git clone -q "$r/bare.git" "$r/author" 2>/dev/null
  mkdir -p "$r/author/proj"; printf 'INSTRUCTIONS v1\n' > "$r/author/proj/CLAUDE.md"
  ( cd "$r/author" && $G add -A && $G commit -qm v1 && git push -q origin HEAD:main )
  git clone -q "$r/bare.git" "$r/clone" 2>/dev/null
}
instructions_publish() { # $1 = root $2 = content -> new version in author, pushed, clone caught up
  local r="$1" G="git -c user.name=t -c user.email=t@t"
  printf '%s\n' "$2" > "$r/author/proj/CLAUDE.md"
  ( cd "$r/author" && $G commit -qam next && git push -q origin HEAD:main )
  git -C "$r/clone" pull -q --ff-only origin main
}
instructions_conflict() { # $1 = clone -> leaves proj/CLAUDE.md in a merge conflict
  local c="$1" G="git -c user.name=t -c user.email=t@t"
  git -C "$c" checkout -q -b local
  printf 'LOCAL\n' > "$c/proj/CLAUDE.md"; ( cd "$c" && $G commit -qam local )
  git -C "$c" checkout -q main
  printf 'OTHER\n' > "$c/proj/CLAUDE.md"; ( cd "$c" && $G commit -qam other )
  # `merge` wants a committer identity BEFORE it finds the conflict -- without one it dies
  # with "Committer identity unknown" and leaves no conflict behind. A developer's global
  # gitconfig hides that; CI has none, and 17 cases went red there.
  ( cd "$c" && $G merge local >/dev/null 2>&1 ) || true
}

test_instructions() {
  head_ "launcher: instructions from a clone -- baseline from the history, conflict becomes a task"
  local r="$TMPROOT/in.$RANDOM"; instructions_fixture "$r"; mkdir -p "$r/tree"
  ins() { # $1 = key -> stderr + rc, against $r/tree
    ( export CC_INSTRUCTIONS_DIR="$r/clone" CC_NO_PULL=1
      # shellcheck source=/dev/null
      source "$ROOT/launcher/_lib.sh"
      cc_instructions_before_start proj "$r/tree" "$1" 2>&1; echo "rc=$?" )
  }
  local out
  out="$(ins proj)"
  if printf '%s\n' "$out" | grep -q 'copied in'; then ok "file missing in the tree -> copied in"; else bad "file missing in the tree -> copied in" "$out"; fi
  assert_eq "... with the clone's content"  "INSTRUCTIONS v1" "$(cat "$r/tree/CLAUDE.md")"
  assert_eq "there and equal -> silent, rc 0" "rc=0" "$(ins proj)"

  # THE case: merely outdated is caught up, not reported as a conflict.
  instructions_publish "$r" "INSTRUCTIONS v2"
  out="$(ins proj)"
  if printf '%s\n' "$out" | grep -q 'caught up'; then ok "merely outdated -> caught up"; else bad "merely outdated -> caught up" "$out"; fi
  if printf '%s\n' "$out" | grep -q 'differ'; then bad "... and NOT reported as a conflict" "$out"; else ok "... and NOT reported as a conflict"; fi
  assert_eq "... the tree is on v2" "INSTRUCTIONS v2" "$(cat "$r/tree/CLAUDE.md")"

  # Real divergence: the tree holds something the history has never seen.
  printf 'CHANGED LOCALLY, never committed\n' > "$r/tree/CLAUDE.md"
  instructions_publish "$r" "INSTRUCTIONS v3"
  out="$(ins proj)"
  if printf '%s\n' "$out" | grep -q 'NO version of the history'; then ok "a local change the history does not know -> reported"; else bad "a local change the history does not know -> reported" "$out"; fi
  assert_eq "... and the tree is left alone" "CHANGED LOCALLY, never committed" "$(cat "$r/tree/CLAUDE.md")"
  if printf '%s\n' "$out" | grep -q '^rc=0$'; then ok "... rc 0: the start goes on"; else bad "... rc 0" "$out"; fi

  # An OLD version still counts as known -- the history, not just HEAD~1.
  printf 'INSTRUCTIONS v1\n' > "$r/tree/CLAUDE.md"
  out="$(ins proj)"
  if printf '%s\n' "$out" | grep -q 'caught up'; then ok "an older version from the history is caught up too"; else bad "an older version from the history is caught up too" "$out"; fi
  assert_eq "... to the current one" "INSTRUCTIONS v3" "$(cat "$r/tree/CLAUDE.md")"

  out="$(ins nosuchkey)"
  if printf '%s\n' "$out" | grep -q 'is not in the clone'; then ok "an unknown key is reported, the start goes on"; else bad "an unknown key is reported, the start goes on" "$out"; fi
  assert_eq "no key at all -> silent, rc 0" "rc=0" "$(ins "")"
  assert_eq "CC_NO_INSTRUCTIONS=1 -> silent, rc 0" "rc=0" "$( ( export CC_INSTRUCTIONS_DIR="$r/clone" CC_NO_INSTRUCTIONS=1
      # shellcheck source=/dev/null
      source "$ROOT/launcher/_lib.sh"; cc_instructions_before_start proj "$r/tree" proj 2>&1; echo "rc=$?" ) )"
  out="$( ( export CC_INSTRUCTIONS_DIR="$r/nowhere"
      # shellcheck source=/dev/null
      source "$ROOT/launcher/_lib.sh"; cc_instructions_before_start proj "$r/tree" proj 2>&1; echo "rc=$?" ) )"
  if printf '%s\n' "$out" | grep -q 'no clone under'; then ok "no clone -> said, the start goes on"; else bad "no clone -> said" "$out"; fi

  # Merge conflict in the clone: nothing copied, the start goes on, and the SESSION gets
  # the task. NOT in $( ) -- that would be a subshell and CC_INSTRUCTIONS_NOTE would never
  # reach the caller; cc_launch calls the function directly for the same reason.
  instructions_conflict "$r/clone"
  [[ -n "$(git -C "$r/clone" ls-files -u)" ]] && ok "fixture: the clone is in a merge conflict" || bad "fixture: the clone is in a merge conflict"
  cp "$r/tree/CLAUDE.md" "$r/before.md"
  local note rc
  note="$( ( export CC_INSTRUCTIONS_DIR="$r/clone" CC_NO_PULL=1
      # shellcheck source=/dev/null
      source "$ROOT/launcher/_lib.sh"
      CC_INSTRUCTIONS_NOTE=""
      cc_instructions_before_start proj "$r/tree" proj 2>"$r/err.txt"; rc=$?
      printf 'rc=%s\n%s' "$rc" "${CC_INSTRUCTIONS_NOTE:-}" ) )"
  rc="$(printf '%s\n' "$note" | sed -n 1p)"; note="$(printf '%s\n' "$note" | sed 1d)"
  assert_eq "conflict in the own key: rc 0, no abort" "rc=0" "$rc"
  if grep -q 'MERGE CONFLICT' "$r/err.txt"; then ok "... named on stderr"; else bad "... named on stderr" "$(cat "$r/err.txt")"; fi
  cmp -s "$r/tree/CLAUDE.md" "$r/before.md" && ok "... nothing copied in" || bad "... nothing copied in"
  # A claim about an empty string passes always -- check it is set BEFORE checking its shape.
  [[ -n "$note" ]] && ok "... the task for the session is set" || bad "... the task for the session is set"
  if printf '%s' "$note" | grep -q -- "$r/clone"; then ok "... it names the clone"; else bad "... it names the clone" "$note"; fi
  if printf '%s' "$note" | grep -q 'NEXT session start'; then ok "... and warns that the fix takes effect at the next start"; else bad "... and warns about the next start" "$note"; fi
  if [[ -n "$note" ]] && ! printf '%s' "$note" | grep -q '[$`]'; then ok "... without backtick or dollar (it travels through bash -lc)"; else bad "... without backtick or dollar" "$note"; fi
  note="$( ( export CC_INSTRUCTIONS_DIR="$r/clone" CC_NO_PULL=1
      # shellcheck source=/dev/null
      source "$ROOT/launcher/_lib.sh"
      CC_INSTRUCTIONS_NOTE=""; cc_instructions_before_start proj "$r/tree" otherkey 2>/dev/null; printf '%s' "${CC_INSTRUCTIONS_NOTE:-}" ) )"
  assert_eq "conflict in ANOTHER project's file: no task for this session" "" "$note"

  # End to end: the entry's fourth field reaches the function, and the task reaches the
  # START PROMPT -- the log is read by nobody inside the session.
  local W="$TMPROOT/ine.$RANDOM"; mkdir -p "$W/profile/sessions" "$W/p/alpha" "$W/p/beta"
  launcher_copy "$W"
  printf 'ARM-RITUAL-PLACEHOLDER\n' > "$W/session-startprompt.txt"
  local r2="$TMPROOT/in2.$RANDOM"; instructions_fixture "$r2"
  mkdir -p "$r2/author/alpha"; printf 'A v1\n' > "$r2/author/alpha/CLAUDE.md"
  ( cd "$r2/author" && git -c user.name=t -c user.email=t@t add -A && git -c user.name=t -c user.email=t@t commit -qm alpha && git push -q origin HEAD:main )
  git -C "$r2/clone" pull -q --ff-only origin main
  cat > "$W/projects.testhost.conf" <<CONF
projects=(
  "alpha|$W/p/alpha||instructions=alpha"
  "beta|$W/p/beta|--add-dir \"/tmp\"|instructions=nosuch"
)
CONF
  fleet_start "$W" 2 "$W/m1" "CC_INSTRUCTIONS_DIR=$r2/clone"
  assert_eq "e2e: both entries start"                       "alpha beta" "$(sort "$W/m1" | paste -sd' ' -)"
  assert_eq "e2e: the key from the fourth field is used"    "A v1" "$(cat "$W/p/alpha/CLAUDE.md" 2>/dev/null)"
  if grep -q "'nosuch/CLAUDE.md' is not in the clone" "$W/out.txt"; then ok "e2e: a missing key is reported, the session starts anyway"; else bad "e2e: a missing key is reported" "$(cat "$W/out.txt")"; fi
  # The old prefix cut would have handed `--add-dir "/tmp"|instructions=nosuch` to claude.
  if grep -q -- '--add-dir "/tmp" --add-dir\|--add-dir "/tmp"|' "$W/m1.args" || grep -q 'instructions=' "$W/m1.args"; then
    bad "e2e: the fourth field does not leak into the claude command line" "$(cat "$W/m1.args")"
  else ok "e2e: the fourth field does not leak into the claude command line"; fi
  if grep -q 'Merge conflict\|merge conflict' "$W/m1.args"; then bad "e2e: no task in the prompt while the clone is clean"; else ok "e2e: no task in the prompt while the clone is clean"; fi

  instructions_conflict "$r2/clone"   # conflicts proj/, not alpha/ -- another project's file
  fleet_start "$W" 2 "$W/m2" "CC_INSTRUCTIONS_DIR=$r2/clone"
  assert_eq "e2e: a conflict in another project's file does not stop the start" "alpha beta" "$(sort "$W/m2" | paste -sd' ' -)"
  if grep -q 'ANOTHER project' "$W/out.txt"; then ok "... and is attributed to its owner"; else bad "... and is attributed to its owner" "$(cat "$W/out.txt")"; fi

  # Now alpha's own file in conflict: start on the local state, task in the prompt.
  git -C "$r2/clone" merge --abort >/dev/null 2>&1 || git -C "$r2/clone" reset -q --hard
  git -C "$r2/clone" checkout -q main 2>/dev/null
  git -C "$r2/clone" checkout -q -b alocal
  printf 'A local\n' > "$r2/clone/alpha/CLAUDE.md"; ( cd "$r2/clone" && git -c user.name=t -c user.email=t@t commit -qam alocal )
  git -C "$r2/clone" checkout -q main
  printf 'A other\n' > "$r2/clone/alpha/CLAUDE.md"; ( cd "$r2/clone" && git -c user.name=t -c user.email=t@t commit -qam aother )
  ( cd "$r2/clone" && git -c user.name=t -c user.email=t@t merge alocal >/dev/null 2>&1 ) || true   # identity, see instructions_conflict
  [[ -n "$(git -C "$r2/clone" ls-files -u -- alpha/CLAUDE.md)" ]] && ok "fixture: alpha/CLAUDE.md is in conflict" || bad "fixture: alpha/CLAUDE.md is in conflict"
  fleet_start "$W" 2 "$W/m3" "CC_INSTRUCTIONS_DIR=$r2/clone"
  assert_eq "e2e: the session STARTS despite the conflict"  "alpha beta" "$(sort "$W/m3" | paste -sd' ' -)"
  assert_eq "e2e: nothing was copied in"                     "A v1" "$(cat "$W/p/alpha/CLAUDE.md")"
  if grep -q 'merge conflict' "$W/m3.args"; then ok "e2e: the task is in the START PROMPT, not only in the log"; else bad "e2e: the task is in the start prompt" "$(cat "$W/m3.args")"; fi
  if grep -q -- "$r2/clone" "$W/m3.args"; then ok "... naming the clone"; else bad "... naming the clone" "$(cat "$W/m3.args")"; fi
  # The ritual is read by the window's shell (`$(cat …)`), so the recording holds the
  # reference, not the text: both must be in the SAME argument for the prompt to carry both.
  if tr '\n' ' ' < "$W/m3.args" | grep -q "session-startprompt.txt') *Note from the launcher"; then ok "... next to the arming ritual, which is kept (same argument)"; else bad "... next to the arming ritual" "$(cat "$W/m3.args")"; fi
  assert_eq "... only the session whose key is in conflict gets it" "1" "$(grep -c 'merge conflict' "$W/m3.args")"

  # Without a start prompt file the task still travels -- a missing file used to swallow it.
  rm -f "$W/session-startprompt.txt"
  fleet_start "$W" 2 "$W/m4" "CC_INSTRUCTIONS_DIR=$r2/clone"
  if grep -q 'merge conflict' "$W/m4.args"; then ok "e2e: the task is passed even without a start prompt file"; else bad "e2e: the task is passed even without a start prompt file" "$(cat "$W/m4.args")"; fi

  fleet_start "$W" 2 "$W/m5" "CC_NO_INSTRUCTIONS=1"
  assert_eq "e2e: CC_NO_INSTRUCTIONS=1 starts everything and touches nothing" "alpha beta" "$(sort "$W/m5" | paste -sd' ' -)"
  if grep -q '\[instructions\]' "$W/out.txt"; then bad "... silently" "$(cat "$W/out.txt")"; else ok "... silently"; fi
}

# --------------------------------------------------------------------------
# launcher: instructions-sync.sh, the write path
# --------------------------------------------------------------------------

test_isync() {
  head_ "launcher: instructions-sync.sh mirrors the working-tree CLAUDE.md into the clone"
  local S="$ROOT/launcher/instructions-sync.sh" r="$TMPROOT/is.$RANDOM"
  instructions_fixture "$r"
  mkdir -p "$r/proj"; printf 'PROJECT INSTRUCTIONS v1\n' > "$r/proj/CLAUDE.md"
  sync() { # $@ = args -> stdout+stderr + rc
    ( export CC_INSTRUCTIONS_DIR="$r/clone" GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
      bash "$S" "$@" 2>&1; echo "rc=$?" )
  }
  local out
  out="$(sync -n other "$r/proj")"
  if printf '%s\n' "$out" | grep -q 'would mirror'; then ok "dry run says what it would do"; else bad "dry run says what it would do" "$out"; fi
  [[ -e "$r/clone/other/CLAUDE.md" ]] && bad "... and changes nothing" || ok "... and changes nothing"

  out="$(sync other "$r/proj")"
  if printf '%s\n' "$out" | grep -q 'mirrored and pushed'; then ok "first sync: committed and pushed"; else bad "first sync: committed and pushed" "$out"; fi
  assert_eq "... the clone holds the file"  "PROJECT INSTRUCTIONS v1" "$(cat "$r/clone/other/CLAUDE.md")"
  git -C "$r/bare.git" cat-file -e main:other/CLAUDE.md 2>/dev/null && ok "... and so does the remote" || bad "... and so does the remote"

  local before; before="$(git -C "$r/clone" rev-parse HEAD)"
  out="$(sync other "$r/proj")"
  if printf '%s\n' "$out" | grep -q 'unchanged'; then ok "second sync without a change: says unchanged"; else bad "second sync without a change: says unchanged" "$out"; fi
  assert_eq "... and makes no commit" "$before" "$(git -C "$r/clone" rev-parse HEAD)"

  printf 'PROJECT INSTRUCTIONS v2\n' > "$r/proj/CLAUDE.md"
  sync other "$r/proj" >/dev/null
  assert_eq "a change is mirrored to the remote" "PROJECT INSTRUCTIONS v2" "$(git -C "$r/bare.git" show main:other/CLAUDE.md)"

  out="$(sync other "$r/nowhere")"
  if printf '%s\n' "$out" | grep -q 'no readable CLAUDE.md' && printf '%s\n' "$out" | grep -q '^rc=1$'; then ok "missing CLAUDE.md -> error, named, rc 1"; else bad "missing CLAUDE.md -> error, named, rc 1" "$out"; fi
  out="$(sync)"
  if printf '%s\n' "$out" | grep -q '^usage:' && printf '%s\n' "$out" | grep -q '^rc=1$'; then ok "no key -> usage, rc 1"; else bad "no key -> usage, rc 1" "$out"; fi

  instructions_conflict "$r/clone"
  printf 'PROJECT INSTRUCTIONS v3\n' > "$r/proj/CLAUDE.md"
  out="$(sync other "$r/proj")"
  if printf '%s\n' "$out" | grep -q 'MERGE CONFLICT' && printf '%s\n' "$out" | grep -q '^rc=1$'; then ok "a clone in conflict is not written to"; else bad "a clone in conflict is not written to" "$out"; fi
  assert_eq "... the file in the clone is left as it was" "PROJECT INSTRUCTIONS v2" "$(cat "$r/clone/other/CLAUDE.md")"
}

# --------------------------------------------------------------------------
# watcher: orphaned consoles (--reap)
# --------------------------------------------------------------------------

# Two halves. The bash side -- what --status, --reap and the arm do with the inventory
# lines -- is tested everywhere through a powershell.exe STUB on PATH that returns a fixed
# inventory and records every Stop-Process instead of executing it. The PowerShell side --
# which conhost is classified as spinner, zombie or neither -- is tested on Windows only,
# by running the classification block from the script against a synthetic process table.
test_reap() {
  head_ "watcher: orphaned consoles -- --reap, and what --status and the arm make of them"
  local W="$TMPROOT/reap.$RANDOM"; mkdir -p "$W/bin"
  local log="$W/stop.log"; : > "$log"
  # The stub answers the inventory call with a fixed table and logs Stop-Process calls.
  cat > "$W/bin/powershell.exe" <<STUB
#!/usr/bin/env bash
if printf '%s' "\$*" | grep -q 'Stop-Process'; then
  printf '%s\n' "\$*" | grep -oE -- '-Id [0-9,]+' >> '$log'
  exit 0
fi
cat <<'INV'
script|app|111|500|0|09-01 10:00
wrapper|app|112|500|1|09-01 10:00
spinner|-|900|7200|33|09-01 08:00
zombie|-|901|90000|0|08-31 09:00
claudepid|-|4242|0|0|
INV
STUB
  chmod +x "$W/bin/powershell.exe"

  # Safety rail before anything armed runs: the stub MUST be the powershell.exe that is
  # found, or `--reap` below would kill real processes on the machine running the tests.
  local found; found="$(PATH="$W/bin:$PATH" command -v powershell.exe)"
  if [[ "$found" != "$W/bin/powershell.exe" ]]; then
    bad "the powershell stub takes precedence on PATH" "found: $found"; return 0
  fi
  ok "the powershell stub takes precedence on PATH"
  local B; B="$(new_bridge)"
  wb() { ( export PATH="$W/bin:$PATH" WATCH_BRIDGE_INV_TTL=0 SESSION_BRIDGE_DIR="$B"; bash "$WATCHER" "$@" 2>&1; echo "rc=$?" ); }

  local out
  out="$(wb --status)"
  assert_eq "--status: exactly one watcher row (the id), none for the orphans" "1" "$(printf '%s\n' "$out" | grep -c '^app ')"
  if printf '%s\n' "$out" | grep -q '^-  *\|^- '; then bad "--status: no row with id '-'" "$out"; else ok "--status: no row with id '-'"; fi
  if printf '%s\n' "$out" | grep -q 'claudepid'; then bad "--status: claudepid lines are consumed, not shown" "$out"; else ok "--status: claudepid lines are consumed, not shown"; fi
  if printf '%s\n' "$out" | grep -q '^WARNING: 1 orphaned console' && printf '%s\n' "$out" | grep -q 'PID 900 '; then ok "--status: the spinner is reported as WARNING with its pid"; else bad "--status: the spinner is reported as WARNING with its pid" "$out"; fi
  if printf '%s\n' "$out" | grep -q '^note: 1 orphaned console.*without load'; then ok "--status: the idle leftover is a note"; else bad "--status: the idle leftover is a note" "$out"; fi
  out="$(wb --status app)"
  if printf '%s\n' "$out" | grep -q '^WARNING: 1 orphaned console'; then ok "--status <id>: the spinner is reported regardless of the id filter"; else bad "--status <id>: the spinner is reported regardless of the id filter" "$out"; fi

  out="$(wb --reap --dry-run)"
  if printf '%s\n' "$out" | grep -q '^spinner  900 ' && ! printf '%s\n' "$out" | grep -q '^zombie'; then ok "--reap --dry-run lists the spinner and not the idle leftover"; else bad "--reap --dry-run lists the spinner and not the idle leftover" "$out"; fi
  if printf '%s\n' "$out" | grep -q 'nothing killed'; then ok "... and says it killed nothing"; else bad "... and says it killed nothing" "$out"; fi
  out="$(wb --reap --dry-run --all)"
  if printf '%s\n' "$out" | grep -q '^zombie   901 '; then ok "--reap --dry-run --all lists the idle leftover too"; else bad "--reap --dry-run --all lists the idle leftover too" "$out"; fi
  assert_eq "no dry run has issued a Stop-Process" "" "$(cat "$log")"

  out="$(wb --reap)"
  assert_eq "--reap kills the spinner only"        "-Id 900" "$(cat "$log")"
  if printf '%s\n' "$out" | grep -q '1 orphaned console(s) killed (PID 900)'; then ok "... and reports it"; else bad "... and reports it" "$out"; fi
  : > "$log"
  wb --reap --all >/dev/null
  assert_eq "--reap --all kills spinner and idle leftover" "-Id 900,901" "$(cat "$log")"
  out="$(wb --reap --bogus)"
  if printf '%s\n' "$out" | grep -q '^rc=64$'; then ok "an unknown --reap option is refused with 64"; else bad "an unknown --reap option is refused with 64" "$out"; fi

  # The arm reaps spinners even when it steps aside, and never mistakes them for its kind.
  : > "$log"
  out="$( ( export PATH="$W/bin:$PATH" WATCH_BRIDGE_INV_TTL=0 SESSION_BRIDGE_DIR="$(new_bridge)"
           unset WATCH_BRIDGE_NO_REAP; timeout 20 bash "$WATCHER" app 1 2>&1; echo "rc=$?" ) )"
  if printf '%s\n' "$out" | grep -q 'already delivering'; then ok "arm: a delivering watcher for the id makes the new arm step aside"; else bad "arm: steps aside" "$out"; fi
  assert_eq "arm: the spinner is killed anyway, the watcher pids are not" "-Id 900" "$(cat "$log")"
  if printf '%s\n' "$out" | grep -q 'killed 1 orphaned console'; then ok "... and the arm says so"; else bad "... and the arm says so" "$out"; fi
  # Same fixture minus the live wrapper: the script row is a silent remnant and is reaped,
  # the spinner too, the zombie never (that needs --all, by hand).
  sed -i '/^wrapper|/d' "$W/bin/powershell.exe"; : > "$log"
  out="$( ( export PATH="$W/bin:$PATH" WATCH_BRIDGE_INV_TTL=0 SESSION_BRIDGE_DIR="$(new_bridge)"
           unset WATCH_BRIDGE_NO_REAP; timeout 3 bash "$WATCHER" app 1 2>&1 ) )"
  assert_eq "arm: silent remnant and spinner reaped, the idle leftover left alone" "-Id 900
-Id 111" "$(cat "$log")"

  # Every consumer of the inventory filters on script/wrapper explicitly -- a structural
  # check, because a missing filter shows only when the new kinds actually occur.
  local body missing=""
  for fn in delivery_state status_report handle_existing; do
    body="$(awk -v f="$fn" '$0 ~ "^"f"\\(\\)" {p=1} p {print} p && /^}/ {exit}' "$WATCHER")"
    printf '%s' "$body" | grep -q 'script || .*wrapper\|spinner' || missing+="$fn "
  done
  assert_eq "every inventory consumer handles the new line kinds" "" "$missing"

  # PowerShell half: the classification itself, against a synthetic process table.
  if ! has_inventory; then
    printf '  skip no PowerShell -- the conhost classification cannot be exercised here\n'
    return 0
  fi
  local block
  block="$(awk '/^# --- Orphaned ConPTY hosts/ {p=1} /^# --- Live claude.exe/ {p=0} p' "$WATCHER")"
  if [[ -z "$block" ]]; then bad "the classification block is found in the script"; return 0; fi
  ok "the classification block is found in the script"
  printf '%s\n' "$block" > "$W/classify.ps1"
  # The fixture: pid|parent|age-seconds|cpu-seconds|name. A live parent is any pid in the table.
  out="$(powershell.exe -NoProfile -NonInteractive -Command "
    \$now = Get-Date
    \$all = @{}
    function P(\$pid_, \$parent, \$age, \$cpu, \$name) {
      \$all[[int]\$pid_] = [pscustomobject]@{ Name=\$name; ProcessId=\$pid_; ParentProcessId=\$parent;
        CreationDate=\$now.AddSeconds(-\$age); KernelModeTime=[long](\$cpu*10000000); UserModeTime=0 }
    }
    P 10 1 100000 5 'bash.exe'
    P 20 10 100000 3000 'conhost.exe'      # live parent, heavy load: a window, never touched
    P 30 999 30    10   'conhost.exe'      # orphan, 30 s, 33 %: too young
    P 31 999 180   60   'conhost.exe'      # orphan, 3 min, 33 %: spinner
    P 32 999 3600  1    'conhost.exe'      # orphan, 1 h, idle: a fresh terminal -- not a zombie yet
    P 33 999 90000 1    'conhost.exe'      # orphan, 25 h, idle: zombie
    P 34 999 90000 30000 'conhost.exe'     # orphan, 25 h, 33 %: spinner
    P 40 999 90000 0    'claude.exe'
    . '$(cygpath -w "$W/classify.ps1" 2>/dev/null || printf '%s' "$W/classify.ps1")'
  " 2>&1 | tr -d '\r' | sed 's/|[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]$//' | sort | paste -sd' ' -)"
  # Expected: the 3-minute spinner, the day-old spinner, the day-old idle orphan -- and
  # neither the window with a live parent, nor the 30-second one, nor the 1-hour idle one.
  assert_eq "classification: only the two spinners and the day-old idle orphan" \
    "spinner|-|31|180|33 spinner|-|34|90000|33 zombie|-|33|90000|0" "$out"
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
  slug="$(slug_of "$repo")"
  mem="$cfg/projects/$slug/memory"
  mkdir -p "$mem"; echo idx > "$mem/MEMORY.md"; echo a > "$mem/a.md"
  rc=0; out="$(CLAUDE_CONFIG_DIR="$cfg" bash "$LM" -n "$repo" 2>&1)" || rc=$?
  assert_eq "-n: exit 0" "0" "$rc"
  assert_eq "-n changes nothing" "" "$(ls -A "$repo")"
  if printf '%s\n' "$out" | grep -qF '[move] 2 file(s) exist only in the profile'; then ok "-n announces the move"; else bad "-n announces the move" "$out"; fi
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
  # The session does the consolidating, so the abort has to hand it enough to start:
  # both full paths and how much differs. Bare filenames meant searching first.
  if printf '%s\n' "$out" | grep -q 'line(s) differ'; then
    ok "conflict states how much differs"
  else bad "conflict states how much differs" "$out"; fi
  if printf '%s\n' "$out" | grep -q 'profile: .*a\.md' && printf '%s\n' "$out" | grep -q 'target:  .*a\.md'; then
    ok "conflict gives both full paths"
  else bad "conflict gives both full paths" "$out"; fi
  if printf '%s\n' "$out" | grep -q 'consolidates them itself'; then
    ok "conflict says who merges"
  else bad "conflict says who merges" "$out"; fi
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
  slug5="$(slug_of "$repo5")"
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
  slugR="$(slug_of "$repoR")"
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
  slugT="$(slug_of "$repoT")"
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
  # --- the id comes from the participant table when nothing better is at hand ---
  local bridge="$TMPROOT/lmbridge.$RANDOM"; mkdir -p "$bridge"
  local repoW="$TMPROOT/app-web.$RANDOM" repoP="$TMPROOT/app-product.$RANDOM"
  mkdir -p "$repoW" "$repoP"
  # the table lists the WEB directory under the id `app`; app-product is a different id
  {
    printf '| id | session | repo / working dir |\n|---|---|---|\n'
    printf '| `app` | web | `%s` (`main`) |\n' "$(winpath_of "$repoW")"
    printf '| `app-product` | product | `%s` (`main`) |\n' "$(winpath_of "$repoP")"
  } > "$bridge/README.md"
  local cfgV="$TMPROOT/lmcfg11.$RANDOM"
  SESSION_BRIDGE_DIR="$bridge" SESSION_MEMORY_DIR="$cloud" CLAUDE_CONFIG_DIR="$cfgV" \
    bash "$LM" --cloud "$repoW" >/dev/null 2>&1
  if [[ -d "$cloud/app" ]]; then ok "the id comes from the participant table, not the directory name"
  else bad "the id comes from the participant table, not the directory name" "$(ls "$cloud")"; fi
  # ... and the neighbouring id must not be caught by a prefix match
  local cfgW="$TMPROOT/lmcfg12.$RANDOM"
  SESSION_BRIDGE_DIR="$bridge" SESSION_MEMORY_DIR="$cloud" CLAUDE_CONFIG_DIR="$cfgW" \
    bash "$LM" --cloud "$repoP" >/dev/null 2>&1
  if [[ -d "$cloud/app-product" ]]; then ok "a neighbouring path is not caught by a prefix match"
  else bad "a neighbouring path is not caught by a prefix match" "$(ls "$cloud")"; fi
  # .session-id still wins over the table
  local cfgX="$TMPROOT/lmcfg13.$RANDOM"; printf 'explicit\n' > "$repoW/.session-id"
  SESSION_BRIDGE_DIR="$bridge" SESSION_MEMORY_DIR="$cloud" CLAUDE_CONFIG_DIR="$cfgX" \
    bash "$LM" --cloud "$repoW" >/dev/null 2>&1
  if [[ -d "$cloud/explicit" ]]; then ok ".session-id wins over the table"; else bad ".session-id wins over the table" "$(ls "$cloud")"; fi
  rm "$repoW/.session-id"
  # no bridge at all -> silent fall back to the directory name
  local cfgY="$TMPROOT/lmcfg14.$RANDOM"
  SESSION_MEMORY_DIR="$cloud" CLAUDE_CONFIG_DIR="$cfgY" bash "$LM" --cloud "$repoW" >/dev/null 2>&1
  if [[ -d "$cloud/$(printf '%s' "${repoW##*/}" | tr 'A-Z' 'a-z')" ]]; then
    ok "without a bridge the directory name is used"
  else bad "without a bridge the directory name is used" "$(ls "$cloud")"; fi
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
  slug="$(slug_of "$repo")"
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
  slugS="$(slug_of "$repoS")"
  memS="$cfgS/projects/$slugS/memory"; mkdir -p "$memS"
  echo idx > "$memS/MEMORY.md"; printf 'somehost 2026-08-30T07:11:51Z 1\n' > "$memS/.last-wrap"
  SESSION_MEMORY_DIR="$cloudS" CLAUDE_CONFIG_DIR="$cfgS" bash "$LM" --cloud --name m "$repoS" >/dev/null 2>&1
  assert_eq "the stamp does not travel into the target" "MEMORY.md" "$(ls -A "$cloudS/m" | LC_ALL=C sort | paste -sd' ' -)"
  # THE case the count exists for: nothing but the stamp is there yet. Both the stamp and
  # the launcher line used to count with `ls | grep -v`, which returns 1 when nothing is
  # left -- with `set -euo pipefail` in the callers that aborted the run instead of warning.
  local cfgE="$TMPROOT/stcfg3.$RANDOM" repoE slugE memE
  repoE="$TMPROOT/strepo4.$RANDOM"; mkdir -p "$repoE"
  slugE="$(slug_of "$repoE")"
  memE="$cfgE/projects/$slugE/memory"; mkdir -p "$memE"
  rc=0; out="$(CLAUDE_CONFIG_DIR="$cfgE" bash "$LM" --stamp "$repoE" 2>&1)" || rc=$?
  assert_eq "--stamp on an empty memory: exit 0, not a silent abort" "0" "$rc"
  assert_eq "--stamp on an empty memory counts 0" "0" "$(cut -d' ' -f3 < "$memE/.last-wrap")"
  rc=0; out="$(CLAUDE_CONFIG_DIR="$cfgE" bash "$LM" --stamp "$repoE" 2>&1)" || rc=$?
  assert_eq "--stamp with only the stamp present: still exit 0" "0" "$rc"
  printf 'other-host 2026-08-30T07:00:00Z 5\n' > "$memE/.last-wrap"
  out="$( CLAUDE_CONFIG_DIR="$cfgE" bash -c '
            set -euo pipefail
            # shellcheck source=/dev/null
            source "$1/launcher/_lib.sh"
            cc_memory_state proj "$2"
            echo REACHED' _ "$ROOT" "$repoE" 2>&1 )"
  if printf '%s\n' "$out" | grep -q '5 file(s) expected, 0 present'; then
    ok "the launcher reports a shortfall when only the stamp has arrived"
  else bad "the launcher reports a shortfall when only the stamp has arrived" "$out"; fi
  if printf '%s\n' "$out" | grep -q '^REACHED$'; then
    ok "... and the start run continues (no abort under set -euo pipefail)"
  else bad "... and the start run continues (no abort under set -euo pipefail)" "$out"; fi
  # THE case a real deployment always has: the memory is reached THROUGH A LINK. `ls`
  # follows it, `find` without -L does not -- an interim fix using plain `find` counted 0,
  # which makes `actual < scount` unsatisfiable and silences the shortfall warning for every
  # migrated project. A test against a plain directory cannot see that.
  local cfgL="$TMPROOT/stcfg4.$RANDOM" repoL slugL memL realL
  repoL="$TMPROOT/strepo5.$RANDOM"; realL="$TMPROOT/streal.$RANDOM"
  mkdir -p "$repoL" "$realL"; echo a > "$realL/a.md"; echo b > "$realL/b.md"; echo c > "$realL/c.md"
  slugL="$(slug_of "$repoL")"
  memL="$cfgL/projects/$slugL/memory"; mkdir -p "$(dirname "$memL")"
  if [[ "$(uname -s)" == MINGW* || "$(uname -s)" == MSYS* ]]; then
    powershell.exe -NoProfile -NonInteractive -Command \
      "New-Item -ItemType Junction -Path '$(cygpath -w "$memL")' -Target '$(cygpath -w "$realL")' | Out-Null" >/dev/null 2>&1
  else
    ln -s "$realL" "$memL"
  fi
  CLAUDE_CONFIG_DIR="$cfgL" bash "$LM" --stamp "$repoL" >/dev/null 2>&1
  assert_eq "--stamp counts THROUGH the link, not 0" "3" "$(cut -d' ' -f3 < "$realL/.last-wrap")"
  printf 'other-host 2026-08-30T07:00:00Z 5\n' > "$realL/.last-wrap"
  out="$( CLAUDE_CONFIG_DIR="$cfgL" bash -c '
            set -euo pipefail
            # shellcheck source=/dev/null
            source "$1/launcher/_lib.sh"
            cc_memory_state proj "$2"
            echo REACHED' _ "$ROOT" "$repoL" 2>&1 )"
  if printf '%s\n' "$out" | grep -q '5 file(s) expected, 3 present'; then
    ok "the shortfall warning fires through the link"
  else bad "the shortfall warning fires through the link" "$out"; fi
  if printf '%s\n' "$out" | grep -q '^REACHED$'; then ok "... and the run continues"; else bad "... and the run continues" "$out"; fi
  rm -f "$realL"/*.md
  out="$( CLAUDE_CONFIG_DIR="$cfgL" bash -c '
            set -euo pipefail
            source "$1/launcher/_lib.sh"
            cc_memory_state proj "$2"
            echo REACHED' _ "$ROOT" "$repoL" 2>&1 )"
  if printf '%s\n' "$out" | grep -q '5 file(s) expected, 0 present' && printf '%s\n' "$out" | grep -q REACHED; then
    ok "an empty linked memory reports 0 and does not abort"
  else bad "an empty linked memory reports 0 and does not abort" "$out"; fi
  # --stamp on a project without a linked memory: says so, exit 0
  local repo2; repo2="$TMPROOT/strepo2.$RANDOM"; mkdir -p "$repo2"
  rc=0; out="$(CLAUDE_CONFIG_DIR="$cfg" bash "$LM" --stamp "$repo2" 2>&1)" || rc=$?
  assert_eq "--stamp without a linked memory: exit 0" "0" "$rc"
  if printf '%s\n' "$out" | grep -q 'nothing to stamp'; then ok "... and says so"; else bad "... and says so" "$out"; fi
}

# --------------------------------------------------------------------------
# the participant-table rule exists in more than one file -- keep them equal
# --------------------------------------------------------------------------

# Suggested by the coordinating session after a backslash fix had to be applied by hand to
# every copy of this rule: instead of carrying the duplication as a documented debt, let a
# test carry it. It compares the rule's defining lines across the files that implement it,
# and runs one shared fixture through both, so divergence goes red on its own.
test_ruleparity() {
  head_ "participant-table rule: all copies stay identical"
  local a="$ROOT/bridge/watch-bridge.sh" b="$ROOT/launcher/link-memory.sh"
  rule() { # the defining lines of the parse rule, whitespace-normalised
    grep -hE 'gsub\(/\[ `\]/|split\(\$4, parts|p=parts\[i\]|print id "\\t" tolower\(p\)' "$1" \
      | sed 's/^[[:space:]]*//; s/[[:space:]]\{1,\}/ /g' | LC_ALL=C sort
  }
  assert_eq "watch-bridge.sh and link-memory.sh parse the table with the same rule" \
    "$(rule "$a")" "$(rule "$b")"
  if [[ -n "$(rule "$a")" ]]; then ok "the rule was actually found (the check can go red)"
  else bad "the rule was actually found (the check can go red)" "grep matched nothing"; fi
  # and one shared fixture through both implementations
  local bridge="$TMPROOT/parity.$RANDOM"; mkdir -p "$bridge/threads/001-x/msgs"
  local proj="$TMPROOT/parityproj.$RANDOM"; mkdir -p "$proj"
  local win; win="$(winpath_of "$proj")"
  {
    printf '| id | session | repo / working dir |\n|---|---|---|\n'
    printf '| `app` | x | `%s` (`main`) |\n' "$win"          # backslashes on Windows, slashes on Linux
  } > "$bridge/README.md"
  local cfgP="$TMPROOT/paritycfg.$RANDOM" cloudP="$TMPROOT/paritycloud.$RANDOM"
  mkdir -p "$cloudP"
  SESSION_BRIDGE_DIR="$bridge" SESSION_MEMORY_DIR="$cloudP" CLAUDE_CONFIG_DIR="$cfgP" \
    bash "$ROOT/launcher/link-memory.sh" --cloud "$proj" >/dev/null 2>&1
  if [[ -d "$cloudP/app" ]]; then ok "link-memory resolves the fixture table to 'app'"
  else bad "link-memory resolves the fixture table to 'app'" "$(ls "$cloudP")"; fi
  # the watcher reads the same table: from the matching directory its id check stays silent
  ( cd "$proj" && SESSION_BRIDGE_DIR="$bridge" bash "$a" --fold app 2>&1 ) > "$TMPROOT/parity.out" || true
  if grep -q 'SUSPICION' "$TMPROOT/parity.out"; then
    bad "watch-bridge reads the same table (no suspicion in the matching directory)" "$(cat "$TMPROOT/parity.out")"
  else ok "watch-bridge reads the same table (no suspicion in the matching directory)"; fi
}

# --------------------------------------------------------------------------
# shipped scripts: LF only
# --------------------------------------------------------------------------

# A tooling trap, not a code bug: several editors and some scripting languages write CRLF by
# default on Windows, and a shell script with CR endings fails in ways that read like a syntax
# error somewhere else. `.gitattributes` keeps the COMMIT clean -- which is exactly why a
# working copy can be broken while everything looks fine in git. The warning against this
# lived in a notes file: read when looking something up, not when typing. So it lives here
# now, where it fires at the moment the change is made -- the test run before the push.
test_lineendings() {
  head_ "shipped scripts have LF line endings"
  local f broken=""
  for f in "$ROOT"/bridge/*.sh "$ROOT"/launcher/*.sh "$ROOT"/tests/*.sh; do
    [[ -f "$f" ]] || continue
    if LC_ALL=C grep -qU $'\r' "$f"; then broken+="${broken:+ }${f##*/}"; fi
  done
  assert_eq "no shell script carries CR (a CRLF script fails in confusing ways)" "" "$broken"
  # the check must be able to fail -- otherwise it guards nothing
  local probe="$TMPROOT/crlf.$RANDOM.sh"; printf '#!/bin/sh\r\necho hi\r\n' > "$probe"
  if LC_ALL=C grep -qU $'\r' "$probe"; then ok "the CR check detects a CRLF file (it can go red)"
  else bad "the CR check detects a CRLF file (it can go red)" "probe not detected"; fi
}

# --------------------------------------------------------------------------
# process inventory: both spellings of the id in a watcher command line
# --------------------------------------------------------------------------

# The arming paragraph exists in two forms: with a literal id, and -- for checkouts that
# share one CLAUDE.md -- as `$(head -1 <tree>/.session-id)`. The wrapper process carries the
# line UNEXPANDED, so an inventory that only knows literal ids attributes the wrapper to no
# id at all. In the field that made `--status` call a delivering session a silent remnant,
# and the next arm reaped the working wrapper. The processes cannot be reproduced here, but
# the RULE can: the same two regexes the script uses, against both spellings.
test_inventory_ids() {
  head_ "process inventory: literal id and the .session-id form both resolve"
  if ! has_inventory; then
    printf '  skip no PowerShell — the inventory regexes cannot be exercised here\n'
    return 0
  fi
  local W="$ROOT/bridge/watch-bridge.sh"
  local rx rxs sid="$TMPROOT/inv.$RANDOM"
  mkdir -p "$sid"; printf 'app\n' > "$sid/.session-id"
  # Fixed-string search on purpose: the lines start with a literal `$`, and escaping that
  # through bash into a regex is exactly the kind of quoting that fails silently and would
  # leave the check green over an empty pattern.
  rx="$(grep -m1 -F '$rx  = ' "$W" | sed 's/^[^"]*"//; s/"$//')"
  rxs="$(grep -m1 -F '$rxs = ' "$W" | sed "s/^[^']*'//; s/'\$//")"
  if [[ -z "$rx" || -z "$rxs" ]]; then
    bad "both id patterns are present in the inventory" "rx='$rx' rxs='$rxs'"; return 0
  fi
  ok "both id patterns are present in the inventory"
  local win; win="$(cygpath -m "$sid" 2>/dev/null || printf '%s' "$sid")"
  # The literal-id pattern contains single quotes itself; inside a PowerShell single-quoted
  # string each one has to be doubled, or the snippet dies with a parser error and the test
  # would report a mismatch that is the harness's fault, not the script's.
  local rxq="${rx//\'/\'\'}" rxsq="${rxs//\'/\'\'}"
  local out
  out="$(powershell.exe -NoProfile -NonInteractive -Command "
    \$rx = '$rxq'; \$rxs = '$rxsq'
    \$lines = @(
      'bash -c ''bash /x/watch-bridge.sh app''',
      'bash -c ''bash /x/watch-bridge.sh \$(head -1 $win/.session-id)'''
    )
    foreach (\$l in \$lines) {
      \$id = \$null
      if (\$l -match \$rx) { \$id = \$Matches[1] }
      if (-not \$id -and \$l -match \$rxs) {
        try { \$id = (Get-Content -LiteralPath \$Matches[1] -TotalCount 1 -ErrorAction Stop).Trim() } catch { \$id = \$null }
      }
      if (\$id) { \$id } else { 'NONE' }
    }" 2>/dev/null | tr -d '\r' | paste -sd' ' -)"
  assert_eq "both spellings resolve to the same id" "app app" "$out"
}

# --------------------------------------------------------------------------
# slash commands: global copy vs. repo copy
# --------------------------------------------------------------------------

# On a name collision the GLOBAL command file wins over the repo copy, so a file can have
# travelled with the repo and still do nothing -- and a file listing shows both, which is
# why this went unnoticed for six weeks in the field. The check runs once per start run.
# `cc_check_commands` resolves its repo as the parent of the directory holding _lib.sh,
# so the fixture has to be a real little repo with a real history: the whole point is that
# the blob hash, not the mtime, decides which case it is.
test_commands() {
  head_ "slash commands: outdated / not in repo / not shared"
  local G="git -c user.name=t -c user.email=t@t -c init.defaultBranch=main"
  local root="$TMPROOT/cmd.$RANDOM" out
  mkdir -p "$root/repo/launcher" "$root/repo/.claude/commands" "$root/profile/commands"
  cp "$ROOT/launcher/_lib.sh" "$root/repo/launcher/_lib.sh"
  $G init -q "$root/repo"
  run_check() {
    ( export CLAUDE_CONFIG_DIR="$root/profile"
      # shellcheck source=/dev/null
      source "$root/repo/launcher/_lib.sh"
      cc_check_commands 2>&1
      echo "findings=${CC_COMMANDS_FINDINGS:-unset}" )
  }
  # v1 committed, then v2 committed -> the repo file has a history
  printf 'version one\n' > "$root/repo/.claude/commands/wrap.md"
  ( cd "$root/repo" && $G add -A && $G commit -qm v1 )
  printf 'version two\n' > "$root/repo/.claude/commands/wrap.md"
  ( cd "$root/repo" && $G add -A && $G commit -qm v2 )

  # 1. identical -> silence
  cp "$root/repo/.claude/commands/wrap.md" "$root/profile/commands/wrap.md"
  assert_eq "identical copies produce no finding" "findings=0" "$(run_check)"

  # 2. the global copy is the OLD committed version -> OUTDATED (history decides, not mtime)
  printf 'version one\n' > "$root/profile/commands/wrap.md"
  out="$(run_check)"
  if printf '%s\n' "$out" | grep -q 'wrap.md: OUTDATED'; then
    ok "an older checked-in version is reported as outdated"
  else bad "an older checked-in version is reported as outdated" "$out"; fi
  # and the mtime points the other way -- the repo file is the newer one on disk
  touch "$root/repo/.claude/commands/wrap.md"
  if printf '%s\n' "$(run_check)" | grep -q 'OUTDATED'; then
    ok "... even when the repo file has the newer mtime (a pull stamps it)"
  else bad "... even when the repo file has the newer mtime" "$(run_check)"; fi

  # 3. the global copy is in no commit -> NOT IN REPO, and it must not be overwritten
  printf 'local edits nobody saved\n' > "$root/profile/commands/wrap.md"
  out="$(run_check)"
  if printf '%s\n' "$out" | grep -q 'wrap.md: NOT IN REPO'; then
    ok "an uncommitted global version is reported as not in the repo"
  else bad "an uncommitted global version is reported as not in the repo" "$out"; fi
  if printf '%s\n' "$out" | grep -q 'do not overwrite'; then
    ok "... and the fix says not to overwrite it"
  else bad "... and the fix says not to overwrite it" "$out"; fi

  # 4. global only -> NOT SHARED (does not exist on the other machine)
  rm "$root/profile/commands/wrap.md"
  cp "$root/repo/.claude/commands/wrap.md" "$root/profile/commands/wrap.md"
  printf 'only here\n' > "$root/profile/commands/solo.md"
  out="$(run_check)"
  if printf '%s\n' "$out" | grep -q 'solo.md: NOT SHARED'; then
    ok "a global-only command is reported as not shared"
  else bad "a global-only command is reported as not shared" "$out"; fi
  assert_eq "... and it is the only finding" "findings=1" "$(printf '%s\n' "$out" | tail -1)"

  # 5. repo only is deliberately NOT a finding (those work through --add-dir)
  rm "$root/profile/commands/solo.md"
  printf 'repo side only\n' > "$root/repo/.claude/commands/repoonly.md"
  ( cd "$root/repo" && $G add -A && $G commit -qm repoonly )
  assert_eq "a repo-only command is not a finding" "findings=0" "$(run_check)"

  # 6. nothing to compare -> silent, and never fatal
  rm -rf "$root/repo/.claude"
  assert_eq "no repo copy -> silent" "findings=0" "$(run_check)"
  # the by-hand entry point says so instead of staying silent
  rc=0; out="$(CLAUDE_CONFIG_DIR="$root/profile" bash "$ROOT/launcher/check-commands.sh" 2>&1)" || rc=$?
  if [[ $rc -eq 1 ]] && printf '%s\n' "$out" | grep -q 'nothing to compare'; then
    ok "check-commands.sh says when there is nothing to compare"
  else bad "check-commands.sh says when there is nothing to compare" "rc=$rc $out"; fi
}

# --------------------------------------------------------------------------
# every path is canonicalised before it is compared or turned into a slug
# --------------------------------------------------------------------------

# The rule: `cd … && pwd -P` BEFORE `cygpath`, wherever a path becomes a profile slug or is
# compared against another path. Windows keeps an 8.3 short name for long directories, and a
# mount alias (`/tmp`) is a second spelling too -- compare two spellings of one directory and
# you silently find nothing. Three places had drifted apart for two days.
#
# Why structural and not behavioural: on a machine where both spellings coincide the
# behavioural tests pass no matter what -- which is exactly how it stayed unnoticed. This
# reads the rule instead of its effect.
#
# Deliberately NOT a blanket "every cygpath must canonicalise": the first draft of this check
# flagged install-watcher.sh, which converts a path in order to WRITE it into another
# session's arming paragraph. There the unresolved spelling is the better one -- it is what
# the reader typed. Emitting is not comparing. So the check has two precise halves instead of
# one broad heuristic:
#   A) any block that builds a slug (`[^A-Za-z0-9]/-/g`) -- a slug is always a lookup key;
#   B) a named list of the functions that compare paths.
# A new comparison site has to be added to (B) by hand; that is the price of not flagging
# code which merely renders a path.
canon_slug_offenders() { # $1 = file, $2 = label -> blocks that slug without canonicalising
  awk -v F="$2" '
    /^[ \t]*#/ { next }
    /^[a-z_]+\(\)[ \t]*\{/ { fn=$1; sub(/\(\).*/,"",fn); inb=1; has=0; can=0; next }
    inb && /^\}/ { if (has && !can) print F ": " fn; inb=0; next }
    {
      s = ($0 ~ /\[\^A-Za-z0-9\]\/-\/g/)
      p = ($0 ~ /pwd -P/)
      if (inb) { if (s) has=1; if (p) can=1 }
      else     { if (s) mhas=1; if (p) mcan=1 }
    }
    END { if (mhas && !mcan) print F ": (top level)" }
  ' "$1"
}

# --------------------------------------------------------------------------
# a missing INDEX slug: sync backlog, or an index older than a rename?
# --------------------------------------------------------------------------

# Reported by the coordinating session: renaming is the prescribed way to resolve a number
# collision, so EVERY correctly executed repair made the fold claim "the sync client is still
# fetching" and send the reader off to wait. The fix does not swap one asserted reason for
# another -- a thread with the same name part under a different number is evidence, not proof
# (two threads may legitimately share a name), so both explanations are printed and the
# candidate is shown as a candidate. Own fixture: adding a rename to a shared bridge would
# move which file decides the fold and silently invalidate the neighbouring assertions.
test_indexrename() {
  head_ "INDEX: a missing slug names both explanations, and the rename candidate"
  local b out
  b="$TMPROOT/idxren.$RANDOM"
  mkdir -p "$b/threads/221-release-notes/msgs" "$b/threads/003-unrelated/msgs" "$b/_archiv"
  {
    echo "# INDEX"
    echo ""
    echo "| Slug | Status |"
    echo "|---|---|"
    echo "| \`172-release-notes\` | OPEN |"
    echo "| \`221-release-notes\` | OPEN |"
    echo "| \`003-unrelated\` | OPEN |"
  } > "$b/INDEX.md"
  fold() { SESSION_BRIDGE_DIR="$b" WATCH_BRIDGE_SETTLE=0 bash "$ROOT/bridge/watch-bridge.sh" --fold someone 2>&1; }

  out="$(fold)"
  if printf '%s
' "$out" | grep -qF 'Two explanations, both possible'; then
    ok "a rename candidate makes the fold name both explanations"
  else bad "a rename candidate makes the fold name both explanations" "$out"; fi
  if printf '%s
' "$out" | grep -qF '172-release-notes -> 221-release-notes'; then
    ok "... and names the candidate, old slug to new"
  else bad "... and names the candidate, old slug to new" "$out"; fi
  if printf '%s
' "$out" | grep -qF 'Evidence, not proof'; then
    ok "... as a candidate, not as the reason (two threads may share a name)"
  else bad "... as a candidate, not as the reason" "$out"; fi
  if printf '%s
' "$out" | grep -qF 'The sync client is probably still fetching'; then
    bad "the asserted single reason is gone when a candidate exists" "$out"
  else ok "the asserted single reason is gone when a candidate exists"; fi

  # no candidate -> the old wording stays; the sync backlog really is the likely cause
  rm -rf "$b/threads/221-release-notes"
  out="$(fold)"
  if printf '%s
' "$out" | grep -qF 'The sync client is probably still fetching'; then
    ok "without a candidate the sync-backlog wording stays"
  else bad "without a candidate the sync-backlog wording stays" "$out"; fi
  if printf '%s
' "$out" | grep -qF 'Two explanations'; then
    bad "no candidate, no candidate line" "$out"
  else ok "no candidate, no candidate line"; fi

  # the archive is a location too: a renamed thread may already have moved there
  mkdir -p "$b/_archiv/221-release-notes/msgs"
  out="$(fold)"
  if printf '%s
' "$out" | grep -qF '172-release-notes -> 221-release-notes'; then
    ok "a candidate in _archiv/ counts as well"
  else bad "a candidate in _archiv/ counts as well" "$out"; fi

  # nothing missing -> no warning at all (the check must not invent work)
  mkdir -p "$b/threads/172-release-notes/msgs"
  out="$(fold)"
  if printf '%s
' "$out" | grep -qF 'listed in INDEX'; then
    bad "complete index, no warning" "$out"
  else ok "complete index, no warning"; fi

  # a slug without a leading number has no number to differ in -> no candidate, no crash
  rm -rf "$b/threads/172-release-notes"
  {
    echo "# INDEX"; echo ""; echo "| Slug | Status |"; echo "|---|---|"
    echo "| \`release-notes\` | OPEN |"
  } > "$b/INDEX.md"
  out="$(fold)"
  if printf '%s
' "$out" | grep -qF 'Two explanations'; then
    bad "a numberless slug yields no candidate" "$out"
  else ok "a numberless slug yields no candidate"; fi
  if printf '%s
' "$out" | grep -qF 'listed in INDEX, but in neither'; then
    ok "... but it is still reported as missing"
  else bad "... but it is still reported as missing" "$out"; fi
}

# --------------------------------------------------------------------------
# files that exist only in the profile: named BEFORE the conflict abort
# --------------------------------------------------------------------------

# Two sessions reported the same gap on the same day after consolidating their notebook
# memory: a per-file comparison only ever sees the intersection, and the files that exist
# on one side alone are copied in with no comparison at all -- which is where they found
# three genuine contradictions with the target, while the one reported conflict file
# carried five idle words. The tool did name those files, but only AFTER the abort had
# already exited, so a session planning its work never saw them. The notice now comes
# first. It stays silent about contradictions when the target is empty: there is nothing
# there to contradict, and a warning would be false.
test_movesnotice() {
  head_ "link-memory: profile-only files are named before the conflict stops the run"
  local LM="$ROOT/launcher/link-memory.sh"
  local cfg repo slug mem out rc
  cfg="$TMPROOT/mncfg.$RANDOM"; repo="$TMPROOT/mnrepo.$RANDOM"
  mkdir -p "$repo/memory"
  slug="$(slug_of "$repo")"; mem="$cfg/projects/$slug/memory"; mkdir -p "$mem"
  # target already holds a memory; profile has one conflict and two files of its own
  echo idx        > "$repo/memory/MEMORY.md"
  echo target     > "$repo/memory/shared.md"
  echo idx        > "$mem/MEMORY.md"
  echo profile    > "$mem/shared.md"
  echo own1       > "$mem/own1.md"
  echo own2       > "$mem/own2.md"

  rc=0; out="$(CLAUDE_CONFIG_DIR="$cfg" bash "$LM" -n "$repo" 2>&1)" || rc=$?
  assert_eq "a conflict still stops the run" "1" "$rc"
  if printf '%s\n' "$out" | grep -qF 'own1.md own2.md'; then
    ok "the profile-only files are named even though the run aborts"
  else bad "the profile-only files are named even though the run aborts" "$out"; fi
  if printf '%s\n' "$out" | grep -qF 'The script compares nothing for these'; then
    ok "... and it says why they are the unchecked half"
  else bad "... and it says why they are the unchecked half" "$out"; fi
  # order matters: after the abort text the reader has already stopped reading
  if [ "$(printf '%s\n' "$out" | grep -n 'only in the profile' | cut -d: -f1)" -lt \
       "$(printf '%s\n' "$out" | grep -n 'nothing touched' | cut -d: -f1)" ]; then
    ok "the notice comes before the abort, not after it"
  else bad "the notice comes before the abort, not after it" "$out"; fi
  if printf '%s\n' "$out" | grep -qF 'shared.md'; then
    ok "the conflict is still reported too"
  else bad "the conflict is still reported too" "$out"; fi

  # empty target -> the files come in, but there is nothing they could contradict
  local repo2 cfg2 mem2
  cfg2="$TMPROOT/mncfg2.$RANDOM"; repo2="$TMPROOT/mnrepo2.$RANDOM"; mkdir -p "$repo2"
  mem2="$cfg2/projects/$(slug_of "$repo2")/memory"; mkdir -p "$mem2"
  echo own1 > "$mem2/own1.md"; echo idx > "$mem2/MEMORY.md"
  rc=0; out="$(CLAUDE_CONFIG_DIR="$cfg2" bash "$LM" -n "$repo2" 2>&1)" || rc=$?
  assert_eq "empty target: exit 0" "0" "$rc"
  if printf '%s\n' "$out" | grep -qF 'exist only in the profile'; then
    ok "empty target: the files are still named"
  else bad "empty target: the files are still named" "$out"; fi
  if printf '%s\n' "$out" | grep -qF 'may contradict'; then
    bad "empty target: no contradiction warning (nothing to contradict)" "$out"
  else ok "empty target: no contradiction warning (nothing to contradict)"; fi

  # nothing profile-only at all -> no notice, no empty count line
  local cfg3 mem3
  cfg3="$TMPROOT/mncfg3.$RANDOM"; mem3="$cfg3/projects/$(slug_of "$repo")/memory"; mkdir -p "$mem3"
  echo idx > "$mem3/MEMORY.md"; echo target > "$mem3/shared.md"
  rc=0; out="$(CLAUDE_CONFIG_DIR="$cfg3" bash "$LM" -n "$repo" 2>&1)" || rc=$?
  if printf '%s\n' "$out" | grep -qF 'exist only in the profile'; then
    bad "nothing to move: no notice at all" "$out"
  else ok "nothing to move: no notice at all"; fi
}

# --------------------------------------------------------------------------
# "no profile memory": a fresh start, or the normal state on a second machine?
# --------------------------------------------------------------------------

# Two different situations shared one message. On a machine that has never held this
# project, the target is already full and nothing needs copying -- but the wording read
# like a deficiency, and the run was reported as suspect. The behaviour was always right
# (it goes through, exit 0, the count is correct); only the framing was missing, and the
# framing is what decides whether somebody stops and asks. Reported from the field after
# a stamp survey found this situation still ahead for almost every migrated project.
test_secondmachine() {
  head_ "link-memory: no profile memory is framed as normal when the target is populated"
  local LM="$ROOT/launcher/link-memory.sh"
  local cfg repo drive out rc
  drive="$TMPROOT/smdrive.$RANDOM"; mkdir -p "$drive/proj"
  printf 'a\n' > "$drive/proj/a.md"; printf 'b\n' > "$drive/proj/b.md"; printf 'i\n' > "$drive/proj/MEMORY.md"
  cfg="$TMPROOT/smcfg.$RANDOM"; repo="$TMPROOT/smrepo.$RANDOM"; mkdir -p "$repo" "$cfg"

  rc=0
  out="$(CLAUDE_CONFIG_DIR="$cfg" SESSION_MEMORY_DIR="$drive" bash "$LM" -n --cloud --name proj "$repo" 2>&1)" || rc=$?
  assert_eq "populated target, no profile memory: exit 0" "0" "$rc"
  if printf '%s\n' "$out" | grep -qF 'normal on a second machine'; then
    ok "it is named as the normal case, not as a deficiency"
  else bad "it is named as the normal case, not as a deficiency" "$out"; fi
  if printf '%s\n' "$out" | grep -qF 'already there (3 file(s))'; then
    ok "... and says how much is already in the target"
  else bad "... and says how much is already in the target" "$out"; fi
  if printf '%s\n' "$out" | grep -qF 'the same number (3)'; then
    ok "... and states the expected outcome, so a session can tell right from wrong"
  else bad "... and states the expected outcome" "$out"; fi

  # and the expectation has to hold when the run goes through
  rc=0
  out="$(CLAUDE_CONFIG_DIR="$cfg" SESSION_MEMORY_DIR="$drive" bash "$LM" --cloud --name proj "$repo" 2>&1)" || rc=$?
  assert_eq "link: exit 0" "0" "$rc"
  if printf '%s\n' "$out" | grep -qF '(3 file(s))'; then
    ok "the promised number is the one actually reported after linking"
  else bad "the promised number is the one actually reported after linking" "$out"; fi
  assert_eq "nothing was copied -- the target is unchanged" "MEMORY.md a.md b.md" \
    "$(ls -A "$drive/proj" | grep -v '^[.]last-wrap$' | LC_ALL=C sort | paste -sd' ' -)"

  # an EMPTY target is a genuinely fresh start -- there the old wording is the right one
  local cfg2 repo2 drive2
  drive2="$TMPROOT/smdrive2.$RANDOM"; mkdir -p "$drive2"
  cfg2="$TMPROOT/smcfg2.$RANDOM"; repo2="$TMPROOT/smrepo2.$RANDOM"; mkdir -p "$repo2" "$cfg2"
  rc=0
  out="$(CLAUDE_CONFIG_DIR="$cfg2" SESSION_MEMORY_DIR="$drive2" bash "$LM" -n --cloud --name fresh "$repo2" 2>&1)" || rc=$?
  assert_eq "empty target: exit 0" "0" "$rc"
  if printf '%s\n' "$out" | grep -qF 'will be created and linked'; then
    ok "empty target keeps the fresh-start wording"
  else bad "empty target keeps the fresh-start wording" "$out"; fi
  if printf '%s\n' "$out" | grep -qF 'normal on a second machine'; then
    bad "empty target does not claim a second machine" "$out"
  else ok "empty target does not claim a second machine"; fi
}

test_canonicalise() {
  head_ "paths are canonicalised before becoming a slug or being compared"
  local f offenders=""
  # (A) the shipped scripts -- every slug there is a lookup key
  for f in "$ROOT"/launcher/*.sh "$ROOT"/bridge/*.sh; do
    [[ -f "$f" ]] || continue
    offenders+="$(canon_slug_offenders "$f" "$(basename "$f")")"
  done
  assert_eq "no shipped script builds a slug without canonicalising first" "" "$offenders"

  # (B) the functions that COMPARE paths, by name -- each must canonicalise
  local fn file body missing=""
  for fn in "cc_session_running:$ROOT/launcher/_lib.sh" \
            "cc_has_transcript:$ROOT/launcher/_lib.sh" \
            "cc_memory_state:$ROOT/launcher/_lib.sh" \
            "norm:$ROOT/launcher/link-memory.sh" \
            "id_from_table:$ROOT/launcher/link-memory.sh"; do
    file="${fn##*:}"; fn="${fn%%:*}"
    # index() instead of a dynamic regex: escaping ( ) { inside an awk string is a trap of
    # its own (it cost two attempts here), and a plain-text match is what is meant anyway.
    body="$(awk -v n="$fn" 'index($0, n "() {")==1 {i=1} i {print} i && /^}/ {exit}' "$file")"
    [[ -n "$body" ]] || { missing+="$fn (not found) "; continue; }
    # id_from_table compares via norm(), so it counts as covered by norm's own check
    if [[ "$fn" == "id_from_table" ]]; then
      printf '%s' "$body" | grep -q 'norm ' || missing+="$fn "
    else
      printf '%s' "$body" | grep -q 'pwd -P' || missing+="$fn "
    fi
  done
  assert_eq "every path-comparing function canonicalises (or delegates to one that does)" "" "$missing"

  # the check must be able to fail, or it guards nothing
  local probe="$TMPROOT/canon.$RANDOM.sh"
  { printf 'f() {\n'; printf '  echo "$1" | sed s/[^A-Za-z0-9]/-/g\n'; printf '}\n'; } > "$probe"
  if [[ -n "$(canon_slug_offenders "$probe" probe)" ]]; then
    ok "the check detects a slug built without canonicalising (it can go red)"
  else bad "the check detects a slug built without canonicalising (it can go red)" "probe not flagged"; fi
}

case "${1:-all}" in
  watcher) test_watcher ;;
  commands) test_commands ;;
  canonicalise) test_canonicalise ;;
  indexrename) test_indexrename ;;
  movesnotice) test_movesnotice ;;
  secondmachine) test_secondmachine ;;
  stamp) test_stamp ;;
  ruleparity) test_ruleparity ;;
  lineendings) test_lineendings ;;
  inventoryids) test_inventory_ids ;;
  install) test_install ;;
  numbers) test_numbers ;;
  newthread) test_new_thread ;;
  coverage) test_coverage ;;
  checkout) test_checkout ;;
  launcher) test_launcher ;;
  resume) test_resume ;;
  pull) test_pull ;;
  autostart) test_autostart ;;
  addedrepos) test_addedrepos ;;
  instructions) test_instructions ;;
  isync) test_isync ;;
  reap) test_reap ;;
  linkmemory) test_linkmemory ;;
  all)     test_watcher; test_coverage; test_checkout; test_numbers; test_new_thread; test_install; test_launcher; test_resume; test_pull; test_autostart; test_addedrepos; test_instructions; test_isync; test_reap; test_linkmemory; test_stamp; test_ruleparity; test_lineendings; test_inventory_ids; test_commands; test_canonicalise; test_indexrename; test_movesnotice; test_secondmachine ;;
  *) echo "usage: run.sh [watcher|coverage|checkout|numbers|newthread|install|launcher|resume|pull|autostart|addedrepos|instructions|isync|reap|linkmemory|stamp|ruleparity|lineendings|inventoryids|commands|canonicalise|all]" >&2; exit 64 ;;
esac

printf '\n%s\n' "----------------------------------------"
printf 'passed: %d   failed: %d\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
