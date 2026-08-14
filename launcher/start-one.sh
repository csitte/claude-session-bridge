#!/usr/bin/env bash
#
# start-one.sh — starts exactly ONE session from the host config.
#
# Usage:  ./start-one.sh "<project name>"
#
# Finds the entry in projects.<host>.conf — including ones disabled with #off
# (starting something once does not make it an autostart). Used by the session
# manager (session-manager.ps1), but works directly from Git Bash too.

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$DIR/_lib.sh"

name="${1:?usage: start-one.sh <project name>}"

cfg="$(cc_resolve_config)" || exit 1
# shellcheck source=/dev/null
source "$cfg"   # defines projects=(...)

for entry in "${projects[@]}"; do
  if [[ "${entry%%|*}" == "$name" ]]; then
    if cc_launch "$entry"; then exit 0; else exit 1; fi
  fi
done

# Not in the active array -> look through the #off lines (disabled entries).
while IFS= read -r line; do
  line="${line#"${line%%[![:space:]]*}"}"   # trim left
  [[ "$line" == "#off "* ]] || continue
  quoted="${line#\#off }"
  eval "entry=$quoted"   # resolves \" exactly as the shell does when sourcing
  if [[ "${entry%%|*}" == "$name" ]]; then
    if cc_launch "$entry"; then exit 0; else exit 1; fi
  fi
done < "$cfg"

echo "[error] Project '$name' found neither active nor as #off in $(basename "$cfg")." >&2
exit 1
