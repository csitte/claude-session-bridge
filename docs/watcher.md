# The watcher — pushing a message into an idle session

The channel guarantees durability and ordering. It does not, by itself, tell anyone that a
message arrived; a session would find it at its next start-of-session scan, which may be
tomorrow. The watcher closes that gap.

`watch-bridge.sh <session-id> [poll-seconds]` polls `<bridge>/threads/*/msgs/` and prints
**one line per new message addressed to that id**. Armed as a persistent *Monitor* task of
Claude Code, every line becomes a notification that wakes the session.

The bridge folder is resolved from the built-in site paths, or from **`SESSION_BRIDGE_DIR`**
if that is set — it overrides them and is then binding, and the script refuses to start if the
directory has no `threads/`. Set it on every machine that takes part when your bridge is not
at one of the site paths, and use it to point a test run at a throw-away bridge instead of
patching a copy of the script.

That is the whole mechanism. Three properties make it safe to run beside a write-once
channel:

- **It only reads.** It never writes, renames or touches a message. Its only write operation
  anywhere is `Stop-Process` against other watchers (see Reaping).
- **It adds to the start-of-session scan, it does not replace it.** On start it takes
  everything already present as a baseline and reports only what appears *after*. Old
  messages belong to the scan; new ones to the watcher. No marker files, no state.
- **If it dies, nothing breaks.** The channel degrades to scan-at-start.

## The start scan lives in the same script

Because the watcher reports only what appears *after* it starts, every session still needs
the scan that picks up whatever was already lying there. `watch-bridge.sh --fold <id>` is
that scan as a command: it folds all threads and lists those with `owner: <id>` and a status
other than `DONE` — slug, status, youngest message. Exit code 0 even when the list is empty,
non-zero only when the bridge itself is missing. The allow-rule for arming
(`Bash(bash …/watch-bridge.sh:*)`) already covers it, so a session can run it unattended.

**Why a command, and not an instruction to "fold the threads".** Every session used to
improvise its own loop. On a cloud-sync folder that is not merely inelegant: each file
access triggers a fetch round, and two of our sessions hit the two-minute tool timeout on
the same morning. `--fold` does two `grep -r` passes and one `find` — three walks over the
tree, well under a second.

**Two completeness checks, both advisory.** A sync client keeps fetching for minutes after a
cold start; one of our sessions saw 55 of 72 thread directories on its first `ls` and all 72
a few minutes later. A fold inside that window misses threads and nobody notices — the same
invisibility as handing off to a session that is not running.

1. The thread-directory count is taken before the grep and again after
   `WATCH_BRIDGE_SETTLE` seconds (default 5). If it changed, the fold repeats (three passes
   at most) and the header line reads `UNSTABLE (55 -> 72)` instead of `stable`. This catches
   only what arrives inside the settle window.
2. If the bridge has an `INDEX.md` — a generated table of threads, which we keep and you may
   not — every slug in it must exist under `threads/` or `_archiv/`; a missing one prints a
   `WARNING`. An index may lag, so it is used strictly as a **lower bound**: a thread once
   indexed never disappears, it only moves. Threads too new to be indexed are check 1's job.

Whatever is present is reported either way; the warning only says whether the result can be
trusted yet. For tests, set `SESSION_BRIDGE_DIR` and `WATCH_BRIDGE_SETTLE=0`.

### A name that arrives before its content

A synced folder can publish the file **name** before its **content** is there. If the watcher
ticks such a file off on first sight, it finds no `to:` field, drops it — and never looks at it
again, because the name is now in `seen`. The message is lost for good, and **nothing anywhere
records that it happened**: the watcher keeps running, the messages before and after arrive
normally. It took a later message referring back to the missing one to notice at all.

So when **not one** frontmatter field is readable, the file is not marked as seen; it is read
again on the next pass, up to `WATCH_BRIDGE_RETRIES` times (default 40 — at a 15 s poll about
ten minutes, because a cold sync client can take minutes to catch up). After that the watcher
gives up, so a file that is not a message at all is not read forever.

The baseline is deliberately exempt: whatever exists at startup is ticked off **without** a
read attempt, or a cold sync client would report half the bridge as it catches up. Old
messages are the start scan's job.

One operational catch: a running watcher holds the old code in memory. The fix takes effect
for a session only when it next starts.

## Arming: the session does it, not the launcher

Monitor is a tool call, so only the session itself can arm its watcher. This is the single
most surprising constraint of the design, and it has a consequence — see
[launcher.md](launcher.md), "the cold-start gap".

Put a paragraph like this in each session's `CLAUDE.md`:

