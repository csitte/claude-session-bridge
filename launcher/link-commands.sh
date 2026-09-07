#!/usr/bin/env bash
#
# link-commands.sh — link the profile's global slash-command folder to the repository copy,
# instead of comparing the two.
#
# The problem: `~/.claude/commands/*.md` are ritual texts that EVERY session executes, and
# they live in the machine profile, which does not travel. A change applies only on the
# machine where it was typed. No diff points at it, and no push can fail.
#
# Why a REPORTER is not enough — this is the expensive part. `cc_check_commands` compares
# both sides and does it correctly; in the field it reported `wrap.md: OUTDATED` with a
# ready-made `cp`, and the profile on the second machine was still eight days old. Reporting
# does not replace pulling across. On top of that comes the timing: you work on a ritual file
# while you are busy with something else — i.e. in a single session you started by hand. The
# fleet start, where the reporter runs, is exactly the moment when nobody is editing one.
# The check sat where the changes do not happen.
#
# So this is not a better reporter but a state instead of a procedure. Once linked there is
# ONE file. An update cannot be forgotten because there is nothing to reconcile; a change in
# the profile IS a change in the working tree, so it shows up in `git status` and travels with
# the next commit. A `git pull` puts new commands in front of every session on the machine
# without anyone doing anything.
#
# The difference in one sentence: a reporter needs configuration in the profile (which does
# not travel either — the same trap a SessionStart hook would fall into, since settings.json
# is itself a profile file) AND has to run at the right moment. A link is set once per machine
# and carries by itself. What does not change on its own may be checked rarely.
#
# The mechanics are inherited from link-memory.sh, which has done the same for the memory
# folder since before this: a junction via PowerShell (never `cmd /c mklink`), canonicalise
# before comparing paths, and verify THROUGH the link afterwards.
#
# Usage:
#   link-commands.sh [<repo-dir>]            link (idempotent)
#   link-commands.sh -n [<repo-dir>]         show what would happen
#   link-commands.sh --status [<repo-dir>]   report state (0 = linked, 10 = not linked)
#   link-commands.sh --unlink                undo: copy the content back into the profile
#
# <repo-dir> is the repository holding `.claude/commands`; without it the repository this
# script lives in, or $CC_COMMANDS_REPO.

set -u

iswin=0
case "$(uname -s 2>/dev/null || echo)" in MINGW*|MSYS*|CYGWIN*) iswin=1 ;; esac

usage() { echo "usage: $(basename "$0") [-n] [--status] [--unlink] [<repo-dir>]" >&2; exit 64; }

dry=0 status_only=0 unlink=0 repo_arg=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n) dry=1; shift ;;
    --status) status_only=1; shift ;;
    --unlink) unlink=1; shift ;;
    -h|--help) usage ;;
    -*) echo "[error] unknown option: $1" >&2; usage ;;
    *) [[ -n "$repo_arg" ]] && usage; repo_arg="$1"; shift ;;
  esac
done

prof="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/commands"

# Determine the repository. Order: argument, environment, the repository this script is in.
# ONLY where it is needed: `--unlink` does without (it copies back from the target of the
# existing link). With the lookup in front of it, undoing failed on a missing repository —
# exactly when you want to undo most. Found by a mutation probe that was looking for
# something else entirely.
repo=""; src=""
if (( ! unlink )); then
  if [[ -n "$repo_arg" ]]; then
    repo="$(cd "$repo_arg" 2>/dev/null && pwd -P)" || { echo "[error] directory '$repo_arg' not found." >&2; exit 1; }
  elif [[ -n "${CC_COMMANDS_REPO:-}" ]]; then
    repo="$(cd "$CC_COMMANDS_REPO" 2>/dev/null && pwd -P)" || { echo "[error] CC_COMMANDS_REPO='$CC_COMMANDS_REPO' not found." >&2; exit 1; }
  else
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
    repo="$(cd "$here/.." 2>/dev/null && pwd -P)" || {
      echo "[error] cannot determine the repository — pass it or set CC_COMMANDS_REPO." >&2; exit 1; }
  fi
  src="$repo/.claude/commands"
fi

