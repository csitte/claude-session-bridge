#!/usr/bin/env bash
#
# check-commands.sh — compares the global slash commands (~/.claude/commands) with the
# copy kept in this repo under .claude/commands.
#
# The mechanics live in _lib.sh (cc_check_commands); this script is only the by-hand
# entry point. The start run calls the same function once before the project loop. Here
# there is one addition: an all-clear. During a start run silence is the right answer;
# when you call it yourself you want to know THAT it checked.
#
# Why this exists: the profile under ~/.claude/ does not travel between machines. A copy
# in the repo does travel, but on a name collision it loses against the global file — so
# it can be present and still have no effect. That is invisible in a file listing, which
# shows both.
#
# Usage:  ./check-commands.sh
# Returns: 0 = in step, 10 = at least one finding (for callers that want to react),
#          1 = nothing to compare.

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$DIR/_lib.sh"

repo="$(cd "$DIR/.." && pwd)"
glob="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/commands"

if [[ ! -d "$repo/.claude/commands" ]]; then
  echo "[commands] No repo copy under $repo/.claude/commands -- nothing to compare." >&2
  exit 1
fi
if [[ ! -d "$glob" ]]; then
  echo "[commands] No global command directory under $glob -- nothing to compare." >&2
  exit 1
fi

cc_check_commands

if [[ "${CC_COMMANDS_FINDINGS:-0}" -eq 0 ]]; then
  echo "[commands] In step: $(ls -1 "$glob"/*.md 2>/dev/null | wc -l | tr -d ' ') global command file(s) checked."
  exit 0
fi
exit 10
