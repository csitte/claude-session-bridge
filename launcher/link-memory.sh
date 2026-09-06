#!/usr/bin/env bash
#
# link-memory.sh — puts a project's Claude Code memory in a place that travels between
# machines and links the profile path to it (junction on Windows, symlink elsewhere).
#
# Usage:  link-memory.sh [-n] [<repo-dir>]                        target <repo>/memory  (repo mode)
#         link-memory.sh [-n] --git [--name <id>] [<repo-dir>]    target <parent>/_session-memory/<id>
#         link-memory.sh [-n] --cloud [--name <id>] [<repo-dir>]  target <cloud>/_session-memory/<id>
#         link-memory.sh --push [<repo-dir>]           commit and push the memory clone
#         link-memory.sh --retire [--name <id>] [<repo-dir>]   set the old cloud folder aside
#         link-memory.sh --mark-only --name <id>       only write this machine's marker
#         (default <repo-dir>: current directory)
#
# Why: Claude Code keeps the memory under ~/.claude/projects/<slug>/memory/, and the slug
# is the PATH of the working directory — D--work-app on one machine, C--work-app on the
# other. So the memory does not travel: a wrap-up on one machine saves into a folder the
# other machine never sees. The profile path becomes a link to a place that travels; run
# once per machine (the slug differs per machine, the target is the same).
#
# Three targets:
#   repo mode   <repo>/memory/ — only for infrastructure repos that exist for this purpose
#               alone: rides the push the wrap-up makes anyway, every memory write shows up
#               as a diff in `git status`.
#   git mode    <parent>/_session-memory/<id>/ — a clone of <host>/memory-<id>.git, ONE REPO
#               PER PROJECT. Why per project and not one for all: a clone fetches the WHOLE
#               tree, and whatever enters the history then sits on every machine that ever
#               clones it, undeletably. One shared repo would put every project's notes on
#               every machine that opens any project — including the ones that machine never
#               touches. With one repo per project a machine holds only what it uses: the
#               separation is BUILT rather than incidental.
#               Set SESSION_MEMORY_SSH_HOST (e.g. "git@example.com" or an ssh-config alias);
#               SESSION_MEMORY_SSH_PATH is the parent directory of the bare repos and
#               defaults to /opt/git. Without a host the mode aborts rather than guessing.
#               The clone root is DERIVED as a sibling of this repository (…/<parent>/
#               _session-memory), the same rule the launcher uses for other shared clones —
#               a derivation cannot go stale the way a second list of machine paths can.
#               SESSION_MEMORY_REPO_DIR overrides it (tests).
#               Note what the git mode does NOT do: carry writes without a commit. A sync
#               client did that for free; git does not. That is what `--push` and the
#               wrap-up step are for — without them the move saves LESS than what it
#               replaces, which is the one way to get this wrong.
#   cloud mode  <cloud>/_session-memory/<id>/ — for everything with a public or private
#               PRODUCT repo: the memory is Claude's working notes (customers, prices,
#               failures) and belongs in neither a public nor a shared history. The sync
#               client carries it without a commit; version history is the cloud's own.
#               Point SESSION_MEMORY_DIR at your sync folder (it is required unless you add
#               your own machine paths to CLOUD_ROOTS below -- this script ships without
#               any, because the folder differs per machine and per person).
#               <id>: --name, else line 1 of .session-id in the repo, else the directory name.
#
# Cases:
#   profile memory is already the link to the target      -> nothing to do (exit 0)
#   profile memory is a link elsewhere                     -> abort (1), nothing touched
#   profile memory missing                                 -> create target, link
#   profile memory is a real directory                     -> move files to the target;
#       a MEMORY.md that differs on both sides is MERGED (index, target lines first); any
#       other file with different content on both sides -> abort, nothing touched;
#       drop identical duplicates, remove the empty directory, link
# Then a cross-check: `ls` THROUGH the link must show the target.
#
# Junction instead of symlink on Windows: needs neither developer mode nor admin rights,
# and Win32 file access (so Node too) sees it as an ordinary directory. Slug rule as Claude
# Code: every character outside [A-Za-z0-9] becomes '-' (':', '\', space included).
# CLAUDE_CONFIG_DIR is honoured (tests, other profiles). -n only shows what would happen.

set -euo pipefail

usage() { echo "usage: $(basename "$0") [-n] [--relink] [--git|--cloud [--name <id>]] [<repo-dir>]
       $(basename "$0") --push [<repo-dir>]               (commit and push the memory clone)
       $(basename "$0") --retire [--name <id>] [<repo-dir>]  (set the old cloud folder aside)
       $(basename "$0") --mark-only --name <id>           (machine marker, no migration)
       $(basename "$0") --stamp [<repo-dir>]              (write the stamp, see below)" >&2; exit 64; }
dry=0 cloud=0 git_mode=0 stamp=0 relink=0 push=0 retire=0 markonly=0 name="" name_explicit=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--dry-run) dry=1; shift ;;
    --cloud) cloud=1; shift ;;
    --git) git_mode=1; shift ;;
    --relink) relink=1; shift ;;
    --stamp) stamp=1; shift ;;
    --push) push=1; shift ;;
    --retire) retire=1; shift ;;
    --mark-only) markonly=1; shift ;;
    --name) [[ -n "${2:-}" ]] || usage; name="$2"; name_explicit=1; shift 2 ;;
    -h|--help) usage ;;
    --) shift; break ;;
    -*) usage ;;
    *) break ;;
  esac
