#!/usr/bin/env bash
#
# install-watcher.sh [-n|--dry-run] [-u|--update] [-f|--force] <session-id> [project-dir] —
# wire the bridge push into a project session. Operational docs: docs/watcher.md.
#
# Does two things, both idempotent:
#   1. Write the arming paragraph into the project's CLAUDE.md — preferably at the end
#      of an existing bridge section, otherwise at the end of the file.
#   2. Add allow-rules for the arming command to .claude/settings.local.json so the
#      permission classifier does not block the monitor at every session start
#      (6 of 8 sessions were affected during our rollout). One rule per machine path.
#
# If the paragraph is already there but outdated, the script says so and changes
# nothing; -u/--update then replaces it with the current wording.
#
# Writes NOTHING into the bridge. The paragraph names BOTH machine paths, because
# CLAUDE.md files travel between machines (via git or file sync).

set -u

dry=0
force=0
update=0
while true; do
  case "${1:-}" in
    -n|--dry-run) dry=1; shift ;;
    -f|--force)   force=1; shift ;;
    -u|--update)  update=1; shift ;;
    -h|--help)
      sed -n '3,18p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) break ;;
  esac
done

me="${1:?usage: install-watcher.sh [-n] [-u] [-f] <session-id> [project-dir]}"
proj="${2:-$PWD}"

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if command -v cygpath >/dev/null 2>&1; then
  repo_win="$(cygpath -m "$repo")"
else
  case "$repo" in
    /?/*) repo_win="$(printf '%s' "${repo:1:1}" | tr 'a-z' 'A-Z'):${repo:2}" ;;
    *)    repo_win="$repo" ;;
  esac
fi
script="$repo_win/watch-bridge.sh"

# Machine paths: a CLAUDE.md travels between machines (via git or file sync), so a
# single absolute path in it is always wrong for one of them. That is why the
# paragraph names both, and why there is one allow-rule per path.
# ---- SITE BLOCK: absolute paths to watch-bridge.sh, one per machine ----
script_pc="C:/tools/claude-session-bridge/watch-bridge.sh"
script_nb="D:/tools/claude-session-bridge/watch-bridge.sh"

[[ -f "$repo/watch-bridge.sh" ]] || { echo "install-watcher: watch-bridge.sh missing in $repo" >&2; exit 1; }

# Check the session id against the participant table in the bridge README. Abort on an
# unknown id — a typo would otherwise insert a second paragraph that the idempotence
# check (which looks for the concrete id) can no longer catch.
for p in ${SESSION_BRIDGE_DIR:+"${SESSION_BRIDGE_DIR%/}"} \
         "$HOME/session-bridge" "/c/session-bridge"; do
  if [[ -f "$p/README.md" ]]; then
    if ! grep -q "^| \`$me\`" "$p/README.md" && [[ $force -eq 0 ]]; then
      echo "install-watcher: '$me' is not in the participant table of the bridge README." >&2
      echo "  Typo? Otherwise force it with -f/--force (the table can be out of date," >&2
      echo "  e.g. a new session is missing there) — and add the row to the README." >&2
      exit 1
    fi
    break
  fi
done

md="$proj/CLAUDE.md"
[[ -f "$md" ]] || { echo "install-watcher: $md not found — check the project directory." >&2; exit 1; }

block="**Bridge push (watcher):** At session start (after the bridge start scan) arm the
Monitor tool — persistent: true, description \"session bridge: new messages for
$me\", command with the path that exists on this machine:
\`bash $script_pc $me\` (machine A) or
\`bash $script_nb $me\` (machine B).
Every notification = a new bridge message for this session → read the file, report it in
the chat, react according to the bridge protocol. The watcher only reads and complements
the start scan; write-once is unaffected. **Do not disarm the watcher:** it survives
\`/clear\` and keeps delivering; a second arm recognises the running one and steps aside.
Use TaskStop only if delivery must stop *immediately*. Check the state with
\`bash $script_pc --status $me\`. Operational docs: docs/watcher.md next to the script."

# ---------- 1. CLAUDE.md ----------
# Adopt the line endings of the target file. -U is mandatory: without binary mode
# MSYS grep swallows the CR and every file looks like LF.
out="$block"; nl=""
if grep -qU $'\r' "$md"; then
  out="$(printf '%s' "$block" | sed 's/$/\r/')"
  nl=$'\r'   # the blank and trailing lines need the CR too
fi

# Delimit an existing paragraph: first line carrying the marker, up to the first line
# from there on that mentions "watcher.md" (= last line of the template). This leaves
# additions a session wrote BELOW the paragraph untouched.
b_start="$(grep -n -m1 -F '**Bridge push (watcher):**' "$md" | cut -d: -f1)"
b_end=""
if [[ -n "$b_start" ]]; then
  b_end="$(awk -v s="$b_start" 'NR>=s && /[Ww]atcher\.md/ {print NR; exit}' "$md")"
  if [[ -z "$b_end" ]]; then
    b_end="$(awk -v s="$b_start" 'NR>=s && /^[[:space:]]*\r?$/ {print NR-1; exit}' "$md")"
    [[ -z "$b_end" ]] && b_end="$(wc -l < "$md")"
    echo "install-watcher: WARNING — paragraph without a watcher.md closing line; guessed the end at line $b_end." >&2
  fi
fi

if [[ -n "$b_start" ]]; then
  ist="$(sed -n "${b_start},${b_end}p" "$md" | tr -d '\r')"
  soll="$(printf '%s' "$block")"
  if [[ "$ist" == "$soll" ]]; then
    echo "CLAUDE.md   : arming paragraph is current — unchanged."
  elif [[ $update -eq 0 ]]; then
    echo "CLAUDE.md   : arming paragraph present, but differs from the current wording"
    echo "              (lines $b_start-$b_end). Replace it with -u/--update."
  elif [[ $dry -eq 1 ]]; then
    echo "CLAUDE.md   : [dry-run] would replace lines $b_start-$b_end. New wording:"
    printf '%s\n' "$block" | sed 's/^/              | /'
  else
    tmp="$(mktemp)"
    head -n $((b_start-1)) "$md" > "$tmp"
    printf '%s\n' "$out" >> "$tmp"
    tail -n +$((b_end+1)) "$md" >> "$tmp"
    mv "$tmp" "$md"
    echo "CLAUDE.md   : arming paragraph updated (lines $b_start-$b_end replaced)."
  fi
else
  # Target position: end of an existing bridge section, otherwise end of file.
  hdr="$(grep -n -m1 -iE '^#{1,6}[[:space:]].*bridge' "$md" | cut -d: -f1)"
  ins=0; wo="at the end of the file"
  if [[ -n "$hdr" ]]; then
    hashes="$(sed -n "${hdr}p" "$md" | grep -oE '^#+')"
    next="$(awk -v s="$hdr" -v l="${#hashes}" \
      'NR>s && match($0,/^#+/) && RLENGTH<=l {print NR; exit}' "$md")"
    if [[ -n "$next" ]]; then
      ins=$((next-1))
      while [[ $ins -gt $hdr ]] && [[ -z "$(sed -n "${ins}p" "$md" | tr -d '\r')" ]]; do
        ins=$((ins-1))
      done
    else
      ins="$(wc -l < "$md")"
    fi
    wo="at the end of section \"$(sed -n "${hdr}p" "$md" | tr -d '\r#' | sed 's/^ *//')\" (after line $ins)"
  fi

  if [[ $dry -eq 1 ]]; then
    echo "CLAUDE.md   : [dry-run] would insert — $wo"
  else
    tmp="$(mktemp)"
    if [[ $ins -gt 0 ]]; then
      head -n "$ins" "$md" > "$tmp"
      printf '%s\n%s\n' "$nl" "$out" >> "$tmp"
      tail -n +$((ins+1)) "$md" >> "$tmp"
    else
      cat "$md" > "$tmp"
      [[ -n "$(tail -c1 "$tmp")" ]] && printf '%s\n' "$nl" >> "$tmp"
      printf '%s\n%s\n' "$nl" "$out" >> "$tmp"
    fi
    mv "$tmp" "$md"
    echo "CLAUDE.md   : arming paragraph inserted — $wo"
  fi
