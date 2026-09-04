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

# cc_has_transcript — is there anything to resume for this directory?
#
# `claude --continue` aborts interactively when the current directory holds no transcript
# yet ("No conversation found"): the window then sits there empty and the session never
# starts at all. In print mode (`-p`) this does NOT happen — there claude silently falls
# back to a new conversation, so anyone reproducing the behaviour with `-p` never sees it.
#
# Transcripts live under ~/.claude/projects/<encoded>/*.jsonl. Encoded = the WINDOWS path
# with every non-alphanumeric character replaced by '-' (colon, backslash, dot and space
# alike). Verified against a plain path and one containing spaces. Case does not matter:
# both spellings occur in the wild, and NTFS does not distinguish them.
#
# If the detection fails we deliberately start WITHOUT --continue and SAY so. A silently
# lost --continue would be the worse failure: the session would then run without its
# history and nobody would notice.
cc_has_transcript() { # $1 = directory (msys path) -> 0 = resumable
  local win enc d
  # Canonicalise as in cc_session_running and cc_memory_state: two spellings of one
  # directory (8.3 short name against the long one) give two different slugs, and this
  # function would then not find the existing transcript — the session would start without
  # `--continue` and lose its history. No test case covers that; it is carried here because
  # it is the same class as the cases next to it.
  d="$(cd "$1" 2>/dev/null && pwd -P)" || d="$1"
  win="$(cygpath -w "$d" 2>/dev/null)" || return 1
  [[ -n "$win" ]] || return 1
  enc="$(printf '%s' "$win" | sed 's/[^A-Za-z0-9]/-/g')"
  compgen -G "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/$enc/*.jsonl" >/dev/null 2>&1
}

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

  # Canonicalise first, then convert -- the same rule as in cc_memory_state and
  # link-memory.sh: two spellings of one directory (an 8.3 short name against the long one,
  # or a mount alias like /tmp) give two different strings, and the cwd branch would then
  # not find the running session -- the launcher would start a second one in the same tree,
  # which is exactly what this function exists to prevent. If the directory does not exist
  # the value is kept as passed: the name comparison below must still work.
  want_dir="$(cd "$want_dir" 2>/dev/null && pwd -P)" || want_dir="$2"
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

