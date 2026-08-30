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

usage() { echo "usage: $(basename "$0") [-n] [--cloud [--name <id>]] [<repo-dir>]" >&2; exit 64; }
dry=0 cloud=0 name=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--dry-run) dry=1; shift ;;
    --cloud) cloud=1; shift ;;
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

# Your sync-folder roots, one per machine (e.g. "/d/SyncFolder" "/e/SyncFolder"). Empty on
# purpose: the path differs per machine and per person, so SESSION_MEMORY_DIR is the
# supported way and this list is only a convenience if you prefer to bake yours in.
CLOUD_ROOTS=()

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
  [[ -n "$name" ]] || name="${repo##*/}"
  target="$root/$name"
  mode="cloud"
else
  target="$repo/memory"
  mode="repo"
fi

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

make_link() {
  if [[ $iswin == 1 ]]; then
    # PowerShell rather than `cmd /c mklink /J "…" "…"`: with /c, cmd strips the first
    # and last quote of the line, and mklink then sees a broken path ("The filename,
    # directory name, or volume label syntax is incorrect") -- failed twice that way.
    powershell.exe -NoProfile -NonInteractive -Command \
      "New-Item -ItemType Junction -Path '$(cygpath -w "$mem")' -Target '$(cygpath -w "$target")' | Out-Null" >/dev/null 2>&1
  else
    ln -s "$target" "$mem"
  fi
}

echo "project:  $native"
echo "profile:  $mem"
echo "target:   $target  ($mode)"

kind="$(link_kind "$mem")"
moves=()
case "$kind" in
  link:*)
    if [[ "$(norm "${kind#link:}")" == "$(norm "$target")" ]]; then
      echo "[ok] already linked -- nothing to do."; exit 0
    fi
    echo "[abort] $mem points to '${kind#link:}', not to the target -- nothing touched. (To change the target: remove the link with 'rm $mem', then rerun.)" >&2; exit 1 ;;
  none)
    echo "[new] no profile memory for '$slug' -- $target will be created and linked." ;;
  dir)
    shopt -s nullglob dotglob
    conflicts=()
    for f in "$mem"/*; do
      b="${f##*/}"
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
    echo "[move] ${#moves[@]} file(s) from the profile into the target${moves[*]:+: ${moves[*]}}"
    if (( ${index_merge:-0} )); then
      n_new=$(grep -vxFf "$target/MEMORY.md" "$mem/MEMORY.md" | grep -c . || true)
      echo "[index] MEMORY.md differs on both sides -- $n_new line(s) from the profile will be appended to the target index."
    fi ;;
esac

if (( dry )); then echo "[dry-run] nothing changed."; exit 0; fi

# Order is safety: COPY the files, only move the profile directory ASIDE, and remove the
# rest only once the link stands and the cross-check passes. The first draft moved and
# deleted before mklink ran -- when mklink then failed on an over-long path (>260 chars
# in a test), the profile memory was gone.
mkdir -p "$target" "$(dirname "$mem")"
if [[ $kind == dir ]]; then
  for b in "${moves[@]}"; do cp -p "$mem/$b" "$target/$b"; done
  if (( ${index_merge:-0} )); then
    cp -p "$target/MEMORY.md" "$target/MEMORY.md.pre-link"          # for the rollback
    grep -vxFf "$target/MEMORY.md" "$mem/MEMORY.md" | grep . >> "$target/MEMORY.md" || true
  fi
  mv "$mem" "$mem.pre-link"
fi
if ! make_link; then
  if [[ $kind == dir ]]; then
    mv "$mem.pre-link" "$mem"
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
  n=$(ls -A "$target" | wc -l | tr -d ' ')
  if [[ $mode == cloud ]]; then
    echo "[ok] $mem -> $target ($n file(s)). The sync client carries it -- no commit; let it upload before switching machines."
  else
    echo "[ok] $mem -> $target ($n file(s)). Now: git add memory/ and commit."
  fi
else
  echo "[error] link created, but an ls through it shows something other than $target. The old profile memory is at $mem.pre-link." >&2; exit 1
fi