done
[[ $# -le 1 ]] || usage
# --git and --cloud are mutually exclusive: both set `target`, and which one wins would be
# order in the code rather than the caller's intent. Fail loudly instead of choosing quietly.
(( git_mode && cloud )) && { echo "[error] --git and --cloud together -- which target is meant?" >&2; exit 64; }
# --name belongs to resolving the id; repo mode has none, so there it would do nothing.
[[ -z "$name" || $cloud == 1 || $git_mode == 1 || $retire == 1 || $markonly == 1 ]] || usage
if (( markonly )) && [[ -z "$name" ]]; then
  echo "[error] --mark-only needs --name <id> -- without an id nobody knows which folder." >&2; exit 64
fi
repo="$(cd "${1:-.}" 2>/dev/null && pwd -P)" || { echo "[error] directory '${1:-.}' not found." >&2; exit 1; }

# The path as Claude Code sees it (Windows form under msys), and the slug from it.
if command -v cygpath >/dev/null 2>&1; then native="$(cygpath -w "$repo")"; iswin=1; else native="$repo"; iswin=0; fi
slug="$(printf '%s' "$native" | sed 's/[^A-Za-z0-9]/-/g')"
profile="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
mem="$profile/projects/$slug/memory"

# --- --stamp: what is here, and from when? -----------------------------------
# Your wrap-up ritual writes `<host> <UTC> <file count>` to `<memory>/.last-wrap` at the
# end; the launcher reads it before starting a session (cc_memory_state in _lib.sh).
#
# Why the FILE COUNT and not just a timestamp: a sync client transfers file by file, there
# is no atomic state. The stamp is itself just a file and can arrive BEFORE the files it
# vouches for; a pure freshness display would then say "up to date" over a half-loaded
# folder -- falsely reassuring at exactly the dangerous moment. With the count it becomes a
# completeness check.
#
# The stamp does not count itself -- otherwise the number would be one too small right
# after writing and every start would report a shortfall. Exactly one `date -u` reading.
if (( stamp )); then
  [[ -d "$mem" ]] || { echo "[stamp] no linked memory for '$slug' -- nothing to stamp."; exit 0; }
  # Counting happens THROUGH the link, and `ls` and `find` differ there:
  #   - `ls -A "$mem"` follows the link and counts correctly. Its only flaw was the exit
  #     code: if nothing remains after filtering (an empty memory, or only the stamp
  #     present), `grep` returns 1, `pipefail` passes it on and `set -e` ends the script.
  #     Hence `{ grep … || true; }` -- exit code neutralised, behaviour unchanged.
  #   - `find "$mem" -mindepth 1` does NOT follow the link (msys treats a junction like a
  #     symlink) and therefore returned **0**. That was worse than the bug before it: `0`
  #     makes the condition `actual < scount` unsatisfiable, so the shortfall warning could
  #     never fire again -- for EVERY migrated project, because a link is what they have by
  #     definition. "Loudly wrong" had become "silently wrong".
  #
  # So: two counts with tools that work DIFFERENTLY, and no stamp is written if they
  # disagree. A number nobody cross-checks is a claim.
  n=$(ls -A "$mem" 2>/dev/null | { grep -vxF '.last-wrap' || true; } | wc -l | tr -d ' ')
  n2=$(find -L "$mem" -maxdepth 1 -mindepth 1 ! -name '.last-wrap' 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$n" != "$n2" ]]; then
    echo "[ATTENTION] counts disagree (ls=$n, find=$n2) in $mem -- no stamp written." >&2
    echo "            The stamp would be a claim; please look at what is there." >&2
    exit 1
  fi
  printf '%s %s %s\n' "$(hostname)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$n" > "$mem/.last-wrap"
  echo "[stamp] $mem/.last-wrap: $(cat "$mem/.last-wrap")"
  exit 0
fi

# Your sync-folder roots, one per machine (e.g. "/d/SyncFolder" "/e/SyncFolder"). Empty on
# purpose: the path differs per machine and per person, so SESSION_MEMORY_DIR is the
# supported way and this list is only a convenience if you prefer to bake yours in.
CLOUD_ROOTS=()


# --- Id from the participant table of the bridge README ----------------------
# Overall order: --name > .session-id > THIS table > directory name, all lower-cased.
# Motivation: a directory name often differs from the session id (`app-web` vs `app`,
# capitalised sync folders, sometimes a completely unrelated name). The participant table
# is the one place where path and id stand together.
#
# TWO comparisons, both as a WHOLE path (equal or below, trailing '/'), never as a prefix
# -- otherwise `.../app` would catch the project `.../app-product`:
#   1. the full path as it stands in the table;
#   2. the same path WITHOUT a drive letter, so a second machine mirroring the layout under
#      another drive resolves too -- without a second column of paths nobody can verify.
#      Where the layout genuinely differs, `.session-id` carries it.
#
# The parse rule is the same as `readme_pathmap` in watch-bridge.sh: a path is any
# backticked field of the last column that is absolute. **Two copies of one rule** --
# change the table format and you change both; it says so here so the second is not
# forgotten. No bridge reachable or id not listed: empty, and the caller falls back to the
# directory name. SESSION_BRIDGE_DIR points at the bridge folder.
id_from_table() {
  local br="" map cwd tail hit
  [[ -n "${SESSION_BRIDGE_DIR:-}" ]] && br="${SESSION_BRIDGE_DIR%/}"
  [[ -n "$br" && -r "$br/README.md" ]] || return 0
  map="$(awk -F'|' '/^\| `[a-z0-9.-]+` \|/ {
           id=$2; gsub(/[ `]/,"",id)
           n=split($4, parts, "`")
           for (i=2; i<=n; i+=2) {
             p=parts[i]; gsub(/^ +| +$/,"",p); gsub(/\\/,"/",p)
             if (p ~ /^\// || p ~ /^[A-Za-z]:/) print id "\t" tolower(p)
           }
         }' "$br/README.md" | tr -d '\r' | tr -s '/' | sed 's|/$||')"
  [[ -n "$map" ]] || return 0
  cwd="$(norm "$repo")"
  tail="${cwd#[a-z]:}"
  hit="$(awk -F'\t' -v c="$cwd" -v t="$tail" '
           { p=$2; q=p; sub(/^[a-z]:/,"",q)
             if (c==p || index(c, p "/")==1) { print $1; exit }
             if (t==q || index(t, q "/")==1) { print $1; exit } }' <<<"$map")"
  printf '%s' "$hit"
}

norm() { # make a path comparable: one form, lower case, '/', no trailing '/'
  local p="$1"
  # If the path exists, CANONICALISE it first. Otherwise two spellings of the same place are
  # compared: Windows keeps an 8.3 short name for long directory names
  # (`C:\Users\RUNNER~1\…` next to `C:\Users\runneradmin\…`), and which one you get
  # depends on the tool -- PowerShell reports the long form for a junction target, `cygpath -m`
  # on our own string may report the short one. An existing link then counts as "points
  # elsewhere" and --relink moves it for nothing. Measured on CI; invisible on a machine where
  # both spellings coincide.
  if [[ -e "$p" ]]; then p="$(cd "$p" 2>/dev/null && pwd -P)" || p="$1"; fi
  [[ $iswin == 1 ]] && p="$(cygpath -m "$p" 2>/dev/null || printf '%s' "$p")"
  printf '%s' "$p" | tr 'A-Z' 'a-z' | tr '\\' '/' | tr -s '/' | sed 's|/$||'
}

link_kind() { # $1 = path -> "none" | "dir" | "link:<target>"
  if [[ $iswin == 1 ]]; then
    [[ -e "$1" ]] || { echo none; return; }
    local out
    out="$(powershell.exe -NoProfile -NonInteractive -Command \
      "\$i = Get-Item -LiteralPath '$(cygpath -w "$1")' -Force; if (\$i.LinkType) { 'link:' + (\$i.Target | Select-Object -First 1) } else { 'dir' }" \
      2>/dev/null | tr -d '\r')"
    echo "${out:-dir}"
  else
    if [[ -L "$1" ]]; then echo "link:$(readlink -f "$1")"; elif [[ -e "$1" ]]; then echo dir; else echo none; fi
  fi
}

make_link() { # $1 = target (a parameter, so the rollback can restore the OLD link)
  local to="$1"
  if [[ $iswin == 1 ]]; then
    # PowerShell rather than `cmd /c mklink /J "…" "…"`: with /c, cmd strips the first
    # and last quote of the line, and mklink then sees a broken path ("The filename,
    # directory name, or volume label syntax is incorrect") -- failed twice that way.
    powershell.exe -NoProfile -NonInteractive -Command \
      "New-Item -ItemType Junction -Path '$(cygpath -w "$mem")' -Target '$(cygpath -w "$to")' | Out-Null" >/dev/null 2>&1
  else
    ln -s "$to" "$mem"
  fi
}

# inside_repo — is $1 INSIDE the repo we were given? Compared with a trailing '/', never
# as a prefix: `/d/work/app` would otherwise match `/d/work/app-product`.
inside_repo() { local p; p="$(norm "$1")/"; [[ "$p" == "$(norm "$repo")/"* ]]; }

# --- git mode: roots, remote, clone ------------------------------------------
# The clone root is DERIVED, not read from a list of machines: this script lives in
# <parent>/<toolrepo>/, so the clone goes next to it in <parent>/_session-memory/. A second
# list of per-machine paths can go stale; a derivation cannot.
memrepo_root() {
  if [[ -n "${SESSION_MEMORY_REPO_DIR:-}" ]]; then printf '%s' "${SESSION_MEMORY_REPO_DIR%/}"; return 0; fi
  local here; here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
  printf '%s' "${here%/*}/_session-memory"
}

# The old cloud folder -- needed by --retire and by cloud mode.
cloud_memroot() {
  if [[ -n "${SESSION_MEMORY_DIR:-}" ]]; then printf '%s' "${SESSION_MEMORY_DIR%/}"; return 0; fi
  local p
  for p in ${CLOUD_ROOTS[@]+"${CLOUD_ROOTS[@]}"}; do
    [[ -d "$p" ]] && { printf '%s' "$p/_session-memory"; return 0; }
  done
  return 1
}

# No default host: the remote differs per person, and guessing one would be a configuration
# detail baked into a tool other people run.
MEM_SSH_HOST="${SESSION_MEMORY_SSH_HOST:-}"
MEM_SSH_PATH="${SESSION_MEMORY_SSH_PATH:-/opt/git}"
vps_url() { printf 'ssh://%s%s/memory-%s.git' "$MEM_SSH_HOST" "$MEM_SSH_PATH" "$1"; }

# ensure_bare -- create the remote repository if it is missing. Idempotent.
ensure_bare() {
  local id="$1" out
  out="$(ssh -o BatchMode=yes -o ConnectTimeout=20 "$MEM_SSH_HOST" \
    "if [ -d '$MEM_SSH_PATH/memory-$id.git' ]; then echo exists; else git init --bare -q '$MEM_SSH_PATH/memory-$id.git' && echo created; fi" 2>&1)" || {
    echo "[error] remote unreachable or repository not creatable: $out" >&2; return 1; }
  printf '%s' "$out"
}

# ensure_clone -- clone if missing, otherwise fast-forward. A FRESH remote has no branch;
# git reports that as a warning and yields a clone without a HEAD commit. That is the normal
# case for the first project and not an error -- the first commit creates the branch.
ensure_clone() {
  local id="$1" path="$2" url; url="$(vps_url "$id")"
  if [[ -d "$path/.git" ]]; then
    git -C "$path" fetch --quiet origin 2>/dev/null || true
    git -C "$path" merge --ff-only --quiet '@{u}' 2>/dev/null || true
    return 0
  fi
  [[ -e "$path" ]] && { echo "[error] $path exists but is not a git clone -- nothing touched." >&2; return 1; }
  mkdir -p "$(dirname "$path")"
  git clone --quiet "$url" "$path" 2>/dev/null || {
    echo "[error] cloning $url into $path failed." >&2; return 1; }
  return 0
}

# memory_push -- commit everything in the clone and push it. The return value separates
# "nothing to do" (0, quiet) from "push failed" (1, WITH the command to catch up): a failed
# push that is merely not reported is exactly the step that PRETENDS to save.
memory_push() {
  local path="$1" why="${2:-wrap}" br
  [[ -d "$path/.git" ]] || { echo "[push] $path is not a git clone -- nothing to push."; return 0; }
  git -C "$path" add -A
  if git -C "$path" diff --cached --quiet; then
    echo "[push] nothing changed."
  else
    git -C "$path" -c user.name="${GIT_AUTHOR_NAME:-claude}" -c user.email="${GIT_AUTHOR_EMAIL:-claude@localhost}" \
      commit --quiet -m "memory: $why ($(hostname), $(date -u +%Y-%m-%dT%H:%M:%SZ))"
    echo "[push] committed: $(git -C "$path" log -1 --format=%h\ %s)"
  fi
  br="$(git -C "$path" symbolic-ref --short HEAD 2>/dev/null || echo master)"
  if git -C "$path" push --quiet -u origin "$br" 2>/dev/null; then
    echo "[push] pushed to $(git -C "$path" remote get-url origin) ($br)."
  else
    echo "[WARNING] push failed -- the state is local only. Catch up with:" >&2
    echo "          git -C '$path' push -u origin $br" >&2
    return 1
  fi
}

# push_target -- three situations, told apart by the PROPERTY, not by the folder name:
#   own .git          -> memory clone (git mode): commit and push.
#   inside a worktree -> repo mode; the project's own commit takes the memory along. Committing
#                        here would be a second writer on the same tree.
#   neither           -> still the cloud folder. The sync client carries it.
# Telling them apart by name would be wrong: the cloud folder and the clone root are BOTH
# called `_session-memory`. Only "does the target sit inside a git worktree" separates them.
push_target() {
  local p="$1"
  if [[ -d "$p/.git" ]]; then memory_push "$p" "wrap"; return $?; fi
  if git -C "$p" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "[push] $p sits inside $(git -C "$p" rev-parse --show-toplevel 2>/dev/null) (repo mode)"
    echo "       -- that repository's commit takes the memory along; nothing to do here."
    return 0
  fi
  echo "[push] $p is not a git clone -- still the cloud folder, which carries it without a"
  echo "       commit. After --git this call takes over."
  return 0
}

# host_key / device_hosts -- for the markers used by --retire. The machine list is the set of
# per-machine config files next to the launcher: it exists already, so this is not a second
# register that can disagree with the first. SESSION_DEVICE_CONF_DIR overrides the location.
host_key() { hostname | tr 'A-Z' 'a-z' | tr -d '\r[:space:]'; }
device_hosts() {
  local base f h
  base="${SESSION_DEVICE_CONF_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)}"
  for f in "$base"/projects.*.conf; do
    [[ -e "$f" ]] || continue
    h="${f##*/projects.}"; h="${h%.conf}"
    printf '%s\n' "$h" | tr 'A-Z' 'a-z'
  done
}

if (( cloud || git_mode || retire )); then
  if [[ -z "$name" && -r "$repo/.session-id" ]]; then name="$(head -1 "$repo/.session-id" | tr -d '\r[:space:]')"; fi
  [[ -n "$name" ]] || name="$(id_from_table)"
  [[ -n "$name" ]] || name="${repo##*/}"
  # Always lower case, whatever the source: directory names are often capitalised, and if
  # one machine created `<root>/Notes` and the other later `<root>/notes`, the sync service
  # may well carry TWO folders. Locally on a case-insensitive filesystem that is invisible;
  # in the cloud, and on a case-sensitive filesystem, it is not.
  name="$(printf '%s' "$name" | tr 'A-Z' 'a-z')"
fi

if (( git_mode )); then
  target="$(memrepo_root)/$name"
  mode="git"
elif (( cloud )); then
  root="$(cloud_memroot)" || { echo "[error] no sync folder configured -- set SESSION_MEMORY_DIR (or fill CLOUD_ROOTS in this script)." >&2; exit 1; }
  target="$root/$name"
  mode="cloud"
else
  target="$repo/memory"
  mode="repo"
fi

# --- --push: save the memory clone (for the wrap-up) -------------------------
# Works on the LINKED memory rather than on a mode argument: the question is "save what this
# session sees as its memory", and that is the link's target. So the wrap-up step needs no
# --git and cannot point at the wrong folder.
if (( push )); then
  k="$(link_kind "$mem")"
  case "$k" in
    link:*) t="${k#link:}"
            # Windows form of the junction back into the msys world, or git finds nothing.
            [[ $iswin == 1 ]] && t="$(cygpath -u "$t" 2>/dev/null || printf '%s' "$t")"
            push_target "$t"; exit $? ;;
    dir)    push_target "$mem"; exit $? ;;
    *)      echo "[push] no linked memory for '$slug' -- nothing to do."; exit 0 ;;
  esac
fi

# --- --mark-only: machine marker without migrating ---------------------------
# What for: --retire wants a marker from EVERY machine. A machine that does not carry a
# project at all could never produce a migration marker -- the condition would be
# unsatisfiable there and --retire blocked forever. This is the kind of rule one builds and
# then nobody can clear. Here the machine says so explicitly: "seen, I do not carry it" --
# a statement by a person at that machine, not an inference from an absence.
if (( markonly )); then
  root="$(cloud_memroot)" || { echo "[error] no sync folder configured." >&2; exit 1; }
  [[ -d "$root/$name" ]] || { echo "[error] $root/$name does not exist -- nothing to mark." >&2; exit 1; }
  if (( dry )); then echo "[dry-run] would write $root/$name/.migrated-$(host_key) (not carried here)."; exit 0; fi
  printf '%s %s not-carried\n' "$(host_key)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$root/$name/.migrated-$(host_key)"
  echo "[marker] $root/$name/.migrated-$(host_key): $(cat "$root/$name/.migrated-$(host_key)")"
  exit 0
fi

# --- --retire: set the old cloud folder aside --------------------------------
# The third step of the move: migrate -> VERIFY -> remove the old location. Without it the
# move does not reach its goal: every file stays where it was, including for projects a
# machine never opens.
#
# Three conditions, all three checked by machine:
#   1. VERIFIED file by file by CONTENT, not by counting lines or files. A file that exists
#      only in the old folder is an ABORT THAT NAMES IT -- files present on one side only are
#      the class that carries the real contradictions.
#   2. Compared against the target THROUGH THE LINK, so the link is part of what is checked
#      and not merely two folders that happen to look alike.
#   3. A marker from EVERY machine that has a projects.<host>.conf. Otherwise one machine
#      deletes the memory out from under a session on the other.
# And at the end a `mv`, not an `rm`, into _retired/<id>/: the folder is shared state, so a
# move inside it is reversible and looks like a move on the other machine, not like a loss.
if (( retire )); then
  root="$(cloud_memroot)" || { echo "[error] no sync folder configured." >&2; exit 1; }
  old="$root/$name"
  echo "project:  $native"
  echo "old:      $old"
  echo "profile:  $mem"
  [[ -d "$old" ]] || { echo "[ok] $old is gone already -- nothing to do."; exit 0; }

  k="$(link_kind "$mem")"
  [[ "$k" == link:* ]] || { echo "[abort] no linked memory for '$slug' -- without the link there is no way to check that the new place carries." >&2; exit 1; }
  neu="${k#link:}"; [[ $iswin == 1 ]] && neu="$(cygpath -u "$neu" 2>/dev/null || printf '%s' "$neu")"
  if [[ "$(norm "$neu")" == "$(norm "$old")" ]]; then
    echo "[abort] the link still points at the OLD folder -- migrate first (--git --relink)." >&2; exit 1
  fi
  echo "new:      $neu  (through the link)"

  missing=(); differs=(); n_ok=0
  shopt -s nullglob dotglob
  for f in "$old"/*; do
    b="${f##*/}"
    [[ "$b" == ".last-wrap" || "$b" == .migrated-* ]] && continue
    [[ -d "$f" ]] && continue
    if [[ ! -e "$mem/$b" ]]; then missing+=("$b")
    elif cmp -s "$f" "$mem/$b"; then n_ok=$((n_ok+1))
    else differs+=("$b"); fi
  done
  if (( ${#missing[@]} || ${#differs[@]} )); then
    echo "[abort] the old folder is NOT fully present at the new place -- nothing touched." >&2
    (( ${#missing[@]} )) && { echo "          missing there entirely (${#missing[@]}):" >&2; printf '            %s\n' "${missing[@]}" >&2; }
    (( ${#differs[@]} )) && { echo "          present with different content (${#differs[@]}):" >&2; printf '            %s\n' "${differs[@]}" >&2; }
    echo "          This session knows both versions: read them, merge, then rerun." >&2
    exit 1
  fi
  echo "[check] $n_ok file(s) identical on both sides, none missing."

  absent=()
  while read -r h; do
    [[ -n "$h" ]] || continue
    [[ -e "$old/.migrated-$h" ]] || absent+=("$h")
  done < <(device_hosts)
  if (( ${#absent[@]} )); then
    echo "[abort] marker missing from: ${absent[*]}" >&2
    echo "          The move has not run there. On that machine either migrate" >&2
    echo "          (link-memory.sh --git --relink --name $name <project>) or, if it does not" >&2
    echo "          carry the project at all, set the marker:" >&2
    echo "            link-memory.sh --mark-only --name $name" >&2
    exit 1
  fi

  ret="$root/_retired/$name"
  if (( dry )); then echo "[dry-run] would move '$old' to '$ret'."; exit 0; fi
  [[ -e "$ret" ]] && { echo "[error] $ret already exists -- look at it by hand." >&2; exit 1; }
  mkdir -p "$root/_retired"
  mv "$old" "$ret"
  echo "[ok] $old -> $ret (content unchanged, reversible on both machines)."
  echo "     Deleting _retired/ for good stays a deliberate step by a person, after a grace period."
  exit 0
fi

echo "project:  $native"
echo "profile:  $mem"
echo "target:   $target  ($mode)"

# --- --relink: move an existing link to a different target -------------------
# Two real cases, and both abort without this flag. (1) A project moves from repo mode to
# cloud mode -- otherwise a six-step recipe by hand, including an `mv` of the folder to
# where the script looks for it. (2) A second checkout shares another session's memory by
# junction; its link points elsewhere on purpose and has to be moved to the same cloud
# folder as the other one.
#
# The files are read THROUGH the old link -- for the collection loop a junction is a
# directory, so the code below is the same as for a real folder.
#
# The OLD target folder is moved aside only if it lies INSIDE the repo we were given
# (case 1: `<repo>/memory` -- otherwise a folder stays there that looks alive and travels
# along on the next `git add`). Outside, it is left untouched and only named: in case 2
# that is ANOTHER SESSION'S memory, and we do not touch it.
kind="$(link_kind "$mem")"
moves=(); relinking=0; oldtarget=""
case "$kind" in
  link:*)
    oldtarget="${kind#link:}"
    if [[ "$(norm "$oldtarget")" == "$(norm "$target")" ]]; then
      echo "[ok] already linked -- nothing to do."; exit 0
    fi
    if (( relink )); then
      relinking=1
      # A MOVE MOVES, IT DOES NOT RENAME. If the folder is called something else at the new
      # place, resolving the id produced something other than what this session actually
      # USES -- and the result would be an empty new memory beside the full old one, with no
      # message at all. Measured across every migrated project here: identical all but once,
      # and that one case was a project deliberately SHARING another's memory by link while
      # its own .session-id said otherwise. Whoever really wants the name changed says so
      # with --name; without that, aborting is the right answer.
      if [[ -z "$name_explicit" && "${oldtarget##*[\\/]}" != "${target##*/}" ]]; then
        echo "[abort] the memory is called '${oldtarget##*[\\/]}' at the old place, '${target##*/}' at the new one." >&2
        echo "          A move should move, not rename -- as it stands the session would run on an" >&2
        echo "          EMPTY memory while the full one sits at the old place." >&2
        echo "          Intended? Then name it explicitly:" >&2
        echo "            $(basename "$0") --git --relink --name ${oldtarget##*[\\/]} $repo" >&2
        exit 1
      fi
      echo "[relink] $mem points to '$oldtarget' -- moving it to $target."
    else
      echo "[abort] $mem points to '$oldtarget', not to the target -- nothing touched. (To move it: --relink, or remove the link with 'rm $mem' and rerun.)" >&2; exit 1
    fi ;;
  none)
    # Two different situations carry the same name, and only one of them is a fresh
    # start. If the target already holds a memory, "no profile memory" is the NORMAL
    # state on a second machine -- that machine has never been here, the memory has
    # been there for a while. The old wording read like a deficiency in both cases.
    # The behaviour was always right (the run goes through, exit 0); what was missing
    # is the framing, and the framing decides whether somebody reports it as a bug.
    n_target=$( (shopt -s nullglob; set -- "$target"/*.md; echo $#) 2>/dev/null || echo 0 )
    if [[ -d "$target" ]] && (( n_target > 0 )); then
      echo "[new] no profile memory for '$slug' -- normal on a second machine:"
      echo "      $target is already there ($n_target file(s)) and is only being linked."
      echo "      Expect: the profile path then shows the same number ($n_target); nothing is copied."
    else
      echo "[new] no profile memory for '$slug' -- $target will be created and linked."
    fi ;;
esac

# In git mode the target must be a clone BEFORE the link points at it: create the remote
# (idempotent), clone or fast-forward. Only then does the normal path run, which brings the
# files in through the old link.
if (( git_mode )); then
  if (( dry )); then
    echo "[dry-run] remote $(vps_url "$name"), clone into $target -- not created."
  else
    # Create the remote only when a clone is actually needed. If the clone is already there,
    # the remote is PROVEN to exist -- it was cloned from. Saves an ssh call and makes the
    # path checkable without a network.
    if [[ ! -d "$target/.git" ]]; then
      [[ -n "$MEM_SSH_HOST" ]] || { echo "[error] --git needs SESSION_MEMORY_SSH_HOST (e.g. git@example.com or an ssh-config alias)." >&2; exit 1; }
      # Do NOT evaluate this inside the command substitution: `echo "$(ensure_bare ...)"`
      # swallows its return value, and the script would carry on after a failed creation
      # (found while writing the tests, with an unresolvable host). Same class as commands
      # that return a plausible result on failure instead of failing.
      bare_state="$(ensure_bare "$name")" || exit 1
      echo "[remote] $(vps_url "$name"): $bare_state"
    fi
    ensure_clone "$name" "$target" || exit 1
    # .last-wrap is the PER-MACHINE stamp and deliberately does not travel (see the copy
    # filter below); in git mode git has to know that too, or one machine's stamp lands in
    # the other's state and the two overwrite it in turns.
    if [[ ! -e "$target/.gitignore" ]]; then
      printf '.last-wrap\nMEMORY.md.pre-link\n' > "$target/.gitignore"
    fi
  fi
fi

if [[ $kind == dir || $relinking == 1 ]]; then
    shopt -s nullglob dotglob
    conflicts=()
    for f in "$mem"/*; do
      b="${f##*/}"
      [[ "$b" == ".last-wrap" ]] && continue     # per-machine stamp, does not travel
      if [[ -e "$target/$b" ]]; then
        cmp -s "$f" "$target/$b" && continue
        # MEMORY.md is the index -- one line per memory, order without meaning. Two
        # different indexes are the NORMAL case when a machine that already has its own
        # memory is linked for the first time (the first real run aborted on exactly
        # that). Merged: target lines first, then the lines only the profile has.
        # Everything else stays a conflict for a human.
        if [[ $b == MEMORY.md ]]; then index_merge=1; else conflicts+=("$b"); fi
      else moves+=("$b"); fi
    done
    # Merging is NOT the script's job but the session's. A line tool would have to guess
    # which version holds; the session wrote both and understands the content. So hand it
    # what it needs: both **full paths**, the size of the difference (so it is visible
    # whether this is one line or a whole file) and the procedure. Listing bare filenames --
    # which is what this printed before -- is too little to start without searching.
    # Files that exist only in the profile are copied into the target without any
    # comparison at all: there is no counterpart they could disagree with visibly.
    # That is the more dangerous half, not the harmless one -- reported from the field
    # by two sessions on the same day, who found three genuine contradictions with the
    # target there, while the single reported conflict file carried five idle words.
    # This line used to sit AFTER the abort, so it never appeared while a session was
    # planning its consolidation work -- only in the run that went through anyway.
    if (( ${#moves[@]} )); then
      echo "[move] ${#moves[@]} file(s) exist only in the profile and come into the target: ${moves[*]}"
      # With an empty target there is nothing for them to contradict -- the warning
      # would be false. Say only what holds here.
      if compgen -G "$target/*.md" >/dev/null 2>&1; then
        echo "       The script compares nothing for these; the target holds no version."
        echo "       Read them before linking: one of them may contradict what the target"
        echo "       already says (there it never shows -- both statements simply stand)."
      fi
    fi
    if (( ${#conflicts[@]} )); then
      echo "[abort] ${#conflicts[@]} file(s) exist on both sides with different content -- nothing touched." >&2
      echo "        This session knows both versions and consolidates them itself:" >&2
      # No `local`: this block sits in the script body, not in a function.
      for c in "${conflicts[@]}"; do
        dl=$(diff "$mem/$c" "$target/$c" 2>/dev/null | grep -c '^[<>]' || true)
        printf '\n        %s  (%s line(s) differ)\n' "$c" "$dl" >&2
        printf '          profile: %s\n' "$mem/$c" >&2
        printf '          target:  %s\n' "$target/$c" >&2
      done
      echo "" >&2
      echo "        Per file: read both, write the consolidation into the TARGET version," >&2
      echo "        delete the profile version. Then run this again -- it reports the next" >&2
      echo "        conflict or goes through. Nothing is overwritten while conflicts remain." >&2
      exit 1
    fi
    if (( ${index_merge:-0} )); then
      n_new=$(grep -vxFf "$target/MEMORY.md" "$mem/MEMORY.md" | grep -c . || true)
      echo "[index] MEMORY.md differs on both sides -- $n_new line(s) will be appended to the target index."
      # Appending loses nothing, but two grown indexes bring two headings into the middle of
      # the file and possibly duplicate entries. A line-wise merge cannot know that -- so say
      # it instead of leaving it: the file is READ at session start, not looked at.
      echo "        Please look over it once: two grown indexes bring two headings and"
      echo "        possible duplicate entries; order and title are handwork."
    fi
fi

if (( dry )); then echo "[dry-run] nothing changed."; exit 0; fi

# Order is safety: COPY the files, only move the profile directory ASIDE, and remove the
# rest only once the link stands and the cross-check passes. The first draft moved and
# deleted before mklink ran -- when mklink then failed on an over-long path (>260 chars
# in a test), the profile memory was gone.
mkdir -p "$target" "$(dirname "$mem")"
if [[ $kind == dir || $relinking == 1 ]]; then
  for b in "${moves[@]}"; do cp -p "$mem/$b" "$target/$b"; done
  if (( ${index_merge:-0} )); then
    cp -p "$target/MEMORY.md" "$target/MEMORY.md.pre-link"          # for the rollback
    grep -vxFf "$target/MEMORY.md" "$mem/MEMORY.md" | grep . >> "$target/MEMORY.md" || true
  fi
  # When relinking, only the link is removed -- the files live in the OLD target and stay
  # there until the cross-check below passes.
  if (( relinking )); then rm "$mem"; else mv "$mem" "$mem.pre-link"; fi
fi
if ! make_link "$target"; then
  if [[ $kind == dir || $relinking == 1 ]]; then
    if (( relinking )); then make_link "$oldtarget" || true; else mv "$mem.pre-link" "$mem"; fi
    for b in "${moves[@]}"; do rm -f "$target/$b"; done
    if (( ${index_merge:-0} )); then mv -f "$target/MEMORY.md.pre-link" "$target/MEMORY.md"; fi
    rmdir "$target" 2>/dev/null || true
  fi
  echo "[error] link not created -- profile unchanged. Path too long? (Windows: 260 chars; this one has $(printf '%s' "$(cygpath -w "$mem" 2>/dev/null || printf '%s' "$mem")" | wc -c))" >&2
  exit 1
fi

# Cross-check THROUGH the link, not just "the command ran".
if [[ "$(ls -A "$mem" 2>/dev/null | LC_ALL=C sort)" == "$(ls -A "$target" | LC_ALL=C sort)" ]]; then
  [[ $kind == dir ]] && rm -rf "$mem.pre-link"
  rm -f "$target/MEMORY.md.pre-link"
  if (( relinking )); then
    if inside_repo "$oldtarget"; then
      mv "$oldtarget" "$oldtarget.pre-link"
      echo "[old] $oldtarget lies inside the repo and became '$oldtarget.pre-link' -- check and delete it once you are satisfied."
      echo "      If it was versioned: 'git rm -r --cached memory' and put 'memory/' in .gitignore -- then verify with"
      echo "      'git check-ignore -v memory/', because an ignore rule that silently does nothing looks exactly like one that works."
    else
      echo "[old] $oldtarget left untouched (outside $repo -- possibly another session's memory)."
    fi
  fi
  n=$(ls -A "$target" | wc -l | tr -d ' ')
  if [[ $mode == git ]]; then
    echo "[ok] $mem -> $target ($n file(s))."
    # Save immediately, not at the next wrap-up. Between linking and the first push the state
    # is LOCAL ONLY -- before the move a sync client carried it without being asked. That gap
    # is the price of the move, and this is where it belongs squeezed to zero.
    memory_push "$target" "moved from the cloud folder" || true
    # Machine marker in the OLD folder: it tells --retire that this machine is done.
    if cr="$(cloud_memroot)" && [[ -d "$cr/$name" ]]; then
      printf '%s %s migrated %s\n' "$(host_key)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$n" > "$cr/$name/.migrated-$(host_key)"
      echo "[marker] $cr/$name/.migrated-$(host_key) written."
      echo "         The old folder stays until EVERY machine has migrated: link-memory.sh --retire"
    fi
  elif [[ $mode == cloud ]]; then
    echo "[ok] $mem -> $target ($n file(s)). The sync client carries it -- no commit; let it upload before switching machines."
  else
    echo "[ok] $mem -> $target ($n file(s)). Now: git add memory/ and commit."
  fi
else
  echo "[error] link created, but an ls through it shows something other than $target. The old profile memory is at $mem.pre-link." >&2; exit 1
fi
