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

  head_ "watcher: bridge path resolution"
  SESSION_BRIDGE_DIR="$TMPROOT/does-not-exist" bash "$WATCHER" app 1 >/dev/null 2>&1
  assert_eq "invalid SESSION_BRIDGE_DIR aborts (no silent fallback)" "1" "$?"
  bash "$WATCHER" >/dev/null 2>&1
  assert_eq "no arguments -> usage, exit 64" "64" "$?"
  SESSION_BRIDGE_DIR="$b" bash "$WATCHER" --status app >/dev/null 2>&1
  assert_eq "--status exits 0 even with nothing running" "0" "$?"

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

case "${1:-all}" in
  watcher) test_watcher ;;
  install) test_install ;;
  all)     test_watcher; test_install ;;
  *) echo "usage: run.sh [watcher|install|all]" >&2; exit 64 ;;
esac

printf '\n%s\n' "----------------------------------------"
printf 'passed: %d   failed: %d\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
