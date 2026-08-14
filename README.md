# claude-session-bridge

A durable, file-based message channel between long-running Claude Code sessions — plus a
per-session watcher that **pushes** new messages into an idle session, and a launcher that
brings a whole fleet back up after a reboot.

The whole mechanism is one sentence: **a shared folder of write-once files, and one small
polling script per session.** No server, no daemon, no database, no lock.

Built and operated on a real fleet of ~15 sessions across two Windows machines since July
2026. Everything here is in daily use; the numbers in [docs/lessons.md](docs/lessons.md) are
measurements from that fleet, not estimates.

## What that buys you

These are the properties that made us stop looking for something else. Where one of them came
out of an incident, [docs/lessons.md](docs/lessons.md) has the incident:

- **A message outlives everything.** Reboots, crashes, a context clear, a session that was
  closed for a week. It is a file; it is still there, and the fold still computes the same
  state from it. Nothing lives in a queue or in memory.
- **You can write to a session that is not running.** It finds the message at its next start
  — and knows whether the ball is with it, because ownership is derived from the messages
  themselves. This is the one property no in-process messaging can give you.
- **It crosses machines.** The channel is a folder; ours syncs between a PC and a notebook.
  Same protocol, no extra component, no port, no account.
- **An idle session gets woken, not left waiting.** The watcher turns a new file into a
  notification that re-invokes the session — no human tapping windows. In practice that is
  seconds at the default 5 s poll, though we have never instrumented it
  ([docs/watcher.md](docs/watcher.md) says exactly what we did and did not measure). And if
  the watcher is dead, missing, or the harness changes underneath it, delivery degrades to
  scan-at-start instead of breaking.
- **Two sessions writing at once cannot corrupt anything.** Every message is a new file, so
  there is no lost update, no merge conflict, and no lock to take — which is also what makes
  a cloud-sync folder a safe transport.
- **The push layer cannot damage the channel.** The watcher only ever reads; it never
  writes, renames or deletes a message.

What it costs: it is Windows-first today, and the watcher kills stale watcher processes of
its own id. Both are spelled out immediately below — please do not skip them.

---

## ⚠️ Read this before you run anything

**`watch-bridge.sh` terminates other processes.** When a session arms its watcher, the script
looks for watchers *of the same session id* and, if it finds a silent leftover, kills it
(`Stop-Process`). This is deliberate — it is what keeps exactly one delivering watcher per
session across context clears — but it means the script kills processes on your machine
without asking.

- Read [`bridge/watch-bridge.sh`](bridge/watch-bridge.sh) (the `handle_existing` function)
  before first use.
- Set `WATCH_BRIDGE_NO_REAP=1` to disable the reaping entirely.
- Use a **test id** when experimenting: the reaper matches on the id alone, not on the
  script path — a hand-run with a real id will reach into that session's live watcher. We
  shot down our own watcher exactly this way while testing the docs.

The bridge itself never deletes or edits anything: messages are write-once files, and the
watcher only ever reads them.

## Honest scope

