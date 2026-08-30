#!/usr/bin/env bash
#
# link-memory.sh — puts a project's Claude Code memory in a place that travels between
# machines and links the profile path to it (junction on Windows, symlink elsewhere).
#
# Usage:  link-memory.sh [-n] [<repo-dir>]                       target <repo>/memory   (repo mode)
#         link-memory.sh [-n] --cloud [--name <id>] [<repo-dir>]  target <cloud>/_session-memory/<id>
#         (default <repo-dir>: current directory)
#
# Why: Claude Code keeps the memory under ~/.claude/projects/<slug>/memory/, and the slug
# is the PATH of the working directory — D--work-app on one machine, C--work-app on the
# other. So the memory does not travel: a wrap-up on one machine saves into a folder the
# other machine never sees. The profile path becomes a link to a place that travels; run
# once per machine (the slug differs per machine, the target is the same).
#
# Two targets:
#   repo mode   <repo>/memory/ — only for infrastructure repos that exist for this purpose
#               alone: rides the push the wrap-up makes anyway, every memory write shows up
#               as a diff in `git status`.
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

usage() { echo "usage: $(basename "$0") [-n] [--relink] [--cloud [--name <id>]] [<repo-dir>]
       $(basename "$0") --stamp [<repo-dir>]   (write the stamp, see below)" >&2; exit 64; }
dry=0 cloud=0 stamp=0 relink=0 name=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--dry-run) dry=1; shift ;;
    --cloud) cloud=1; shift ;;
    --relink) relink=1; shift ;;
    --stamp) stamp=1; shift ;;
    --name) [[ -n "${2:-}" ]] || usage; name="$2"; shift 2 ;;
    -h|--help) usage ;;
    --) shift; break ;;
    -*) usage ;;
    *) break ;;
  esac
done
[[ $# -le 1 ]] || usage
[[ -z "$name" || $cloud == 1 ]] || usage
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
  n=$(ls -A "$mem" 2>/dev/null | grep -vxF '.last-wrap' | wc -l | tr -d ' ')
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

if (( cloud )); then
  if [[ -n "${SESSION_MEMORY_DIR:-}" ]]; then
    root="${SESSION_MEMORY_DIR%/}"
  else
    root=""
    for p in ${CLOUD_ROOTS[@]+"${CLOUD_ROOTS[@]}"}; do
      if [[ -d "$p" ]]; then root="$p/_session-memory"; break; fi
    done
    [[ -n "$root" ]] || { echo "[error] no sync folder configured -- set SESSION_MEMORY_DIR (or fill CLOUD_ROOTS in this script)." >&2; exit 1; }
  fi
  if [[ -z "$name" && -r "$repo/.session-id" ]]; then name="$(head -1 "$repo/.session-id" | tr -d '\r[:space:]')"; fi
  [[ -n "$name" ]] || name="$(id_from_table)"
  [[ -n "$name" ]] || name="${repo##*/}"
  # Always lower case, whatever the source: directory names are often capitalised, and if
  # one machine created `<root>/Notes` and the other later `<root>/notes`, the sync service
  # may well carry TWO folders. Locally on a case-insensitive filesystem that is invisible;
  # in the cloud, and on a case-sensitive filesystem, it is not.
  name="$(printf '%s' "$name" | tr 'A-Z' 'a-z')"
  target="$root/$name"
  mode="cloud"
else
  target="$repo/memory"
  mode="repo"
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
      echo "[relink] $mem points to '$oldtarget' -- moving it to $target."
    else
      echo "[abort] $mem points to '$oldtarget', not to the target -- nothing touched. (To move it: --relink, or remove the link with 'rm $mem' and rerun.)" >&2; exit 1
    fi ;;
  none)
    echo "[new] no profile memory for '$slug' -- $target will be created and linked." ;;
esac

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
    if (( ${#conflicts[@]} )); then
      echo "[abort] same file with different content in profile and target -- merge by hand, nothing touched:" >&2
      printf '        %s\n' "${conflicts[@]}" >&2; exit 1
    fi
    echo "[move] ${#moves[@]} file(s) into the target${moves[*]:+: ${moves[*]}}"
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
  if [[ $mode == cloud ]]; then
    echo "[ok] $mem -> $target ($n file(s)). The sync client carries it -- no commit; let it upload before switching machines."
  else
    echo "[ok] $mem -> $target ($n file(s)). Now: git add memory/ and commit."
  fi
else
  echo "[error] link created, but an ls through it shows something other than $target. The old profile memory is at $mem.pre-link." >&2; exit 1
fi