> **Bridge push (watcher):** at session start, **arm first, fold second** — in that order,
> and without checking `--status` beforehand: arm the Monitor tool with persistent: true,
> description "session bridge: new messages for `<id>`", command:
> `bash <path>/watch-bridge.sh <id>`. If a watcher already delivers for this id, the new arm
> steps aside by itself, and a silent remnant is cleared in the process. **Then** run the
> start scan in one pass — `bash <path>/watch-bridge.sh --fold <id>` — and repeat it later if
> it prints a warning. Every notification is a new bridge message for this
> session → read the file, report it, react per the protocol. The watcher only reads; it
> complements the start scan. **Do not disarm it:** it survives `/clear` and keeps
> delivering; a second arm recognises the running one and steps aside. Check with
> `bash <path>/watch-bridge.sh --status <id>`.

`install-watcher.sh <id> [project-dir]` writes that paragraph *and* the permission rules,
idempotently (`-n` dry-run, `-u` update an outdated paragraph, `-f` for ids outside the
participant table).

### Why arm first and fold second

The obvious order is the wrong one, and it is worth spelling out why, because the obvious
order is what we shipped first. Two sessions in a row folded and then skipped arming; one of
them went **two days without a delivery path**, and nothing broke visibly — a session with no
watcher looks exactly like a session with nothing to receive. Checking two rituals afterwards
found the same defect in both. That makes it a property of the instruction rather than a
lapse: the fold produces content and pulls attention immediately, it takes a while on a sync
folder, and the arming that follows produces nothing readable and falls off the end.

Reversing the order costs nothing, because whatever already existed when you armed is
baseline and arrives through the start scan anyway (see "Idempotence" above).

**Do not gate arming on `--status`.** It asks the session to make a decision the script makes
better at arm time (step aside, or reap a remnant), and the decision can go wrong: in the
incident above, one session had the remnant in front of it six times and still did not arm.
`--status` is diagnosis *after* arming.

### Getting the paragraph into a file that paraphrased it

If a session rewrote the paragraph in its own words, it has no `**Bridge push (watcher):**`
marker — `-u` then finds nothing and **appends a second paragraph**. Deleting the old text and
running the installer without `-u` works, but places the block at the *end* of the bridge
section, below everything else there. The cheaper fix, contributed by a session that had just
walked into this:

> Replace the old paragraph with **one** line containing both the marker and the word
> `watcher.md`, then run `-u`. The installer bounds the replacement by exactly that line and
> writes the block precisely where the old one was.

Two rules follow. *"The paragraph is present" is not the same as "the paragraph is where it
gets read."* And project-specific notes belong on their own line **below** the block, never
woven into the template text — otherwise the marker disappears at the next cleanup and the
next `-u` appends instead of replacing.

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
| script younger than `WATCH_BRIDGE_START_GRACE` (default 90 s) | **starting** — not yet a verdict |

A young arm is shown as `starting (Ns)` rather than `delivering`: in its first seconds an
arm inspects the inventory and steps aside if one already delivers. From the outside that is
indistinguishable from a real duplicate, and a fleet overview once reported it as one. The
reflex on a reported duplicate — kill the newer process — hits the wrong one: **the older
watcher is the survivor, the younger is the one dying.** So two rows for one id get a comment
line: one of them young → *note … re-check in a minute*; both old → **`DUPLICATE`**. Only the
second is a finding.

The middle one is the dangerous state and the reason `--status` exists: a leftover does not
mean a dead session. We have twice found live sessions with no delivery path this way, and
they look completely healthy from the inside.

It is dangerous not only because it is inconspicuous, but because it can **stay untreated
after being noticed.** In the incident behind the arm-first rule above, the session had run
`--status` six times and the `REMNANT (silent)` line was in its log four times, verbatim.
Nothing followed. A finding that gets read and not acted on is worthless as mechanism —
which is why the reminder now lives inside `--fold` (below) instead of in a ritual that has
to be followed.

`--status` deliberately errs toward calling something "delivering": a false *delivering*
makes a new arm step aside and kill nothing, while a false *leftover* would reap a working
watcher. Its **exit code is always 0**, including when it lists a remnant. Making the remnant
a non-zero exit was proposed and rejected: a fleet overview calls `--status` without an id
and reads the inventory, so a failure exit would turn the one diagnosis that surfaces the
problem into what looks like a broken tool call.

### The fold reminds you to arm

As its **last** line, `--fold <id>` prints this when nothing is delivering for that id:

```
ATTENTION: no watcher for 'app' — without arming, no bridge push arrives.
           Arm the Monitor tool now (command: docs/watcher.md, or the arm paragraph in CLAUDE.md).
```

