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

A global rule in the user-level settings (`~/.claude/settings.json` — spell the file name
out; a stray `.settings.json` with a leading dot in the same folder looks plausible and is
never read, and an entry there is correctly formatted and does nothing) covers all present
and future sessions at once and is the least painful option. Note that the rule contains an **absolute path**: if your
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

### Telling the middle state apart from the harmless one

Until recently `--status` could not actually distinguish those two rows. It sees watcher
processes; it never saw sessions. A leftover with a live session (deaf session, no push) and
a leftover from a closed window (harmless) produced the same line, and only a human who knew
which sessions were open could tell them apart.

The missing half arrived as a by-product of a feature that has nothing to do with bridges:
since Claude Code shipped native cross-session messaging it keeps a directory of running
sessions under `~/.claude/sessions/` — one JSON per session with `pid`, `cwd`, `name` and
`status`. What makes it usable here is that it is a **file**. The equivalent tool call cannot
be reached from inside a shell script; a file can be read by anything. (`$CLAUDE_CONFIG_DIR`
is honoured if you set it.)

With that second source `--status` says which of the three it is, and appends a block for the
state that has no watcher row at all:

```
app         12345  09-01 10:43  REMNANT (silent) — session IS RUNNING, unarmed
mail        12777  09-01 10:43  REMNANT (silent) — session ended, harmless

UNARMED: 1 running session(s) without a watcher — nothing is delivered there:
         docs             window "Documentation", PID 41902
         Not fixable from outside: that session has to arm the monitor tool itself
         (the arming paragraph in its CLAUDE.md) — or it gets restarted.
```

**Sessions are matched by `cwd`, not by name.** The session name is a window label chosen by
whoever started it and frequently is not the participant id at all. The path column of the
participant table in your bridge README, on the other hand, has one entry per participant.
The full path is compared, **never as a substring**: a participant `app` living in
`/repos/app` would otherwise match the row of `app-product` in `/repos/app-product`, silently
and in whichever direction the table happens to be ordered. This is the same trap the `to:`
list documents, and it caught the implementation of this very check.

**Where it says nothing, on purpose.** A session in a directory the README does not list is
not a participant and raises no alarm. Without the registry, without a README, or on a
platform with no process inventory the check is skipped entirely and `--status` behaves as it
always did — on a platform where watchers cannot be seen, *every* session would look unarmed,
and a warning that is reliably wrong is worse than no warning. A registry entry whose PID is
gone is skipped too, so a stale file cannot raise a false alarm.

Note the shape of this: the messaging feature is **used without a message being sent**. The
watcher stays the delivery path, because the native channel reaches only sessions that are
running and keeps no history — the two properties a bridge exists for.

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

### The fold names threads that have no owner

Folding matches `owner == me`. A thread whose messages never set a `sets-owner:` therefore
shows up in **no** fold at all — not even in the folds of its own participants. It is listed
neither as open nor as done; it is simply absent, and nothing ever makes it archive-ripe.

```
NOTE: 1 thread(s) without a 'sets-owner' -- invisible to every fold, including their participants':
      042-shared-hardware                      status: ?
      Whoever is a participant there sets 'sets-owner' in the next message of that thread.
```

We found one of these sitting unnoticed for ten days while it was still unresolved, and only
by accident — by counting `ls threads/` against the folded lines.

Worse than absent: if you generate an index, it most likely sorts threads by status through a
switch whose default branch catches everything unknown, so an empty status lands in the "done"
bucket. The thread is then not merely missing from the fold, it is **reported as finished** in
the one table a human actually reads. That optimistic default is the real defect; this note
only makes its consequence visible at the place every session already looks — the same reason
the arming reminder lives here.

Two deliberate limits:

- **Only `owner == "" AND status != DONE`.** An ownerless thread that is DONE is picked up by
  the housekeeping rule (DONE + 7 days) and heals itself; reporting it would be noise.
- **It is printed for every session, not only for participants.** A thread with no owner has
  no session responsible for it by definition — that is exactly the defect. Whoever looks
  first passes the word on.


### The fold names files whose name does not sort

Folding and delivery order by the **filename**, not by the `date:` field — the protocol says so
itself: if they disagree, the filename wins. A name outside
`YYYY-MM-DDTHHMMSSZ__<from>__<rand>.md` therefore sorts wrongly, and permanently. In the field
a message named `20260826T162510Z__…` (dashes forgotten, `date:` field correct) sorted lexically
**after** `2026-08-28T…` (`-` < `0`), won every subsequent fold, and kept a thread OPEN for three
days although a younger message had set it DONE. Two effects, not one: the fold flipped for the
owner, and the **push** delivered the same stale state to another reader as current — the DONE
message behind it never reached them. A wrong name does not merely flip a status; it hands a
careful reader a wrong picture with a correct derivation. An error that produces a plausible
result instead of aborting is more expensive than any that fails loudly — so a machine checks it.

```
Name check: 1 file(s) in msgs/ do not start with 'YYYY-MM-DDTHHMMSSZ__' -- folding and push order by the name, not by 'date:':
            threads/047-history-as-corpus/msgs/.tmp-app-cc2b.md
            Repair: mv to the correct name (content unchanged). A temp leftover next to its finished
            message is not a message -- ask the author. Running watchers deliver a renamed file once.
```