norm() { # make a path comparable — see link-memory.sh: canonicalise first, or on Windows you
         # compare the 8.3 short name against the long form of the same place.
  local p="$1"
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

make_link() { # $1 = path of the link, $2 = target
  if [[ $iswin == 1 ]]; then
    # PowerShell rather than `cmd /c mklink /J`: with /c, cmd strips the first and last quote
    # of the line and mklink then sees a broken path.
    powershell.exe -NoProfile -NonInteractive -Command \
      "New-Item -ItemType Junction -Path '$(cygpath -w "$1")' -Target '$(cygpath -w "$2")' | Out-Null" >/dev/null 2>&1
  else
    ln -s "$2" "$1"
  fi
}

drop_link() { # remove the link. Under msys a junction is a link: `rm`, never `rmdir`.
  rm -f "$1" 2>/dev/null || rm -rf "$1" 2>/dev/null || true
}

kind="$(link_kind "$prof")"
target=""; [[ "$kind" == link:* ]] && target="${kind#link:}"
[[ -n "$target" && $iswin == 1 ]] && target="$(cygpath -u "$target" 2>/dev/null || printf '%s' "$target")"

# ---------------------------------------------------------------- --status
if (( status_only )); then
  if [[ "$kind" == link:* ]] && [[ "$(norm "$target")" == "$(norm "$src")" ]]; then
    echo "[commands] linked: $prof -> $src"
    exit 0
  fi
  if [[ "$kind" == link:* ]]; then
    echo "[commands] linked, but to a DIFFERENT target: $target" >&2
    echo "           expected: $src" >&2
    exit 10
  fi
  n=$(ls -1 "$prof"/*.md 2>/dev/null | wc -l | tr -d ' ')
  echo "[commands] NOT linked — $prof is a folder of its own ($n file(s))." >&2
  echo "           Changes to it apply on this machine only." >&2
  echo "           Link it: $(basename "$0") $repo" >&2
  exit 10
fi

# ---------------------------------------------------------------- --unlink
if (( unlink )); then
  if [[ "$kind" != link:* ]]; then
    echo "[commands] $prof is not a link — nothing to undo."; exit 0
  fi
  echo "[commands] unlinking: $prof -> $target"
  if (( dry )); then echo "[dry-run] would copy the files back from $target."; exit 0; fi
  tmp="$prof.unlinked.$$"
  mkdir -p "$tmp" || { echo "[error] cannot create $tmp." >&2; exit 1; }
  cp "$target"/*.md "$tmp"/ 2>/dev/null || true
  drop_link "$prof"
  mv "$tmp" "$prof" || { echo "[error] swap back failed; the content is in $tmp." >&2; exit 1; }
  echo "[commands] unlinked. $(ls -1 "$prof"/*.md 2>/dev/null | wc -l | tr -d ' ') file(s) are back in the profile."
  exit 0
fi

# ---------------------------------------------------------------- link
[[ -d "$src" ]] || { echo "[error] no repository copy at $src." >&2; exit 1; }
git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
  echo "[error] $repo is not a git working tree — then the link carries nothing." >&2; exit 1; }
ls "$src"/*.md >/dev/null 2>&1 || {
  echo "[error] $src holds no *.md — that would be an empty profile." >&2; exit 1; }

echo "profile:  $prof"
echo "target:   $src"

if [[ "$kind" == link:* ]]; then
  if [[ "$(norm "$target")" == "$(norm "$src")" ]]; then
    echo "[commands] already linked — nothing to do."; exit 0
  fi
  echo "[abort] $prof already points elsewhere: $target" >&2
  echo "        That is somebody else's link; this tool does not touch it." >&2
  echo "        Undo it with: $(basename "$0") --unlink" >&2
  exit 1
fi

# The actual safeguard: anything in the profile that is NOT in the repository without loss
# would become invisible behind the link. Before touching anything, check file by file.
# Same distinction as cc_check_commands, and for the same reason by BLOB HASH rather than
# mtime: a `git pull` stamps the repository file with the checkout time, so it always looks
# newer afterwards — in the case that prompted all this, mtime pointed the wrong way.
blocker=0
if [[ "$kind" == "dir" ]]; then
  for f in "$prof"/*.md; do
    [[ -f "$f" ]] || continue
    name="$(basename "$f")"
    if [[ ! -f "$src/$name" ]]; then
      echo "[abort] $name exists only in the profile — the link would make it invisible." >&2
      echo "        Save it first: cp \"$f\" \"$src/$name\" && git -C \"$repo\" add + commit" >&2
      blocker=$((blocker + 1)); continue
    fi
    cmp -s "$f" "$src/$name" && continue
    h="$(git -C "$repo" hash-object -- "$f" 2>/dev/null || true)"
    found=0
    if [[ -n "$h" ]]; then
      for rev in $(git -C "$repo" rev-list --max-count=50 HEAD -- ".claude/commands/$name" 2>/dev/null || true); do
        b="$(git -C "$repo" rev-parse "$rev:.claude/commands/$name" 2>/dev/null || true)"
        [[ "$b" == "$h" ]] && { found=1; break; }
      done
    fi
    if (( found )); then
      echo "[ok]    $name: an older committed version — the link supersedes it."
    else
      echo "[abort] $name: the profile version is in NO commit — it carries changes that are" >&2
      echo "        saved nowhere. Take them over first, do not overwrite:" >&2
      echo "        diff \"$src/$name\" \"$f\"" >&2
      blocker=$((blocker + 1))
    fi
  done
fi
(( blocker )) && { echo "[abort] $blocker file(s) in the way — nothing touched." >&2; exit 1; }

if (( dry )); then
  echo "[dry-run] would move $prof aside and recreate it as a link to $src."
  exit 0
fi

# Move aside rather than delete — and clean up only after the verification succeeds.
save=""
if [[ "$kind" == "dir" ]]; then
  save="$prof.before-link.$(date -u +%Y%m%dT%H%M%SZ)"
  mv "$prof" "$save" || { echo "[error] cannot move $prof aside." >&2; exit 1; }
fi
mkdir -p "$(dirname "$prof")"
make_link "$prof" "$src"

# Verify THROUGH the link: not "the junction exists" but "the files are readable through it
# and identical". If that fails, roll back.
ok=1
k2="$(link_kind "$prof")"
[[ "$k2" == link:* ]] || ok=0
for f in "$src"/*.md; do
  name="$(basename "$f")"
  cmp -s "$prof/$name" "$f" || { ok=0; break; }
done

if (( ! ok )); then
  echo "[error] verification through the link failed — rolling back." >&2
  drop_link "$prof"
  [[ -n "$save" ]] && mv "$save" "$prof"
  exit 1
fi

[[ -n "$save" ]] && rm -rf "$save"
echo "[commands] linked: $prof -> $src"
echo "           $(ls -1 "$prof"/*.md 2>/dev/null | wc -l | tr -d ' ') command(s) now come from the repository on this machine."
echo "           Changes to them show up in 'git status' of $repo."