# cc_check_commands — compares the global slash commands under ~/.claude/commands with a
# copy kept in this repo under .claude/commands. ONCE per start run, not per project: this
# is a state of the MACHINE, and showing the same message fifteen times would be noise.
#
# Why it exists: on a name collision the **global** file wins over the project copy. A
# command file can therefore have travelled correctly with the repo and still do nothing —
# and the file listing shows both, so it looks right. In the field one wrap-up command ran
# for six weeks in a version from six weeks earlier while the current one sat next to it,
# unused. The profile under ~/.claude/ does not travel between machines, and nobody
# compares it by hand.
#
# Three findings, silence otherwise:
#   OUTDATED     Both exist, contents differ, and the global version appears in the repo
#                file's history -> it is an older checked-in copy. Fix: copy from the repo.
#   NOT IN REPO  Both exist, differ, and the global version is in no commit -> it carries
#                changes that are saved nowhere. Fix: adopt it into the repo, do not
#                overwrite it.
#   NOT SHARED   Global only -> it does not exist on the other machine. Fix: put it in the
#                repo.
# "Repo only" is deliberately not a finding: such commands work through --add-dir.
#
# Why history and not mtime decides: a `git pull` stamps the repo file with the checkout
# time, so it always looks newer, even when its content is older. That is exactly the case
# that hid the incident above. The blob hash does not lie.
#
# Always returns 0 -- the display never decides about the start. The number of findings is
# left in CC_COMMANDS_FINDINGS for check-commands.sh, which also reports the all-clear.
cc_check_commands() {
  local repo glob rel f name h rev b found n=0
  repo="$(cd "$CC_SCRIPT_DIR/.." && pwd)"
  glob="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/commands"
  CC_COMMANDS_FINDINGS=0
  [[ -d "$repo/.claude/commands" && -d "$glob" ]] || return 0
  git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0

  for f in "$glob"/*.md; do
    [[ -f "$f" ]] || continue
    name="$(basename "$f")"
    rel=".claude/commands/$name"
    if [[ ! -f "$repo/$rel" ]]; then
      echo "[commands] $name: NOT SHARED -- only in this profile, missing from the repo." >&2
      echo "           Fix: put it in $repo/$rel and commit." >&2
      n=$((n + 1)); continue
    fi
    cmp -s "$f" "$repo/$rel" && continue
    # Does the global file's content appear in the history of the repo file?
    h="$(git -C "$repo" hash-object -- "$f" 2>/dev/null || true)"
    found=0
    if [[ -n "$h" ]]; then
      for rev in $(git -C "$repo" rev-list --max-count=50 HEAD -- "$rel" 2>/dev/null || true); do
        b="$(git -C "$repo" rev-parse "$rev:$rel" 2>/dev/null || true)"
        [[ "$b" == "$h" ]] && { found=1; break; }
      done
    fi
    if [[ "$found" == "1" ]]; then
      echo "[commands] $name: OUTDATED -- the global copy is an older checked-in version." >&2
      echo "           Fix: cp \"$repo/$rel\" \"$f\"" >&2
    else
      echo "[commands] $name: NOT IN REPO -- the global version is in no commit." >&2
      echo "           Fix: review it, then adopt it into $repo/$rel (do not overwrite)." >&2
    fi
    n=$((n + 1))
  done
  CC_COMMANDS_FINDINGS="$n"
  return 0
}

# cc_pull_before_start — pulls the project repo BEFORE the session starts. Motivation:
# sessions alternate between two machines, and the launcher used to start whatever state
# happened to be on disk — CLAUDE.md, scripts and (with link-memory.sh) the memory only
# travel by push/pull.
# Which remote: CC_PULL_REMOTE if set and present in this repo, else the branch's
# upstream, else nothing (said, not pulled). Set CC_PULL_REMOTE in your starter if your
# machines share a remote under a fixed name.
# Fast-forward only. A local lead, a dirty tree, a sleeping remote are REPORTED and the
# session starts anyway: a silently skipped pull would be the worse failure (same rule
# as a lost --continue). Not a repo: silent. CC_NO_PULL=1 (--no-pull) skips the step,
# e.g. offline. ssh with ConnectTimeout and BatchMode so that neither a sleeping remote
# nor a passphrase prompt holds up the start. Always returns 0 — the pull never decides
# about the start.
cc_pull_before_start() { # $1 = name, $2 = directory (msys path)
  local name="$1" dir="$2" remote branch before after out
  [[ "${CC_NO_PULL:-0}" == "1" ]] && return 0
  git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  if [[ -n "${CC_PULL_REMOTE:-}" ]] && git -C "$dir" remote get-url "$CC_PULL_REMOTE" >/dev/null 2>&1; then
    remote="$CC_PULL_REMOTE"; branch="$(git -C "$dir" symbolic-ref --short HEAD 2>/dev/null || true)"
  elif branch="$(git -C "$dir" rev-parse --abbrev-ref '@{u}' 2>/dev/null)"; then
    remote="${branch%%/*}"; branch="${branch#*/}"
  else
    echo "[pull] $name: no upstream and no CC_PULL_REMOTE -- not pulled." >&2; return 0
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