Four deliberate choices:

- **A quiet line, no upper-case keyword.** The finding needs visibility, not urgency. It is
  printed **above** the thread list, because it may have flipped exactly the line the reader is
  about to take at face value.
- **Only the timestamp part is checked.** The random suffix is free-form by protocol and does
  not sort; in our bridge it is mostly four hex digits, but `k4n7`, `c0ld` and `winm` exist too.
  A pattern on the suffix would have produced a hundred false alarms.
- **`_archiv/` is included** (a wrong name comes back on reactivation); `threads/_*` is not
  (never folded). A leftover temp file (`.tmp-…md` next to its finished message) fails the check
  as well: it sorts *before* everything and never wins, but it is not a message either — the line
  names it, the action lies with the author.
- **The repair is an `mv`**, content unchanged — the same class as archiving ("relocated, never
  edited"). Side effect, measured in the field: **to every running watcher the new name is a new
  file** — it delivers it once. Wanted for a repair (the reader above got the lost DONE state
  that way after all); it just should not surprise anyone who "quickly" straightens an old file.

Why one incident is enough here, where we usually measure before building: the filename is not
a cheap proxy for the thing, it **is** the thing — the usual objection to cheap measurables
(they measure something other than what is meant) does not apply. And the cost is one regex at
the place every session looks at every start. The test suite replays the incident: a compact
stamp beats a younger, well-formed DONE; after the `mv` the fold heals.

### The fold names stamps that lie ahead of their write time

The name check catches the wrong **form**. On the same day three names turned up with the
right form and a wrong **value**: `…T104500Z` written at 08:45 UTC (local time with a `Z`
appended), `…T160000Z` and `…T170000Z` written at 12:52 and 13:45 (typed). A message stamped
in the future sorts after everything written up to its stamp and wins every fold until then: the
16:00 DONE kept its thread closed, the 17:00 one would have overruled every reply until the
evening — and nothing showed anywhere, because the form was right.

```
Stamp check: 1 file(s) in threads/*/msgs/ whose name lies more than 5 min after the write time (mtime) -- typed, or local time with a 'Z'. They still decide the fold of their thread (last file, last sets-status or sets-owner) and win against everything written up to their stamp:
            threads/174-orders/msgs/2026-08-29T170000Z__mail__c1a8.md  (+3.2 h, written 2026-08-29T134521Z)
            Repair by the author: mv to the name derived from the write time (content unchanged). Running watchers deliver the renamed file once.
            The line disappears once a younger message with sets-* supersedes the file -- it then decides nothing any more.
```

Three choices, two of them against the first proposal:

- **mtime, not `now`.** The proposal was "name lies more than *n* minutes in the future", with
  two objections named by its author: clock drift between machines, and a finding that goes
  away by itself once the clock catches up. Comparing with the file's **mtime** answers both:
  name and mtime come from the same clock; the sync client carries the write time across
  machines (measured: messages written on the other machine sit 2 s from their stamp); and the
  mtime does not move. "Future" was the symptom — the statement is "the stamp lies *n* hours
  after the write time". A false alarm is close to impossible by construction: a synced copy
  can carry a *later* mtime at most (download time), never an earlier one — that misses a case,
  it never invents one. Threshold 5 min; in the field 25 hits in ~1400 messages, the smallest
  real one 5.4 min (a typed round minute), the 2 h cluster being the local-time class.
- **Only what still decides.** The first run showed 13 lines, eleven of them history
  (superseded messages in long-closed threads) burying the one active case. A file is reported
  only while it **decides** the fold of its thread: last file, last `sets-status` or last
  `sets-owner`, compared bytewise as the fold does. So the line does disappear by itself — but
  for the right reason: when a younger message with `sets-*` has superseded the file, not when
  the clock moves on. An `mv` on a superseded file would only wake watchers and break other
  people's `in-reply-to` anyway.
- **`threads/` only**, not `_archiv/` — nothing is folded there any more, so there is nothing
  to do. Repair as for the name check: `mv` to the name derived from the write time, which the
  line prints. Cost: one `find -printf` and two `grep -r`, well under a second; needs GNU find
  and an awk with `mktime` (gawk, mawk ≥ 1.3.4). `WATCH_BRIDGE_STAMP_SLACK` (seconds) for tests.

No protocol change: the one-call recipe has been in the protocol for weeks; the check only
measures whether it was followed.

### The fold names thread numbers handed out twice

`--new-thread` allocates numbers collision-free, but **renaming** bypasses it: whoever
repairs a collision by hand creates the next one with the same movement. A rule against that
acts on the creator — and the creator is precisely who notices nothing. So the detector sits
where every session looks at every start.

```
Thread number: handed out twice, and both threads are open -- the number means two things:
              172-release-notes                            oldest message: 2026-08-29T153006Z__app__1d82.md
              172-network-setup                            oldest message: 2026-08-27T080516Z__other__1c99.md
              Whoever created the later one renames -- take the number from '--new-thread',
              do not guess; renaming onto a guessed number is how this arose.
```

Three choices, each from a measurement rather than an opinion:

- **Only where two of them are still open.** In the field there were nine duplicate numbers
  under `threads/` and exactly one where both threads were open. Naming all nine would have
  printed twenty lines into every fold, eighteen of them without an action. If one is DONE the
  number is unambiguous enough. No status counts as open.
- **`_archiv/` stays out** — historical duplicates are plentiful and settled; `--numbers` is
  the command for those.
- **The oldest message per folder** shows who came later and therefore renames. It is fetched
  **only for the hits**: listing every candidate cost 3.7 s on a sync folder, the hits a
  fraction of that.

### Two checkouts, one CLAUDE.md — the wrong id

**What happened.** A background session living in a second checkout armed and folded under
the id of the *main* checkout. Its arm then correctly stepped aside — a watcher for that id
was already delivering — so the session was **silent**. From the outside everything looked
healthy: `--status <id>` reported "delivering". The fold handed it the other session's inbox,
and it nearly started working on a thread that belonged elsewhere. A human noticed; no tool
did.

**The cause was a template, not carelessness.** Both checkouts share a **committed**
CLAUDE.md, and the arming paragraph in it — written by `install-watcher.sh` — named the main
id at every one of its seven occurrences. The session had *followed* the documentation. A
paragraph that demonstrates the trap beats any warning printed beside it, so the fix has two
halves.

#### 1. `--fold` checks the id against the working directory

New keyword **SUSPECT** (WARNING = the sync client is still fetching, ATTENTION = no arm,
NOTE = thread without an owner). It is printed **above** the thread list, not below: if the id
is wrong the whole list belongs to somebody else, and a warning underneath arrives too late.

Three sources, in order:

1. **`.session-id` in the working directory.** Line 1 the id, line 2 the directory it was
   issued for. The second line catches what `.gitignore` cannot prevent: somebody **copies** a
   tree and the copy claims the original's id.
2. **The participant table of the README.** Does the working directory sit under one of the
   paths registered for this id?
3. Otherwise nothing — no entry, no statement.

Compared with a trailing `/`, **never as a bare prefix**: `…/app/` against `…/app-bgd` would
otherwise pass, and that is exactly the case at hand.

No abort, just a note: deliberately folding a foreign id is a legitimate diagnostic move. The
case this targets is the one where **nobody** notices.

**False-positive check:** every running session in our fleet, invoked from its own working
directory — all of them silent, including two whose directory name and participant id have
nothing in common. The incident itself, replayed, reports.

#### 2. `install-watcher.sh -s/--shared` writes a derivable id

Instead of the fixed id the shared variant writes `$(head -1 .session-id)` — the convention
one participant pair had been maintaining by hand, now produced by the installer.

**The variant is detected from the FILE, not from the flag.** If the existing paragraph
contains `.session-id`, it stays shared — including under a `-u` without `-s`. That is the
heart of it: a register of exceptions you "must not forget during a rollout" does not hold.
Ours is the proof — one participant pair still runs the *previous* ritual order because it was
excluded from an update rollout and got the new wording by message instead. What is only ever
carried over by hand goes stale unnoticed.

The flag is only needed to convert a file for the first time (`-s -u`).

**A side effect that makes the incident impossible:** if `.session-id` is missing the argument
is empty and `watch-bridge.sh` answers with its `usage` — **a loud failure instead of a quiet
wrong id.** The paragraph says so explicitly: do not fall back to another id, do not guess,
ask.

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


**The fan-out note (since thread `168`).** When `--new-thread <slug> <nr>` adds another thread
under a number already in use, the command does not only say "deliberate series" — it says what
to watch out for:

```
watch-bridge: number 168 is taken (168-…-app) -- creating it as a deliberate series.
         NOTE: series 168 now spans 2 threads. Separate owners mean separate
         sight -- name the sibling threads of the series in every message you send,
         or the recipients will answer the same question independently.
```

**Why.** Two sessions sharing one repository got the same request in two threads — correct, so
that each has an owner of its own and neither falls through the fold. Both answered an open
question inside it independently, each committed on their own branch, and the merge tool nearly
decided instead of the two of them. **A fan-out answers "who acts?", not "who needs to know?"**
— separate owners are right, separate sight is not.

**Why in the command rather than in the protocol.** A single observed case does not justify a
rule maintained in three documents, and a rule you have to copy out loses against the shortcut.
The command already knows a fan-out is being created, and its caller is exactly the one who has
to act. If the case shows up a second time, the rule belongs in the protocol — with two pieces
of evidence instead of one.

**Create first, report second.** The series message was originally printed *before* the
`mkdir`. Three lines on stderr are enough for a caller's `| head -2` to close the pipe and kill
the script with SIGPIPE — before the directory exists. Hit during development: the thread was
missing while the output looked complete. **Whatever creates something creates it first and
reports second.**

The test for it is deliberately **structural** (it asserts in the source that `mkdir` precedes
the message) rather than behavioural: whether SIGPIPE actually lands is a race, and a runtime
test for it stayed green with the order broken — guarding nothing. Both times this happened it
surfaced only through a mutation run, never through reading.

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
