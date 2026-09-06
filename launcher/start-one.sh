#!/usr/bin/env bash
#
# start-one.sh — starts exactly ONE session from the host config.
#
# Usage:  ./start-one.sh [--fresh] [--force] [--no-pull] "<project name>"
#
# Finds the entry in projects.<host>.conf — whether or not it is in the local autostart
# selection (starting something once does not make it an autostart; the list is complete,
# only the selection is local). Used by the session manager (session-manager.ps1), but
# works directly from Git Bash too.
# --fresh: start without '--continue' — an empty context, but a NEW remote session that
# carries the name from the config (see the naming block in _lib.sh).
# --no-pull: do not pull the project repo before the start (see
# cc_pull_before_start in _lib.sh) — e.g. offline.

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$DIR/_lib.sh"

fresh=0
force=0
nopull=0
name=""
for arg in "$@"; do
  case "$arg" in
    --fresh) fresh=1 ;;
    --force) force=1 ;;
    --no-pull) nopull=1 ;;
    *) name="$arg" ;;
  esac
done
[[ -n "$name" ]] || { echo "usage: start-one.sh [--fresh] [--force] [--no-pull] <project name>" >&2; exit 2; }
export CC_FRESH="$fresh"
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

# Not in the array. Since step 2 there are no #off lines left to search -- if the name
# still stands in one, the config is stale and the entry is invisible to bash. That is
# said, not worked around: starting the line here anyway would leave the prefix in place
# forever.
if cc_stale_off_lines "$cfg" | grep -qxF -- "$name"; then
  cc_warn_stale_off "$cfg" || true
  echo "[error] Project '$name' only stands in a stale '#off' line of $(basename "$cfg") -- remove the prefix, then try again." >&2
  exit 1
fi
echo "[error] Project '$name' not found in $(basename "$cfg")." >&2
exit 1