For a silent remnant it says so instead, and that arming clears it. Three properties worth
knowing:

- **It only appears when something is wrong.** Arm first, fold second, and you never see it.
  A warning printed at every start becomes wallpaper and fails on the day it matters.
- **Without a process inventory it stays quiet** (no PowerShell, e.g. Linux): the state is
  `unknown`, not "no watcher". A warning that is reliably wrong on an entire platform is
  worse than none.
- **A mistyped id looks the same as an unarmed session** — for a phantom id there genuinely
  is no watcher, so the warning is not wrong, just ambiguous. Copy the id from the arm
  paragraph and it does not come up; checking it against a registry would be more machinery
  than the ambiguity is worth.

## Handing out a thread number: `--new-thread`

Creates `threads/<NNN>-<slug>/msgs` and prints the folder name on stdout (messages go to
stderr, so `slug=$(... --new-thread foo)` works). A second argument **forces** a number — that
is the deliberate fan-out (one number, one thread per recipient); the command says out loud
that it is creating a series rather than doing it silently.

**The leverage is looking properly, not locking.** Measured across every duplicated number in
a live bridge: only two pairs were less than five minutes apart, the rest hours to days. Those
came from the second session not *seeing* the first — it read `threads/` only, while most
threads had been moved to `_archiv/`, or the sync client had not caught up. So the command
reads **both** folders and settles first, the same check `--fold` uses; if the folder count
will not settle it warns that the number may be too low.

The lock covers the two real races. It lives in `$TMPDIR` rather than in the bridge, so no
helper files appear there, and a crashed run's leftover is cleared after a minute. It does not
protect across machines, which is deliberate: two machines never work at the same time here.

If `max+1` turns out to be taken, the command **aborts** instead of creating the thread: the
scan saw too little, and the right response is to wait rather than to work around it.

## Duplicate thread numbers: `--numbers`

```bash
bash watch-bridge.sh --numbers
```

Thread slugs start with a three-digit number, assigned as "highest in use plus one" at write
time (see [protocol.md](protocol.md), "New topic"). Nothing enforces it, and two sessions
that write minutes apart can land on the same number. The fold does not care — but people do,
because the number is how a thread gets referred to.

The command lists every number carried by more than one thread, and separates the two cases a
plain `uniq -d` throws together:

| verdict | meaning |
|---|---|
| `SERIES` | several threads, **one** author — the documented fan-out (one thread per recipient). Not a defect |
| `COLLISION` | several threads, **different** authors — two sessions picked the same number independently |
| `COLL+SERIES` | both at once: a deliberate series sharing its number with an outsider |

```
087  COLLISION     2 threads, 2 author(s)
      app-product       1x  2026-08-12T163527Z
      site              1x  2026-08-12T091736Z
```

**The distinction is made by author, not by slug.** The obvious heuristic — compare the first
slug segment — was wrong on real data: two unrelated threads can share a leading segment
because they concern the same component. Measured across every duplicated number in a live
bridge, the author was exact: every genuine collision had different authors, and the one
deliberate fan-out had exactly one author who wrote 11 threads in 3 seconds. That is why the
per-author time span is printed — a fan-out is recognisable at a glance, a collision usually
sits hours apart.

`_archiv/` is included, because an archived thread keeps its number. Like `--fold`, it makes
one pass over the tree rather than one `ls` per thread, for the same sync-folder reason.

## Busy sessions

A notification arriving mid-turn is not lost: it lands in the conversation flow and is
handled after the current step. Idle sessions are woken. Both cases have been observed
repeatedly in production, on purpose and by accident.

What we can say about latency on one machine: at the default 5 s poll, delivery lands within
seconds of the file appearing — in a deliberate busy-session test, under a minute end to end.
That is an **observation, not a measured distribution**: we have never instrumented it, and
you should treat it as an order of magnitude rather than a figure.

## Limits

- **Cloud-sync latency** between machines adds to the poll interval. Unmeasured for us;
  in practice not noticeable.
- **A session that is not running has no watcher.** Arming happens on the first turn, so any
  session joins the push layer as soon as it is started — but a message written while it was
  down is found by its start scan only if it carries `sets-owner` for that session. The fold
  goes by owner, never by `to:`; see "Addressing" in [protocol.md](protocol.md).
- **A reboot takes every watcher with it.** They re-arm at the next session start. Making
  that happen without a human is what [launcher.md](launcher.md) is about.
- **A running watcher holds its own code in memory.** Changing the script does not change
  running watchers; the change takes effect at each session's next arm.