fi

# ---------- 2. Allow-rules (one per machine path) ----------
rules=("Bash(bash $script_pc:*)" "Bash(bash $script_nb:*)")
settings="$proj/.claude/settings.local.json"

fehlend=()
for r in "${rules[@]}"; do
  [[ -f "$settings" ]] && grep -qF "$r" "$settings" || fehlend+=("$r")
done

if [[ ${#fehlend[@]} -eq 0 ]]; then
  echo "settings    : allow-rules already present — unchanged."
elif [[ $dry -eq 1 ]]; then
  echo "settings    : [dry-run] would add — ${fehlend[*]}"
elif command -v node >/dev/null 2>&1; then
  mkdir -p "$proj/.claude"
  node -e '
    const fs = require("fs"), [file, ...rules] = process.argv.slice(1);
    let j = {};
    if (fs.existsSync(file)) {
      const raw = fs.readFileSync(file, "utf8").trim();
      if (raw) j = JSON.parse(raw);
    }
    j.permissions = j.permissions || {};
    j.permissions.allow = j.permissions.allow || [];
    for (const rule of rules)
      if (!j.permissions.allow.includes(rule)) j.permissions.allow.push(rule);
    fs.writeFileSync(file, JSON.stringify(j, null, 2) + "\n");
  ' "$settings" "${fehlend[@]}" \
    && echo "settings    : added ${#fehlend[@]} allow-rule(s) to ${settings#$proj/}" \
    || { echo "install-watcher: settings.local.json not writable (broken JSON?) — add manually:" >&2
         printf '  %s\n' "${fehlend[@]}" >&2; }
else
  echo "install-watcher: node not found — please add the allow-rules manually:" >&2
  printf '  %s\n' "${fehlend[@]}" >&2
fi

# ---------- Summary ----------
cat <<EOF

Done for '$me'. From the next session start on, the session arms itself.
To take effect in the running session: arm the Monitor tool, persistent: true,
  command:     bash $script $me
  description: session bridge: new messages for $me
If one is already running for '$me', the new arm steps aside by itself — state:
  bash $script --status $me
Background and the formerly needed double-arm check are in docs/watcher.md.
EOF
