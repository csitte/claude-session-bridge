#!/usr/bin/env bash
# bridge-push.sh <id> [poll] -- long-running service: deliver bridge messages to a
# participant that is not a session but an HTTP endpoint.
#
#   bash bridge-push.sh mybot
#
# WHY THIS EXISTS: the bridge's push means "wake a running session", and each session arms
# its own watcher. A participant without a session arms nothing -- it gets neither push nor
# fold, and its messages sit until it looks by itself.
#
# WHY ON THE MACHINE AND NOT IN A SESSION: a bridge message is written by a session, and a
# session only runs while a machine runs. A notifier on the machine can therefore only miss
# what would not exist without that machine. It does NOT depend on a session window being
# open, though: machine on, service running. (Measured in the fleet this came from: 3,072
# of 3,082 messages were written by sessions.)
#
# WHAT IT DOES NOT DO: if no machine runs, nobody wakes. A message filed in that window is
# reported at the next start of the service -- the watcher's mark makes sure it is not
# swallowed as baseline -- and until then the recipient's own polling carries it. Both
# together are the cover; this service is the fast half, not the only one.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
id="${1:-}"
[[ -n "$id" ]] || { echo "usage: $(basename "$0") <bridge-id> [poll-seconds]" >&2; exit 64; }
poll="${2:-5}"

conf="${BRIDGE_PUSH_CONF:-$HOME/.config/session-bridge/$id.webhook}"
log="${BRIDGE_PUSH_LOG:-$HOME/.config/session-bridge/$id.service.log}"

# Fail loudly rather than run quietly: a service without a config would "deliver" every
# message and send nothing, and that looks exactly like "nothing arrived".
if [[ ! -r "$conf" ]]; then
  echo "[bridge-push] no configuration: $conf" >&2
  echo "              Expected two lines: url=... and key=... (from the recipient's side)." >&2
  echo "              The file does NOT belong in a repository." >&2
  exit 78
fi
if ! grep -qE '^[[:space:]]*url=[^[:space:]]' "$conf" || ! grep -qE '^[[:space:]]*key=[^[:space:]]' "$conf"; then
  echo "[bridge-push] incomplete configuration: $conf (url= and key= must be filled in)" >&2
  exit 78
fi

echo "[bridge-push] id:      $id"
echo "[bridge-push] config:  $conf"
echo "[bridge-push] log:     $log"
echo "[bridge-push] poll:    ${poll}s"
echo "[bridge-push] delivery log: $conf.log"
echo

# The watcher decides WHAT is delivered (token-exact, one place), this script only WHERE to.
# `WAKE_ON_OWNER` is set here and nowhere else: a wake-up that only reads `to:` stays silent
# in exactly the case where somebody hands a thread over correctly.
#
# ABOUT THE LOG: stdout goes to a FILE here, not into a pipe. For a watcher inside a session
# that is dangerous (the `echo` into a dead pipe is its last safety net -- see the comment at
# `state_save` in watch-bridge.sh). This service has no monitor that could die, so the file
# is right, and it is the only record of what was delivered.
export WATCH_BRIDGE_WAKE_ON_OWNER=1
export WATCH_BRIDGE_ON_MESSAGE="bash '$here/webhook-notify.sh' '$conf'"

# `--service` is not decoration: without it the process inventory takes this watcher for a
# silent remnant -- "delivering" meant "a wrapper under the session binary is alive", and by
# construction there is none here. The next start would then clean up the running service.
exec bash "$here/watch-bridge.sh" "$id" "$poll" --service >> "$log" 2>&1
