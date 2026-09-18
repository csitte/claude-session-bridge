#!/usr/bin/env bash
#
# link-skills.sh — link the profile's global skill folder to the repository copy, instead of
# comparing the two.
#
# The problem is the one link-commands.sh solves, noticed one step later. A personal skill is
# a delivery path for knowledge every session needs without carrying it in every context: only
# its name and description are loaded, the body is read when it applies. For that to hold, the
# skill has to be in `~/.claude/skills` on every machine -- and that is exactly where it was
# not. On a freshly set up machine the folder did not exist at all, the repository held two
# skills, and the only session that saw them was the one started with that repository as an
# additional directory. For every other session on that machine the skill did not exist. It
# surfaced through a question ("does that skill work on the laptop?"), not through a check.
#
# Why a link again and not a reporter: a reporter is a procedure, a link is a state. A skill
# folder changes rarely and is read by every session; what does not change by itself may be
# checked rarely -- and then better never, because there is nothing left to reconcile. A
# `git pull` brings new skills into all sessions on the machine with no further action.
#
# The difference from link-commands.sh runs through the whole script: a command is ONE file, a
# skill is a FOLDER (`<name>/SKILL.md` plus whatever it ships). Every check therefore works per
# folder and recursively over its files -- comparing only SKILL.md would miss a reference file
# next to it, and that is work that can be lost just as easily.
#
# Usage:
#   link-skills.sh [<repo-dir>]            link (idempotent)
#   link-skills.sh -n [<repo-dir>]         show what would happen
#   link-skills.sh --status [<repo-dir>]   report state (0 = linked, 10 = not linked)
#   link-skills.sh --unlink                undo the link, copy the content back
#
# <repo-dir> is the repository holding `.claude/skills`; without it the repository this script
# lives in, or $CC_SKILLS_REPO.

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

prof="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills"

# Determine the repository ONLY where it is needed. `--unlink` does without it (it copies back
# out of the target of the existing link). With the lookup in front of it, undoing failed on a
# missing repository -- exactly when you want to undo most.
repo=""; src=""
if (( ! unlink )); then
  if [[ -n "$repo_arg" ]]; then
    repo="$(cd "$repo_arg" 2>/dev/null && pwd -P)" || { echo "[error] directory '$repo_arg' not found." >&2; exit 1; }
  elif [[ -n "${CC_SKILLS_REPO:-}" ]]; then
    repo="$(cd "$CC_SKILLS_REPO" 2>/dev/null && pwd -P)" || { echo "[error] CC_SKILLS_REPO='$CC_SKILLS_REPO' not found." >&2; exit 1; }
  else
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
    repo="$(cd "$here/.." 2>/dev/null && pwd -P)" || {
      echo "[error] cannot determine the repository — pass it or set CC_SKILLS_REPO." >&2; exit 1; }
  fi
  src="$repo/.claude/skills"
fi

norm() { # make a path comparable — canonicalise first, or on Windows you compare the 8.3
         # short name against the long form.
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
    # of the line -- that cost two attempts when link-memory.sh was built.
    powershell.exe -NoProfile -NonInteractive -Command \
      "New-Item -ItemType Junction -Path '$(cygpath -w "$1")' -Target '$(cygpath -w "$2")' | Out-Null" >/dev/null 2>&1
  else
    ln -s "$2" "$1"
  fi
}

drop_link() { # In msys a junction is a link: use `rm`, never `rmdir`.
  rm -f "$1" 2>/dev/null || rm -rf "$1" 2>/dev/null || true
}