- **Windows-first.** Developed on Windows 11 with Git Bash / mintty and PowerShell. The
  *core* — polling, the arming ritual, message folding — is portable shell. The *process
  hygiene* (`--status`, leftover detection, the launcher's window handling) uses PowerShell
  and WMI and will not run as-is on macOS or Linux. We have never tested it there and do not
  claim it works.
- **The push depends on Claude Code's Monitor primitive.** A session arms a persistent
  background monitor whose stdout lines become notifications. If that primitive changes, the
  push layer disappears and the channel degrades to scan-at-session-start — which still
  works. That degradation path is the design, not an afterthought.
- **Not a product.** No versioning policy, no support, no stability promise — a declared
  snapshot of a system that is in daily use elsewhere. It does have an installer and a test
  suite, because we need them ourselves; what it does not have is anyone on call for you.
  That is also why the scripts carry more "why" than "what" in their comments: the reasoning
  is the part you cannot re-derive from the code.

## What problem this solves

Several Claude Code sessions work in separate repos on related things. They need to hand off
work and signal gating events without a human carrying the message. The obvious approaches
fail in specific ways:

| approach | fails because |
|---|---|
| **git** — a branch, an issue tracker, a file in a shared repo | the obvious one, and it nearly works: durable, ordered, already there. But a message has to reach a working copy you do not control, so someone must pull; two sessions editing one file is a merge conflict, which is exactly what write-once avoids; and nothing tells the other session that anything happened. Issues add a network round-trip and a second place to look |
| ad-hoc files (`REPLY-topic.md`) | no owner, no status, nobody scans them — a real answer sat unread for two weeks |
| native cross-session messaging | ephemeral, same machine only, nothing for a session that is not running |
| a daemon / socket bus | another moving part to keep alive; still no cross-device, no history |

This channel is a **shared folder** (ours lives in Google Drive, which is what makes it work
across two machines) where every message is a write-once file. State is not stored, it is
**derived** by folding the files. That makes it safe under concurrent access with no locks
and no coordinator, and it survives everything: reboots, crashes, context compaction, and
sessions that were not running when the message was written.

The watcher on top is pure latency reduction — see [docs/watcher.md](docs/watcher.md).

## Layout

```
docs/protocol.md    the message format and the folding rules — start here
docs/watcher.md     the push layer: arming, self-recognition, diagnosis
docs/launcher.md    starting and stopping a fleet; the cold-start problem
docs/lessons.md     what six weeks of operating this taught us (with numbers)
bridge/             the watcher and its installer
launcher/           fleet start/stop scripts and the session manager (Windows)
example-bridge/     a synthetic thread showing the on-disk shape
tests/run.sh        test suite (see Tests below)
CONTRIBUTING.md     ground rules, and what a port to another platform would touch
.github/workflows/  CI: shellcheck + suite on Linux, suite + analyzer on Windows
```

If you read only one file after this one, read [docs/protocol.md](docs/protocol.md) — the
channel is the part worth copying even if you never run a line of this code.

## Quickstart (bridge + watcher only)

1. Create a shared folder with a `threads/` subdirectory, and export
   `SESSION_BRIDGE_DIR=/path/to/it` on every machine that takes part.
   [`example-bridge/`](example-bridge/) shows what it looks like once it has content —
   worth thirty seconds before you invent a structure of your own.
2. Copy the **whole `bridge/` directory** somewhere stable, and `cd` there — the commands
   below are run from that copy. Both scripts have to stay together: `install-watcher.sh`
   refuses to run without `watch-bridge.sh` beside it.
3. Edit the **SITE BLOCK in both scripts**. In `watch-bridge.sh` it is only a fallback
   (`SESSION_BRIDGE_DIR` overrides it), but in `install-watcher.sh` it is the path that
   ends up in every session's arming paragraph — leave the example values there and your
   sessions will arm a path that does not exist. The installer warns you if the block
   does not match its own location.
4. For each session: give it an id and run
   `bash install-watcher.sh <id> /path/to/project`. It writes the arming paragraph into
   that project's **existing** `CLAUDE.md` (it will not create one) and adds the
   permission allow-rules — the part people forget, because a session **cannot grant
   itself** the permission to run the watcher. Use `-n` first to see what it would do.
5. Write a message file (recipe in [docs/protocol.md](docs/protocol.md)) and watch the
   other session wake up.

**When you first run `watch-bridge.sh` by hand** — to try it out, to see the output — use a
made-up id and switch the reaping off:

```bash
WATCH_BRIDGE_NO_REAP=1 bash watch-bridge.sh testid 1
```

The reaper matches on the **id alone**, not on the script path or the bridge directory, so
`bash watch-bridge.sh <a real session id>` from a shell reaches into that session's live
watcher — even from another directory, even pointed at a throw-away bridge. This is the one
mistake in here that bites immediately; see the warning at the top.

Note on the participant table: if your bridge folder contains a `README.md` with a table of
participant ids (ours does — it is where the fleet is documented), `install-watcher.sh`
checks new ids against it and refuses unknown ones, which catches typos. Without such a file
the check is simply skipped. So adding a README to your bridge folder later switches that
check on; `-f` forces an id through.

Read [docs/protocol.md](docs/protocol.md) before writing the first message. Two rules there
are load-bearing and cheap to get wrong: **never edit a message file**, and **never type a
timestamp**.

## Tests

```bash
bash tests/run.sh            # all
bash tests/run.sh watcher    # delivery only
```

Everything runs against a throw-away bridge in a temp directory, and the suite refuses to
start unless `SESSION_BRIDGE_DIR` points inside it and `WATCH_BRIDGE_NO_REAP=1` is set — a
test run must never be able to reap a watcher belonging to one of your live sessions.

The suite covers the addressing rules in detail (lists, broadcast, the prefix traps, own
posts, the start baseline) and the installer's file surgery (placement, idempotence,
`-u` update, dry-run, CRLF files, unknown ids, allow-rules). CI runs it on Linux **and**
Windows: the delivery core is plain POSIX shell, so the Linux job is what backs the claim
above that the core is portable while the process hygiene is not.

## Porting this to your system — an open invitation

The design is not Windows-specific; our implementation is. If you run macOS or Linux, you
have something we do not have and cannot fake, and the parts that need you are small and
well isolated:

- **Process hygiene** — `--status`, detecting a live vs. an orphaned watcher, and the
  reaping step all go through PowerShell/WMI in `watcher_inventory()`. A `pgrep`/`ps`
  equivalent would make the whole watcher native. The rest of the file is already
  portable, and the Linux CI job proves it runs there today.
- **The launcher** — mintty windows, `taskkill`, a WinForms session manager. The *idea*
  (data/mechanics split, a start prompt that forces the first turn) transfers to tmux,
  iTerm, or a systemd user unit without much left over.
- **A second sync transport.** We use Google Drive because it happened to be there.
  Syncthing, Dropbox or a shared network mount should all work — the write-once rule is
  what makes any of them safe, and it would be good to have that confirmed by someone who
  actually runs one.

Contributions in that direction are explicitly welcome, including ones that restructure
our code to make room for a second platform. See [CONTRIBUTING.md](CONTRIBUTING.md).
What we cannot do is review a port against reality: we have no macOS or Linux machine
running this, so a port lives or dies by its author's testing — which is exactly why the
test suite exists.

## License

MIT — see [LICENSE](LICENSE).
