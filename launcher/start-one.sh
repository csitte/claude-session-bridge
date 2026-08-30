#!/usr/bin/env bash
#
# start-one.sh — starts exactly ONE session from the host config.
#
# Usage:  ./start-one.sh [--force] [--no-pull] "<project name>"
#
# Finds the entry in projects.<host>.conf — including ones disabled with #off
# (starting something once does not make it an autostart). Used by the session
# manager (session-manager.ps1), but works directly from Git Bash too.
# --no-pull: do not pull the project repo before the start (see
# cc_pull_before_start in _lib.sh) — e.g. offline.

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$DIR/_lib.sh"

force=0
nopull=0
name=""
for arg in "$@"; do
  case "$arg" in
    --force) force=1 ;;
    --no-pull) nopull=1 ;;
    *) name="$arg" ;;
  esac
done
[[ -n "$name" ]] || { echo "usage: start-one.sh [--force] [--no-pull] <project name>" >&2; exit 2; }
export CC_FORCE="$force"
export CC_NO_PULL="${CC_NO_PULL:-$nopull}"

# Return 2 from cc_launch means "already running" and is NOT a failure — the
# session manager reads the exit code and would otherwise report an error where
# the guard has just done its job.
cc_exit() {
  local rc=0
  cc_launch "$1" || rc=$?
  case "$rc" in
    0|2) exit 0 ;;
    *)   exit 1 ;;
  esac
}

cfg="$(cc_resolve_config)" || exit 1
# shellcheck source=/dev/null
source "$cfg"   # defines projects=(...)

for entry in "${projects[@]}"; do
  if [[ "${entry%%|*}" == "$name" ]]; then
    cc_exit "$entry"
  fi
done

# Not in the active array -> look through the #off lines (disabled entries).
while IFS= read -r line; do
  line="${line#"${line%%[![:space:]]*}"}"   # trim left
  [[ "$line" == "#off "* ]] || continue
  quoted="${line#\#off }"
  # shellcheck disable=SC2086,SC2294  # same dequoting the shell does when sourcing the conf
  eval "entry=$quoted"   # resolves \" exactly as the shell does when sourcing
  if [[ "${entry%%|*}" == "$name" ]]; then
    cc_exit "$entry"
  fi
done < "$cfg"

echo "[error] Project '$name' found neither active nor as #off in $(basename "$cfg")." >&2
exit 1
