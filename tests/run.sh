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
  if printf '%s\n' "$fold" | grep -q '012-done'; then
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

case "${1:-all}" in
  watcher) test_watcher ;;
  install) test_install ;;
  numbers) test_numbers ;;
  newthread) test_new_thread ;;
  coverage) test_coverage ;;
  checkout) test_checkout ;;
  all)     test_watcher; test_coverage; test_checkout; test_numbers; test_new_thread; test_install ;;
  *) echo "usage: run.sh [watcher|coverage|checkout|numbers|newthread|install|all]" >&2; exit 64 ;;
esac

printf '\n%s\n' "----------------------------------------"
printf 'passed: %d   failed: %d\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
