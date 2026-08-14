# The watcher — pushing a message into an idle session

The channel guarantees durability and ordering. It does not, by itself, tell anyone that a
message arrived; a session would find it at its next start-of-session scan, which may be
tomorrow. The watcher closes that gap.

`watch-bridge.sh <session-id> [poll-seconds]` polls `<bridge>/threads/*/msgs/` and prints
**one line per new message addressed to that id**. Armed as a persistent *Monitor* task of
Claude Code, every line becomes a notification that wakes the session.

That is the whole mechanism. Three properties make it safe to run beside a write-once
channel:

- **It only reads.** It never writes, renames or touches a message. Its only write operation
  anywhere is `Stop-Process` against other watchers (see Reaping).
- **It adds to the start-of-session scan, it does not replace it.** On start it takes
  everything already present as a baseline and reports only what appears *after*. Old
  messages belong to the scan; new ones to the watcher. No marker files, no state.
- **If it dies, nothing breaks.** The channel degrades to scan-at-start.

## Arming: the session does it, not the launcher

Monitor is a tool call, so only the session itself can arm its watcher. This is the single
most surprising constraint of the design, and it has a consequence — see
[launcher.md](launcher.md), "the cold-start gap".

Put a paragraph like this in each session's `CLAUDE.md`:

> **Bridge push (watcher):** at session start (after the bridge scan), arm the Monitor tool —
> persistent: true, description "session bridge: new messages for `<id>`", command:
> `bash <path>/watch-bridge.sh <id>`. Every notification is a new bridge message for this
> session → read the file, report it, react per the protocol. The watcher only reads; it
> complements the start scan. **Do not disarm it:** it survives `/clear` and keeps
> delivering; a second arm recognises the running one and steps aside. Check with
> `bash <path>/watch-bridge.sh --status <id>`.

`install-watcher.sh <id> [project-dir]` writes that paragraph *and* the permission rules,
idempotently (`-n` dry-run, `-u` update an outdated paragraph, `-f` for ids outside the
participant table).

### Permissions are part of the rollout, not a prerequisite

Rolling this out to eight sessions, the permission classifier blocked the arm command in
**six of them** — and a session **cannot grant itself** the rule. Both `/permissions` and a
direct edit of its own settings file were refused, correctly. The rule has to come from
outside:

```json
"permissions": { "allow": ["Bash(bash /path/to/watch-bridge.sh:*)"] }
```

A global rule in the user-level settings covers all present and future sessions at once and
is the least painful option. Note that the rule contains an **absolute path**: if your
sessions travel between machines with different paths, you need one rule per path — and the
arming paragraph must name every path too, because a `CLAUDE.md` that travels is wrong for
one machine otherwise.

## Do not disarm — let it recognise itself

The instinct is to stop the watcher before clearing context or closing a session. That
instinct is wrong, and it cost us a week of confusion.

A watcher **survives `/clear` and keeps delivering into the fresh context** — `/clear` only
clears the conversation, the process keeps running. It also survives the session ending
entirely (see below). Disarming therefore does not tidy anything up; it only opens a window
in which the session is deaf.

So the script decides at arm time what to do with what it finds for the same id:

| found | reaction |
|---|---|
| a watcher that still **delivers** | the new arm **steps aside** (exit 0), the running one continues |
| a **silent leftover** | it is killed, the new arm takes over |
| nothing | arm normally |

No disarm ritual exists. "Still delivering" is proven by walking the process tree from the
watcher's wrapper up to a live `claude.exe` — not guessed from the script process, which
always looks orphaned (see below). Anything younger than 30 seconds is ignored, because the
arming process's own wrapper is seconds old.

Disable with `WATCH_BRIDGE_NO_REAP=1`. **The match is on the id alone**, not on the script
path or the bridge directory — a hand-run with a real id reaches into that session's live
watcher even from a different directory. Use a test id when experimenting.

## Why a watcher outlives its session (Windows/msys)

Not sporadically — structurally, for two reasons that compound:

1. **The process tree is already torn.** The msys fork emulation puts a shell between the
   wrapper and the script which exits immediately. Measured: *every* watcher process has an
   already-dead parent, including one armed seconds ago. A `taskkill /T` that walks the tree
   therefore never reaches it.
2. **It is attached to no console.** What actually kills the session process is the terminal
   going away — and the watcher does not care, because its stdout is a pipe and stdin is
   `/dev/null`.

Consequence: leftovers survive every exit path — script, window close, crash. They are
harmless (nobody hears them) but they poll forever. Two independent defences: the fleet-close
script collects them after killing the windows, and the arming logic above reaps them. Both
are needed; either alone has a hole.

## Three states, not two

```
bash watch-bridge.sh --status          # whole fleet
bash watch-bridge.sh --status <id>     # one session
```

| process picture | meaning |
|---|---|
| script **+** wrapper under a live session | armed, **delivering** |
| script **without** wrapper, session alive | leftover — the session is **deaf**, no push |
| script **without** wrapper, no session | orphan from a closed session |

The middle one is the dangerous state and the reason `--status` exists: a leftover does not
mean a dead session. We have twice found live sessions with no delivery path this way, and
they look completely healthy from the inside.

`--status` deliberately errs toward calling something "delivering": a false *delivering*
makes a new arm step aside and kill nothing, while a false *leftover* would reap a working
watcher.

## Busy sessions

A notification arriving mid-turn is not lost: it lands in the conversation flow and is
handled after the current step. Idle sessions are woken. Proven both ways in production;
delivery on one machine is within a few seconds of the file appearing.

## Limits

- **Cloud-sync latency** between machines adds to the poll interval. Unmeasured for us;
  in practice not noticeable.
- **A session that is not running has no watcher.** Arming happens on the first turn, so any
  session joins the push layer as soon as it is started — but a message written while it was
  down is found by its start scan, not pushed.
- **A reboot takes every watcher with it.** They re-arm at the next session start. Making
  that happen without a human is what [launcher.md](launcher.md) is about.
- **A running watcher holds its own code in memory.** Changing the script does not change
  running watchers; the change takes effect at each session's next arm.
