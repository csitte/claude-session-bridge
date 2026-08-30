#!/usr/bin/env bash
#
# start-cc-sessions.sh — starts ALL autostart sessions of this machine.
#
# Mechanics: _lib.sh (identical on every machine)
# Data:      projects.<host>.conf  (example: projects.example.conf)
#
# From Git Bash:   ./start-cc-sessions.sh [--force] [--no-pull]
# By double click: start-cc.cmd (finds this script relative to itself).
#
# Resuming: the launch passes '--continue'. If --remote-control falls back to a NEW
# session, type '/resume' in that window and pick the right conversation.
#
# A project whose session is already running is not started again (registry
# ~/.claude/sessions/, live pid only — see cc_session_running). --force starts anyway.
#
# Before each start the project repo is pulled — fast-forward only, from CC_PULL_REMOTE
# or the branch's upstream; a failure is reported and the session starts anyway (see
# cc_pull_before_start in _lib.sh). Reason: sessions alternate between machines and the
# state only travels by push/pull. --no-pull skips that, e.g. offline.

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$DIR/_lib.sh"

force=0
nopull=0
for arg in "$@"; do
  case "$arg" in
    --force) force=1 ;;
    --no-pull) nopull=1 ;;
    -h|--help) echo "usage: $(basename "$0") [--force] [--no-pull]"; exit 0 ;;
    *) echo "[error] unknown argument '$arg' (allowed: --force, --no-pull)." >&2; exit 2 ;;
  esac
done
export CC_FORCE="$force"
export CC_NO_PULL="$nopull"

cfg="$(cc_resolve_config)" || { read -n 1 -s -r -p "Press any key to close ..."; echo; exit 1; }
# shellcheck source=/dev/null
source "$cfg"   # defines projects=(...)

# Machine state, ONCE per start run (not per project): if the global slash commands differ
# from the repo copy, a travelled version is having no effect -- on a name collision
# ~/.claude/commands wins. Purely advisory (cc_check_commands always returns 0 and only
# speaks when there is something to do).
cc_check_commands

skipped=0
started=0
running=0
for entry in "${projects[@]}"; do
  # 0 = started, 2 = already running (not an error), anything else = skipped.
  # `|| rc=$?` is mandatory: under `set -e` any non-zero return ends the whole
  # script, and that is exactly what every skipped entry returns.
  rc=0; cc_launch "$entry" || rc=$?
  case "$rc" in
    0) started=$((started + 1)) ;;
    2) running=$((running + 1)) ;;
    *) skipped=$((skipped + 1)) ;;
  esac
done

# Detach the background windows so the starter console can close cleanly.
disown -a 2>/dev/null || true

echo
echo "Done: $started window(s) started, $running already running, $skipped skipped  (config: $(basename "$cfg"))."
if [[ "$skipped" -ne 0 ]]; then
  echo
  echo "WARNING: at least one project was skipped - please check above."
  read -n 1 -s -r -p "Press any key to close ..."; echo
fi

# Exit code 1 when something was skipped -> the starter console (start-cc.cmd) stays open.
[[ "$skipped" -eq 0 ]]
