#!/usr/bin/env bash
#
# instructions-sync.sh <key> [<project-dir>]
#
# Write path for project instructions that are kept OUTSIDE the project's git repository:
# takes the CLAUDE.md from the working tree, commits it in the clone of your instructions
# repository and pushes. Counterpart of `cc_instructions_before_start` (the read direction)
# in _lib.sh.
#
# WHY: the launcher takes the instructions from a git clone, not from a sync folder. The
# reason was never the storage location but the BASELINE -- a clone knows what it last
# delivered, and only that makes "merely outdated" distinguishable from "changed on both
# machines". That property holds only as long as somebody also WRITES: if the clone stands
# still while the file in the working tree is maintained, the launcher copies an old
# version in at the next start and reports the new one as a local change. Hence this
# command; run it from your wrap-up ritual.
#
# Without a directory: the current directory.
#   bash instructions-sync.sh app
#   bash instructions-sync.sh app /d/work/app
#
# Switches:
#   -n  dry run: shows what would happen, changes nothing.
#
# Returns 0 = mirrored or nothing to do; 1 = error (named, never silent).

set -uo pipefail

dry=0
[[ "${1:-}" == "-n" ]] && { dry=1; shift; }

key="${1:-}"
proj="${2:-$PWD}"

if [[ -z "$key" ]]; then
  echo "usage: instructions-sync.sh [-n] <key> [<project-dir>]" >&2
  echo "       <key> = value of instructions=... in projects.<host>.conf" >&2
  exit 1
fi

# Find the clone -- the same derivation as cc_instructions_root in _lib.sh: a sibling of
# this repository named `_instructions`. CC_INSTRUCTIONS_DIR wins (tests, special cases).
if [[ -n "${CC_INSTRUCTIONS_DIR:-}" ]]; then
  root="${CC_INSTRUCTIONS_DIR%/}"
else
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  root="${here%/*}/_instructions"
fi
if [[ ! -d "$root/.git" ]]; then
  echo "[error] no clone of the instructions repository found." >&2
  echo "        Expected under: $root  (or set CC_INSTRUCTIONS_DIR)" >&2
  echo "        Create it with: git clone <your-instructions-remote> '$root'" >&2
  exit 1
fi

src="$proj/CLAUDE.md"
[[ -r "$src" ]] || { echo "[error] no readable CLAUDE.md in '$proj'." >&2; exit 1; }

# An unresolved clone is not written to -- otherwise we would commit conflict markers,
# and exactly those are what the next session reads as content.
if [[ -n "$(git -C "$root" ls-files -u 2>/dev/null)" ]]; then
  echo "[error] the clone is in a MERGE CONFLICT -- nothing written." >&2
  echo "        Resolve first: cd '$root' && git status" >&2
  exit 1
fi

dst="$root/$key/CLAUDE.md"

if [[ -e "$dst" ]] && cmp -s "$src" "$dst"; then
  echo "[sync] $key: unchanged -- nothing to do."
  exit 0
fi

if (( dry )); then
  echo "[dry-run] would mirror: $src"
  echo "                   to: $dst"
  [[ -e "$dst" ]] && echo "          (existing version would be replaced)" || echo "          (new file)"
  exit 0
fi

# Pull first, so the commit sits on the current state and the push does not fail on a
# divergence that a fast-forward would have resolved.
if ! git -C "$root" pull --ff-only --quiet 2>/dev/null; then
  echo "[sync] $key: the clone could not be pulled (offline, or it has diverged)." >&2
  echo "       Committing anyway; the push may fail and is then reported." >&2
fi

mkdir -p "$root/$key" || { echo "[error] cannot create '$root/$key'." >&2; exit 1; }
cp -- "$src" "$dst"   || { echo "[error] copy failed: $src -> $dst" >&2; exit 1; }

git -C "$root" add -- "$key/CLAUDE.md" || { echo "[error] git add failed." >&2; exit 1; }
if git -C "$root" diff --cached --quiet -- "$key/CLAUDE.md"; then
  echo "[sync] $key: content unchanged -- no commit."
  exit 0
fi

git -C "$root" commit -q -m "$key: CLAUDE.md mirrored from the working tree" \
  || { echo "[error] commit failed." >&2; exit 1; }

if git -C "$root" push --quiet 2>/dev/null; then
  echo "[sync] $key: mirrored and pushed ($(git -C "$root" rev-parse --short HEAD))."
  exit 0
fi

# Name it, do not just fail: the state is committed in the clone, but it does not travel.
echo "[sync] $key: CLAUDE.md is committed but NOT pushed -- the state stays local at" >&2
echo "       $(git -C "$root" rev-parse --short HEAD). The other machine does not see it." >&2
echo "       Catch up with: git -C '$root' push" >&2
exit 1
