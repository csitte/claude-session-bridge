#!/usr/bin/env bash
#
# _lib.sh — shared mechanics of the Claude session launchers.
#
# Sourced by start-cc-sessions.sh and start-one.sh; holds the ONLY copy of the launch
# mechanics (mintty flags, exports). That way the details cannot drift apart between
# machines. The machine-specific DATA (project list, paths) lives next to it in
# projects.<host>.conf (example: projects.example.conf).
#

# --- Mechanics exports ---
# When started standalone from mintty (without the git-bash.exe wrapper) MSYSTEM is
# missing, and the child windows would not find 'claude' in PATH.
export MSYSTEM="${MSYSTEM:-MINGW64}"
# Suppresses the "summary vs. full session" dialog for large/old sessions
# -> '--continue' always loads the FULL session.
export CLAUDE_CODE_RESUME_TOKEN_THRESHOLD="${CLAUDE_CODE_RESUME_TOKEN_THRESHOLD:-999999999}"

# Directory of this file (all scripts and configs live together).
CC_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# cc_resolve_config — finds projects.<host>.conf for the current machine.
# Host from $HOSTNAME (fallback: the hostname command), lower-cased.
# Prints the path on stdout; returns 1 if no config exists.
cc_resolve_config() {
  local host cfg
  host="$(echo "${HOSTNAME:-$(hostname)}" | tr '[:upper:]' '[:lower:]')"
  cfg="$CC_SCRIPT_DIR/projects.$host.conf"
  if [[ ! -f "$cfg" ]]; then
    echo "[error] No config for host '$host': $cfg" >&2
    echo "        Available configs:" >&2
    ls "$CC_SCRIPT_DIR"/projects.*.conf 2>/dev/null | sed 's/^/          /' >&2
    return 1
  fi
  printf '%s\n' "$cfg"
}

# cc_launch — starts ONE entry in its own mintty window.
# Format:  "name|path"  or  "name|path|extra-args"  (3rd field passed to claude as-is).
# Returns: 0 = started, 1 = skipped (directory missing).
cc_launch() {
  local entry="$1" name rest dir extra=""
  name="${entry%%|*}"
  rest="${entry#*|}"
  dir="${rest%%|*}"
  [[ "$rest" == *"|"* ]] && extra="${rest#*|}"

  if [[ ! -d "$dir" ]]; then
    echo "[skipped] $name: directory '$dir' does not exist." >&2
    return 1
  fi

  # Start prompt: '--continue' alone runs NO turn — the session is there, but never
  # executes the arming ritual from its CLAUDE.md. After one machine restart we
  # therefore had 12 sessions running and 1 watcher armed: no push at all, until every
  # window had been touched by hand. The prompt forces exactly one turn and fences it
  # in ("do not begin a task" is load-bearing — without it, some CLAUDE.md files send
  # the session off into a full review unsupervised). Arming stays the session's own
  # job: Monitor is a tool call, and a watcher started by the launcher would have no
  # channel into the session (see docs/watcher.md).
  #
  # Passed as a file + $(cat) rather than inline, because the backticks in the wording
  # would otherwise become command substitutions inside this doubly nested quoting. If
  # the file is missing, the session starts as it did before — unarmed, but it starts.
  local promptarg=""
  if [[ -r "$CC_SCRIPT_DIR/session-startprompt.txt" ]]; then
    promptarg="\"\$(cat '$CC_SCRIPT_DIR/session-startprompt.txt')\""
  else
    echo "[note] $name: session-startprompt.txt missing — the session will not arm itself." >&2
  fi

  echo "[start] $name  ->  $dir"
  # --Title (capital T): pins the window title — Claude Code cannot overwrite it at
  #   runtime (lower-case -t/--title can be overwritten).
  # -o ConfirmExit=no: no "processes are running" dialog when closing.
  # 'exec bash': keeps the window open after claude exits (so errors stay readable).
  mintty -o ConfirmExit=no --Title "$name" -e bash -lc \
    "cd '$dir' && claude --continue $promptarg --remote-control \"$name\" $extra; exec bash" &
  return 0
}