skills_in() { # $1 = folder -> names of the skills (subfolders with SKILL.md), one per line
  local d="$1" p
  [[ -d "$d" ]] || return 0
  for p in "$d"/*/; do
    [[ -f "$p/SKILL.md" ]] || continue
    basename "$p"
  done
}

count_skills() { skills_in "$1" | wc -l | tr -d ' '; }

kind="$(link_kind "$prof")"
target=""; [[ "$kind" == link:* ]] && target="${kind#link:}"
[[ -n "$target" && $iswin == 1 ]] && target="$(cygpath -u "$target" 2>/dev/null || printf '%s' "$target")"

# ---------------------------------------------------------------- --status
if (( status_only )); then
  if [[ "$kind" == link:* ]] && [[ "$(norm "$target")" == "$(norm "$src")" ]]; then
    echo "[skills] linked: $prof -> $src ($(count_skills "$prof") skill(s))"
    exit 0
  fi
  if [[ "$kind" == link:* ]]; then
    echo "[skills] linked, but to a DIFFERENT target: $target" >&2
    echo "         expected: $src" >&2
    exit 10
  fi
  if [[ "$kind" == "none" ]]; then
    echo "[skills] NOT linked — $prof does not exist on this machine." >&2
    echo "         So NO session on this machine has the skills from the repository; only a" >&2
    echo "         session started with that repository as an additional directory sees them." >&2
  else
    echo "[skills] NOT linked — $prof is a folder of its own ($(count_skills "$prof") skill(s))." >&2
    echo "         Changes to it apply on this machine only." >&2
  fi
  echo "         Link it: $(basename "$0") ${repo:-<repo-dir>}" >&2
  exit 10
fi

# ---------------------------------------------------------------- --unlink
if (( unlink )); then
  if [[ "$kind" != link:* ]]; then
    echo "[skills] $prof is not a link — nothing to undo."; exit 0
  fi
  echo "[skills] undoing the link: $prof -> $target"
  if (( dry )); then echo "[dry-run] would copy the skills back out of $target."; exit 0; fi
  tmp="$prof.unlinked.$$"
  mkdir -p "$tmp" || { echo "[error] cannot create $tmp." >&2; exit 1; }
  # `cp -R <src>/. <dst>/` rather than `<src>/*`: it takes dotfiles along and does not run
  # into an empty glob.
  cp -R "$target"/. "$tmp"/ 2>/dev/null || true
  drop_link "$prof"
  mv "$tmp" "$prof" || { echo "[error] swapping back failed; the content is in $tmp." >&2; exit 1; }
  echo "[skills] undone. $(count_skills "$prof") skill(s) are back in the profile."
  exit 0
fi

# ---------------------------------------------------------------- link
[[ -d "$src" ]] || { echo "[error] no repository copy under $src." >&2; exit 1; }
git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
  echo "[error] $repo is not a git work tree — then the link carries nothing." >&2; exit 1; }
[[ -n "$(skills_in "$src")" ]] || {
  echo "[error] $src holds no skill (<name>/SKILL.md) — that would be an empty profile." >&2; exit 1; }

echo "profile:  $prof"
echo "target:   $src"

if [[ "$kind" == link:* ]]; then
  if [[ "$(norm "$target")" == "$(norm "$src")" ]]; then
    echo "[skills] already linked — nothing to do."; exit 0
  fi
  echo "[abort] $prof already points elsewhere: $target" >&2
  echo "        That is someone else's link; this tool does not touch it." >&2
  echo "        Undo it with: $(basename "$0") --unlink" >&2
  exit 1
fi

# The actual protection: anything in the profile that is NOT in the repository without loss
# would become invisible through the link. Checked per skill and per file inside it, and via
# the BLOB HASH rather than the mtime: a `git pull` stamps the repository file with the
# checkout time, so it always looks newer afterwards.
blocker=0
if [[ "$kind" == "dir" ]]; then
  # EVERYTHING in the profile is checked, not only what counts as a skill. A folder without a
  # SKILL.md is not a skill, but the link would hide it just the same, and a loose file next to
  # it even more so. Writing the tests is what showed this: the first version looped over
  # `skills_in`, and anything outside that definition vanished without a warning.
  reported=""
  while IFS= read -r rel; do
    [[ -n "$rel" ]] || continue
    pf="$prof/$rel"; rf="$src/$rel"
    top="${rel%%/*}"
    # If the whole top-level folder is missing over there, say it once instead of per file.
    if [[ "$top" != "$rel" && ! -e "$src/$top" ]]; then
      case " $reported " in
        *" $top "*) continue ;;
        *) reported="$reported $top"
           echo "[abort] '$top' exists only in the profile — the link would hide it." >&2
           echo "        Save it first: cp -R \"$prof/$top\" \"$src/\" && git -C \"$repo\" add + commit" >&2
           blocker=$((blocker + 1)); continue ;;
      esac
    fi
    if [[ ! -f "$rf" ]]; then
      echo "[abort] $rel exists only in the profile — the link would hide the file." >&2
      echo "        Save it first: cp \"$pf\" \"$rf\"" >&2
      blocker=$((blocker + 1)); continue
    fi
    cmp -s "$pf" "$rf" && continue
    h="$(git -C "$repo" hash-object -- "$pf" 2>/dev/null || true)"
    found=0
    if [[ -n "$h" ]]; then
      for rev in $(git -C "$repo" rev-list --max-count=50 HEAD -- ".claude/skills/$rel" 2>/dev/null || true); do
        b="$(git -C "$repo" rev-parse "$rev:.claude/skills/$rel" 2>/dev/null || true)"
        [[ "$b" == "$h" ]] && { found=1; break; }
      done
    fi
    if (( found )); then
      echo "[ok]    $rel: an older committed version — the link brings it up to date."
    else
      echo "[abort] $rel: the profile version is in NO commit — it carries changes that are" >&2
      echo "        saved nowhere. Take them over first, do not overwrite:" >&2
      echo "        diff \"$rf\" \"$pf\"" >&2
      blocker=$((blocker + 1))
    fi
  done < <(cd "$prof" 2>/dev/null && { find . -type f -printf '%P
' 2>/dev/null || find . -type f | sed 's|^\./||'; })
fi
(( blocker )) && { echo "[abort] $blocker item(s) in the way — nothing touched." >&2; exit 1; }

if (( dry )); then
  if [[ "$kind" == "none" ]]; then
    echo "[dry-run] would create $prof as a link to $src ($(count_skills "$src") skill(s))."
  else
    echo "[dry-run] would move $prof aside and recreate it as a link to $src."
  fi
  exit 0
fi

# Move aside rather than delete — and clean up only after the cross-check succeeds.
save=""
if [[ "$kind" == "dir" ]]; then
  save="$prof.before-link.$(date -u +%Y%m%dT%H%M%SZ)"
  mv "$prof" "$save" || { echo "[error] cannot move $prof aside." >&2; exit 1; }
fi
mkdir -p "$(dirname "$prof")"
make_link "$prof" "$src"

# Cross-check THROUGH the link: not "the junction exists" but "the files are readable through
# it and identical".
ok=1
k2="$(link_kind "$prof")"
[[ "$k2" == link:* ]] || ok=0
while IFS= read -r name; do
  [[ -n "$name" ]] || continue
  cmp -s "$prof/$name/SKILL.md" "$src/$name/SKILL.md" || { ok=0; break; }
done < <(skills_in "$src")

if (( ! ok )); then
  echo "[error] the cross-check through the link failed — rolling back." >&2
  drop_link "$prof"
  [[ -n "$save" ]] && mv "$save" "$prof"
  exit 1
fi

[[ -n "$save" ]] && rm -rf "$save"
echo "[skills] linked: $prof -> $src"
echo "         $(count_skills "$prof") skill(s) now apply on this machine in EVERY session."
echo "         Changes to them show up in 'git status' of $repo."
echo "         A new skill takes effect at the next session start, not in running ones."
