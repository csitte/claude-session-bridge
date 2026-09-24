#!/usr/bin/env bash
# webhook-notify.sh -- deliver ONE bridge message to a recipient that is not a session
# but an HTTP endpoint.
#
# Meant as the hook for `watch-bridge.sh` (`WATCH_BRIDGE_ON_MESSAGE`). The watcher decides
# WHAT is delivered -- token-exact, in one place; this script only decides HOW it leaves
# the machine.
#
#   usage:  webhook-notify.sh <config-file>
#   input:  the `WB_*` variables the watcher puts into the environment.
#
# Config file (`key=value`, `#` starts a comment):
#   url=https://...
#   key=...
#
# IT IS READ, NEVER EXECUTED. No `source`: a config file you execute is an invitation, and
# a secret inside an executable file is two mistakes in one. The parser takes exactly the
# two keys it knows.
#
# Keep the file out of the repository. Suggested place: `~/.config/session-bridge/<id>.webhook`.
set -uo pipefail

conf="${1:-}"
[[ -n "$conf" ]] || { echo "usage: $(basename "$0") <config-file>" >&2; exit 64; }
[[ -r "$conf" ]] || { echo "[webhook] config not readable: $conf" >&2; exit 66; }

log="${WEBHOOK_NOTIFY_LOG:-$conf.log}"
say() { printf '%s  %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$log"; }

# --- read the config: only known keys, trimmed at the edges ------------------------
url=""; key=""
while IFS= read -r line || [[ -n "$line" ]]; do
  line="${line%$'\r'}"                       # CRLF: a human types this file
  [[ "$line" =~ ^[[:space:]]*# ]] && continue
  case "$line" in
    url=*) url="${line#url=}" ;;
    key=*) key="${line#key=}" ;;
  esac
done < "$conf"
url="${url#"${url%%[![:space:]]*}"}"; url="${url%"${url##*[![:space:]]}"}"
key="${key#"${key%%[![:space:]]*}"}"; key="${key%"${key##*[![:space:]]}"}"

if [[ -z "$url" || -z "$key" ]]; then
  # Fail loudly rather than do nothing quietly: a half-filled config looks exactly like
  # "nothing arrived" in production -- the failure mode this whole path exists to avoid.
  say "ERROR incomplete config ($conf): ${url:+url ok}${url:-url missing}, ${key:+key ok}${key:-key missing}"
  echo "[webhook] incomplete config: $conf" >&2
  exit 78
fi

file="${WB_FILE:-}"
[[ -r "$file" ]] || { say "ERROR message not readable: ${file:-<empty>}"; exit 66; }

# --- build the payload --------------------------------------------------------------
# Python rather than by hand: the body of a bridge message contains quotes, backslashes,
# newlines and backticks. Gluing JSON together with `printf` rebuilds the quoting trap --
# except that here it only shows up at the recipient. `-X utf8`, or Python on Windows
# takes the console code page and mangles non-ASCII.
payload="$(mktemp)" || exit 70
headers="$(mktemp)" || { rm -f "$payload"; exit 70; }
trap 'rm -f "$payload" "$headers"' EXIT

if ! python -X utf8 -c '
import json, os, sys

path = os.environ["WB_FILE"]
with open(path, "r", encoding="utf-8", errors="replace") as fh:
    body = fh.read()

# `to:` is a comma list by protocol. The recipient wants an array -- empty entries drop
# out so that "a, , b" does not leave a hole.
to = [t.strip() for t in os.environ.get("WB_TO", "").split(",") if t.strip()]

json.dump({
    "thread":      os.environ.get("WB_SLUG", ""),
    "filename":    os.path.basename(path),
    "from":        os.environ.get("WB_FROM", ""),
    "to":          to,
    "type":        os.environ.get("WB_TYPE", ""),
    "sets_owner":  os.environ.get("WB_SETS_OWNER", ""),
    "sets_status": os.environ.get("WB_SETS_STATUS", ""),
    "wake_reason": os.environ.get("WB_REASON", ""),
    "body":        body,
}, sys.stdout, ensure_ascii=False)
' > "$payload" 2>>"$log"; then
  say "ERROR could not build payload ($(basename "$file"))"
  exit 70
fi

# The key travels in a curl config file, NOT on the command line: arguments are visible in
# the process list, and a secret that shows up there is readable by every piece of software
# on the machine.
{
  printf 'header = "Authorization: Bearer %s"\n' "$key"
  printf 'header = "Content-Type: application/json"\n'
} > "$headers"
chmod 600 "$headers" 2>/dev/null

send() {
  curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
       --max-time 20 --request POST --config "$headers" \
       --data-binary "@$payload" "$url" 2>>"$log"
}

short="$(basename "$file")"
code="$(send)"
if [[ "$code" == 2* ]]; then
  say "ok $code $short (${WB_REASON:-?}) -> ${WB_ID:-?}"
  exit 0
fi

# Exactly ONE retry. More would not be a better service but a queue nobody drains: what
# fails twice here is picked up by the recipient's own polling -- that is the cover, not
# this call. Set the gap with WEBHOOK_NOTIFY_RETRY.
say "attempt 1 failed (HTTP ${code:-?}) $short -- retrying in ${WEBHOOK_NOTIFY_RETRY:-45}s"
sleep "${WEBHOOK_NOTIFY_RETRY:-45}"
code="$(send)"
if [[ "$code" == 2* ]]; then
  say "ok-after-retry $code $short (${WB_REASON:-?}) -> ${WB_ID:-?}"
  exit 0
fi

say "ERROR failed twice (HTTP ${code:-?}) $short -- the recipient will see it on its own next poll"
exit 1
