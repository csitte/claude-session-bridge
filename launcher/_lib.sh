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

# cc_session_running — is a Claude session already running for this entry?
#
# Neither the launcher nor the session manager ever checked this; cc_launch knew
# exactly one reason to skip, the missing directory. A second start puts a second
# window on the same project; both sessions then work in the same tree, and at the
# bridge watcher the second arm steps aside (see docs/watcher.md), so the new
# session is SILENT — the same picture as two checkouts sharing one id, from a
# different cause.
#
# Source is ~/.claude/sessions/*.json — one file per RUNNING session, with `pid`,
# `cwd` and `name` (a by-product of Claude Code's native cross-session messaging).
#
# Why not the mintty window title: the title belongs to the WINDOW, not to the
# session. `exec bash` keeps the window open after claude exits — the title outlives
# the session it names. Measured once: 16 mintty windows, 15 running sessions.
#
# `cwd` is compared as a WHOLE path and `name` as a whole token, never as a
# substring: `D:/work/app` is contained in `D:/work/app-product`.
#
# No registry (older Claude version, another CLAUDE_CONFIG_DIR) means NO, and the
# start proceeds as before: better a duplicate window than a session that can no
# longer be started.
#
# An entry counts only if its `pid` is ALIVE: the registry file disappears only on
# a clean exit. After an unattended reboot the entries of every killed session were
# still there, the launcher took each one for running and started nothing — a
# second attempt worked only because Claude Code prunes dead entries when it
# starts. The process must be named `claude`, or a pid reused after the reboot
# would count as a hit. An EMPTY list means "nothing is alive", not "check broken":
# after a reboot it is rightly empty, and exactly then the start must go through.
#
# Test hook: CC_LIVE_PIDS (set, even if empty) replaces the process list.

# cc_live_claude_pids — Windows pids of all running claude processes, one per line.
# `ps -W` (msys) shows the Windows pid in column 4 and the command path last; the
# registry carries the same Windows pid. Without `ps -W` (not msys) the list is empty.
cc_live_claude_pids() {
  ps -W 2>/dev/null | awk 'NR > 1 && $NF ~ /[\/\\]claude(\.exe)?$/ { print $4 }'
}

cc_session_running() { # $1 = name, $2 = directory (msys path) -> 0 = already running
  local want_name="$1" want_dir="$2" f n c win pid pids
  local dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/sessions"
  [[ -d "$dir" ]] || return 1

  # msys path -> the Windows form the registry uses; without cygpath (not msys)
  # rewrite /d/x by hand, or the cwd branch is dead and only the name ever matches.
  win="$(cygpath -m "$want_dir" 2>/dev/null || printf '%s' "$want_dir" | sed -E 's|^/([a-zA-Z])/|\1:/|')"
  win="$(printf '%s' "$win" | tr 'A-Z' 'a-z' | tr -s '/' | sed 's|/$||')"
  pids="${CC_LIVE_PIDS-$(cc_live_claude_pids)}"

  for f in "$dir"/*.json; do
    [[ -f "$f" ]] || continue
    # A dead pid is a leftover entry and does not count. No pid field: same.
    pid="$(grep -oE '"pid":[0-9]+' "$f" | head -1 | cut -d: -f2)"
    [[ -n "$pid" ]] && grep -qx "$pid" <<<"$pids" || continue
    n="$(grep -oE '"name":"[^"]*"' "$f" | head -1 | cut -d'"' -f4 | tr 'A-Z' 'a-z')"
    c="$(grep -oE '"cwd":"[^"]*"' "$f" | head -1 | cut -d'"' -f4 \
         | awk '{ gsub(/\\\\/,"/"); print tolower($0) }' | tr -s '/' | sed 's|/$||')"
    [[ -n "$c" && "$c" == "$win" ]] && return 0
    [[ -n "$n" && "$n" == "$(printf '%s' "$want_name" | tr 'A-Z' 'a-z')" ]] && return 0
  done
  return 1
}

# cc_pull_before_start — pulls the project repo from 'vps' (else from the upstream)
# BEFORE the session starts. Motivation: sessions alternate between two machines, and
# the launcher used to start whatever state happened to be on disk — CLAUDE.md,
# scripts and (with link-memory.sh) the memory only travel by push/pull.
# Fast-forward only. A local lead, a dirty tree, a sleeping remote are REPORTED and the
# session starts anyway: a silently skipped pull would be the worse failure (same rule
# as a lost --continue). Not a repo: silent. Neither 'vps' nor an upstream: said, not
# pulled. CC_NO_PULL=1 (--no-pull) skips the step, e.g. offline. ssh with ConnectTimeout
# and BatchMode so that neither a sleeping remote nor a passphrase prompt holds up the
# start. Always returns 0 — the pull never decides about the start.
cc_pull_before_start() { # $1 = name, $2 = directory (msys path)
  local name="$1" dir="$2" remote branch before after out
  [[ "${CC_NO_PULL:-0}" == "1" ]] && return 0
  git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  if git -C "$dir" remote get-url vps >/dev/null 2>&1; then
    remote=vps; branch="$(git -C "$dir" symbolic-ref --short HEAD 2>/dev/null || true)"
  elif branch="$(git -C "$dir" rev-parse --abbrev-ref '@{u}' 2>/dev/null)"; then
    remote="${branch%%/*}"; branch="${branch#*/}"
  else
    echo "[pull] $name: neither a remote 'vps' nor an upstream -- not pulled." >&2; return 0
  fi
  [[ -n "$branch" ]] || { echo "[pull] $name: no branch (detached HEAD) -- not pulled." >&2; return 0; }
  before="$(git -C "$dir" rev-parse --short HEAD 2>/dev/null || true)"
  if out="$(GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh} -o ConnectTimeout=5 -o BatchMode=yes" \
            git -C "$dir" pull --ff-only "$remote" "$branch" 2>&1)"; then
    after="$(git -C "$dir" rev-parse --short HEAD 2>/dev/null || true)"
    [[ "$before" == "$after" ]] || echo "[pull] $name: $remote/$branch caught up ($before -> $after)." >&2
  else
    echo "[pull] $name: $remote/$branch NOT pulled -- the session starts with the state on disk:" >&2
    printf '       %s\n' "$(printf '%s\n' "$out" | grep -v '^$' | tail -3)" >&2
  fi
  return 0
}

# cc_launch — starts ONE entry in its own mintty window.
# Format:  "name|path"  or  "name|path|extra-args"  (3rd field passed to claude as-is).
# Returns: 0 = started, 1 = skipped (directory missing),
#          2 = already running (not an error, see cc_session_running).
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

  # Its own return value, not 1: "already running" is the normal case on a second
  # run and must not keep the starter console open as an error.
  # CC_FORCE=1 (--force) starts anyway — there are legitimate cases, e.g. a second
  # window on the same project for a quick job on the side.
  if [[ "${CC_FORCE:-0}" != "1" ]] && cc_session_running "$name" "$dir"; then
    echo "[running] $name: a session is already running in '$dir' — not started again." >&2
    return 2
  fi

  # Pull first, then start — otherwise the session runs on the other machine's state
  # from yesterday (see cc_pull_before_start).
  cc_pull_before_start "$name" "$dir"

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