# cc_memory_state — reports the state of the project memory BEFORE the start. Source is
# `<memory>/.last-wrap`, written by the wrap-up ritual via `link-memory.sh --stamp`:
# `<host> <UTC> <file count>`.
#
# What is read is always the PROFILE path `~/.claude/projects/<slug>/memory` — that is the
# link, no matter whether the repo or a sync folder sits behind it. The launcher therefore
# does not need to know the mode.
#
# Two cases, silence otherwise (a message carries only if it names an action or says
# something you do not already know):
#   SHORTFALL    fewer files present than stamped -> the sync client is still loading.
#                Loud, because this is exactly where a session used to start with half a
#                memory.
#   OTHER HOST   stamp from the other machine -> one line, so it is visible how old the
#                state is. Own host = nothing travelled = nothing to say.
# MORE files than stamped is normal (written locally since the wrap), not a case. No stamp
# (not migrated, never wrapped) or unreadable: silent. Always returns 0 — the display never
# decides about the start.
cc_memory_state() { # $1 = name, $2 = directory (msys path)
  local name="$1" dir="$2" native slug mem shost sts scount actual ts_s now_s age=""
  # Canonicalise first, then build the slug -- exactly as link-memory.sh does when it creates
  # the folder. Without it the two tools compute different slugs as soon as Windows keeps an
  # 8.3 short name for a long directory (`C--Users-RUNNER-1-…` against
  # `C--Users-runneradmin-…`): the launcher would never see a stamp and would stay silent --
  # precisely the shortfall warning this function exists for. Measured on CI (5 cases).
  dir="$(cd "$dir" 2>/dev/null && pwd -P)" || return 0
  native="$(cygpath -w "$dir" 2>/dev/null || printf '%s' "$dir")"
  slug="$(printf '%s' "$native" | sed 's/[^A-Za-z0-9]/-/g')"
  mem="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/$slug/memory"
  [[ -d "$mem" && -r "$mem/.last-wrap" ]] || return 0
  read -r shost sts scount < "$mem/.last-wrap" 2>/dev/null || return 0
  [[ -n "$scount" && "$scount" != *[!0-9]* ]] || return 0
  # `ls -A` follows the link, `find` without `-L` does not -- and `$mem` IS a link for every
  # migrated project. An interim version using `find` counted 0, which made the condition
  # `actual < scount` unsatisfiable: the warning could never fire again. `{ grep … || true; }`
  # only neutralises the exit code, because if nothing remains after filtering `grep` returns
  # 1 -- and the starters run with `set -euo pipefail`, which would have aborted the whole
  # start run instead of warning. Two bugs on one line, both measured: the empty folder AND
  # access through the link. Whoever touches it checks both.
  actual="$(ls -A "$mem" 2>/dev/null | { grep -vxF '.last-wrap' || true; } | wc -l | tr -d ' ')"
  # Age only if `date -d` understands the stamp -- otherwise show the raw time.
  if ts_s="$(date -u -d "$sts" +%s 2>/dev/null)" && now_s="$(date -u +%s)"; then
    age=" ($(( (now_s - ts_s) / 60 )) min ago)"
  fi
  if (( actual < scount )); then
    echo "[memory] $name: $scount file(s) expected, $actual present -- sync still running (state $shost $sts$age)." >&2
    echo "         Wait a moment before working on; the session reads the memory ONCE at start." >&2
  elif [[ "$shost" != "$(hostname)" ]]; then
    echo "[memory] $name: state from $shost, $sts$age, $actual file(s)." >&2
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
  # And say how old the memory is, or that it has not fully arrived yet.
  cc_memory_state "$name" "$dir"

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

  # --continue only when there is something to resume (see cc_has_transcript).
  #
  # CC_FRESH=1 suppresses --continue for this run (the --fresh switch of the calling
  # scripts). It is needed to have the REMOTE session created anew: --continue attaches to
  # the existing one ("Reattaching to session cse_...", instead of "Created session"), and
  # that one keeps its name — including an old, hostname-generated one. The price is the
  # same as for /clear: an empty context. See the naming block below.
  local contarg="--continue"
  if [[ "${CC_FRESH:-0}" == "1" ]]; then
    contarg=""
    echo "[fresh] $name: --fresh set — starting without --continue (empty context, new remote session)." >&2
  elif ! cc_has_transcript "$dir"; then
    contarg=""
    echo "[new] $name: nothing to resume in '$dir' — starting fresh." >&2
  fi

  echo "[start] $name  ->  $dir"
  # --Title (capital T): pins the window title — Claude Code cannot overwrite it at
  #   runtime (lower-case -t/--title can be overwritten).
  # -o ConfirmExit=no: no "processes are running" dialog when closing.
  # 'exec bash': keeps the window open after claude exits (so errors stay readable).
  #
  # TWO NAMES IN TWO PLACES — they have nothing to do with each other:
  #
  # (1) LOCAL (prompt box, /resume picker, ~/.claude/sessions/<pid>.json): --name.
  #   Without it Claude DERIVES the name from the folder ("nameSource":"derived":
  #   app-af instead of Notes, acme-39 instead of mail) — and it does so afresh on every
  #   start, which is why it only became obvious after a reboot. --name also takes effect
  #   when resuming (measured: every session started with --continue carried its config
  #   name). This matters beyond cosmetics: cc_session_running above compares the registry
  #   `name` field, and without --name that comparison can never match — only the cwd
  #   branch would carry the guard.
  #
  # (2) REMOTE (claude.ai, phone): the name of the remote-control session. It is assigned
  #   when the session is CREATED — with --continue Claude attaches to the existing one
  #   ("Reattaching to session cse_...", visible with --debug-file) and inherits its old
  #   name. That is why sessions can keep showing a hostname-style name on the phone even
  #   though both flags below are on the command line: their remote sessions predate them,
  #   and a reboot changes nothing (the launcher passes --continue again afterwards). The
  #   only cure is a start without --continue -> CC_FRESH=1 / --fresh, see above.
  #   On creation, --name also names the remote session (measured: --name PROBE-A next to
  #   prefix PROBEA showed up as "PROBE-A", without the random suffix the prefix adds).
  #   --remote-control-session-name-prefix only steers AUTO-generated names (default: the
  #   hostname) and is therefore the fallback if no --name takes hold; --remote-control
  #   switches RC on even without the `remoteControlAtStartup` settings line. Both stay.
  mintty -o ConfirmExit=no --Title "$name" -e bash -lc \
    "cd '$dir' && claude $contarg $promptarg --name \"$name\" --remote-control \"$name\" --remote-control-session-name-prefix \"$name\" $extra; exec bash" &
  return 0
}
