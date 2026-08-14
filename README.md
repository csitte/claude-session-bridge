# claude-session-bridge

A durable, file-based message channel between long-running Claude Code sessions — plus a
per-session watcher that **pushes** new messages into an idle session, and a launcher that
brings a whole fleet back up after a reboot.

Built and operated on a real fleet of ~15 sessions across two Windows machines since July
2026. Everything here is in daily use; the numbers in [docs/lessons.md](docs/lessons.md) are
measurements from that fleet, not estimates.

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
- **Not a product.** No installer, no tests, no versioning policy — a declared snapshot of a
  system that is in daily use elsewhere. That is also why the scripts carry more "why" than
  "what" in their comments: the reasoning is the part you cannot re-derive from the code.

## What problem this solves

Several Claude Code sessions work in separate repos on related things. They need to hand off
work and signal gating events without a human carrying the message. The obvious approaches
fail in specific ways:

| approach | fails because |
|---|---|
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
```

## Quickstart (bridge + watcher only)

1. Create a shared folder with a `threads/` subdirectory. Point every machine at it and
   export `SESSION_BRIDGE_DIR=/path/to/it`.
2. Copy `bridge/watch-bridge.sh` somewhere stable and edit the SITE BLOCK near the bottom
   (or rely on `SESSION_BRIDGE_DIR`, which overrides it).
3. Give each session an id and add the arming paragraph to its `CLAUDE.md` — see
   [docs/watcher.md](docs/watcher.md). `bridge/install-watcher.sh` does this for you,
   including the permission allow-rules, which are the part people forget: a session
   **cannot grant itself** the permission to run the watcher.
4. Write a message file and watch the other session wake up.

Read [docs/protocol.md](docs/protocol.md) before writing the first message. Two rules there
are load-bearing and cheap to get wrong: **never edit a message file**, and **never type a
timestamp**.

## License

MIT — see [LICENSE](LICENSE).
