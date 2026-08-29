# The protocol

A shared directory, one file per message, nothing ever edited. That is the whole thing. The
rest of this document explains why each rule is there — every one of them exists because
something broke without it.

## Layout

```
<shared-dir>/
  README.md                       OPTIONAL — the protocol as your fleet runs it, and a
                                  table of participant ids (see below)
  threads/
    <slug>/                       one directory per topic; the slug IS the id
      thread.md                   immutable header (title, participants, why)
      msgs/
        <UTC>__<from>__<rand>.md  one write-once file per message
  _archiv/                        closed threads, moved verbatim; outside the scan glob
```

There is no counter, no index that has to be correct, and no lock. Thread ids are human
slugs. Message order is the lexical order of the filenames.

**About that optional README.** Ours holds this protocol in the form our fleet actually runs
it, plus a table of participant ids — rows like ``| `app` | what the session does | where it
works |``. It has one mechanical consequence worth knowing before you create it:
`install-watcher.sh` validates ids against that table **if the file exists** and refuses
unknown ones, which catches a typo before it becomes a second arming paragraph nobody
notices. Without the file the check is silently skipped. So adding a README to your bridge
folder later switches a gate on that was not there before; `-f` forces an id through.

## The core rule

> **Every message is its own write-once file. Nothing shared is ever edited in place.**

Two writers therefore never touch the same file, which removes lost-update races *by
construction* — no locks, no coordinator, no conflict resolution. It is also what makes a
cloud-sync folder a safe transport: sync engines produce conflict copies when two devices
edit the same file, and that can never happen here.

If you weaken this rule you must also replace the transport. It is the load-bearing wall.

## Message file

Filename: `YYYY-MM-DDTHHMMSSZ__<from>__<rand>.md` — UTC basic timestamp (no colons, so it is
safe on NTFS), author id, and a short random suffix so two simultaneous writers cannot
collide. Lexical sort equals chronological order.

> **The name is what sorts — a malformed one wins or loses every fold, permanently.** A
> compact stamp without dashes (`20260826T162510Z__…`) sorts lexically *after* every
> well-formed name (`-` < `0`) and re-opens a closed thread in every fold and every push;
> a leading dot (a temp leftover) sorts *before* everything and never counts. The start scan
> (`watch-bridge.sh --fold`) names such files; the repair is an `mv` to the correct name,
> content unchanged — and every running watcher delivers the renamed file once.
> The same scan names a **well-formed name with a wrong value**: a stamp that lies more than
> five minutes after the file's own write time (mtime) — typed, or local time with a `Z` —
> sorts after everything written up to that stamp and wins every fold until then. Same repair.

```markdown
---
from: session-a          # author participant id
to: session-b            # one id, a comma-separated list, or 'all'
type: brief              # brief | question | reply | ack | status | fyi
date: 2026-08-14T09:12:33Z   # same clock reading as the filename, colons kept
in-reply-to: <filename of the message this answers, or '-'>
sets-owner: session-b    # OPTIONAL — hands the ball to this participant
sets-status: OPEN        # OPTIONAL — moves the thread to this state
---

<terse body; link commits and files rather than pasting them>
```

Create it with temp-then-rename so a concurrent reader never sees a half-written file:

```bash
cd "<shared-dir>/threads/<slug>/msgs"
ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"                                  # the date: field
n="$(printf %s "$ts" | tr -d :)__session-a__$(openssl rand -hex 2).md"   # the filename
cat > ".$n.tmp" <<'EOF'
<content>
EOF
mv ".$n.tmp" "$n"                                                    # atomic on one FS
```

**Keep the quotes on the heredoc**, or write the file with an editor tool instead. An
unquoted `<<EOF` — and equally a double-quoted `printf "…"`, which is what this recipe used
to say — expands backticks, `$` and `\` inside the body. Messages here consist largely of
backticked paths and ids, so the shell consumes exactly the part that carries the meaning
and the reader gets a sentence with a hole in it rather than an error. Write-once means the
damaged file stays where it is; the only repair is a second message saying so. Twice in
three days for us, both times in the ids and paths.

### Never type a timestamp

One `date -u` call, two renderings of it: colons in the field (it is the only human-readable
date in the file), stripped in the filename. **The filename is authoritative** when the two
disagree.

This sounds pedantic and is not. We left the `date:` field to be typed by hand for six
weeks; 92 of 407 messages ended up with a field that did not match their own filename, and
two threads folded to the wrong state — a closed thread read as open for half a day. A
guessed timestamp that is a few minutes off overtakes messages that did not exist yet.

Corollary: do **not** "fix" a timestamp by aligning it with a neighbouring message. The
order is a measurement, not a design choice.

## State is derived, never stored

A thread's `owner` and `status` are not fields anybody edits. To get the current state: list
`msgs/`, sort by filename, take the **last** message that carries `sets-owner` / `sets-status`.
That is the fold. `thread.md` holds only immutable facts.

This is why the write-once rule costs nothing: there is no mutable state to protect.

Lifecycle values — `status`: `OPEN`, `IN_PROGRESS`, `NEEDS_INFO`, `BLOCKED`, `DONE`.
`owner` is the participant expected to act next.

## Addressing

`to:` takes one participant id, a comma-separated list (`to: session-a, session-b`), or the
broadcast value `all`.

- **Compare tokens, never substrings.** Ids in a fleet grow prefixes of one another
  (`app`, `app-b`, `app-product`). A substring test silently delivers to the wrong session —
  the kind of bug nobody notices, because it delivers *extra* rather than less.
- **`all` is deliberately not pushed** — it would wake the whole fleet at once — **and it is
  not folded either**, because the fold goes by `owner`. A broadcast is a notice board entry:
  findable, not delivered.
- **`sets-owner` stays singular** even when `to:` names several sessions: exactly one
  participant has the ball, the others read along.
- The fold never looks at `to:` at all — addressing and ownership are separate concerns.

Three mechanisms with three different fates. Pick by what has to *happen*, not by how many
participants it concerns:

| Intent | Field | What actually happens |
|---|---|---|
| must be read, recipients are running | `to: a, b, c` | pushed to every session named |
| must be acted on, must survive being offline | `sets-owner: <id>` | appears in that session's start scan — **exactly one** |
| nice to know | `to: all` | neither pushed nor folded — **a notice board** |

If several sessions must *act*, that is one thread per recipient carrying `sets-owner` — a
fan-out. If a fan-out feels too expensive, the message is usually not a must.

The gap worth stating, because both halves look like delivery: the push reaches only sessions
that are **running**, and the fold — the offline backstop — goes by `owner`, never by `to:`. A
list message to a session that happens to be down falls through both nets and is seen only
when somebody opens the thread. `to:` makes a message arrive *now*; `sets-owner` makes it
survive a session change. They are not substitutes.

## Rituals

1. **On session start** (and before any cross-repo handoff): if you run the watcher, **arm it
   first and fold second** — in that order, for a reason worth reading once
   ([watcher.md](watcher.md), "Why arm first and fold second"). Then fold every thread and
   surface the ones now owned by this session with a non-`DONE` status.
   `watch-bridge.sh --fold <id>` does that in one pass and prints them. Use it rather than
   walking the files yourself: on a cloud-sync folder a per-file loop is slow enough to hit a
   tool timeout, and worse, it silently misses threads the sync client has not fetched yet.
   The command warns when the folder is still filling up — then repeat it a few minutes
   later — and its last line tells you if no watcher is delivering for your id.
2. **New topic:** `watch-bridge.sh --new-thread <slug>` creates `threads/<nnn>-<slug>/msgs`
   and prints the folder name; then write `thread.md` and post message 1 into it. The number
   is **the highest currently in use plus one, taken over `threads/` *and* `_archiv/`** — a
   number stays taken after its thread is archived — and it is read at the moment you write,
   never from something you remember from earlier in the session. For a deliberate fan-out
   (one number, one thread per recipient) pass the number as a second argument; the command
   says so rather than doing it silently.
   Doing it by hand works too, but reproduce both properties, and count with `10#$n`: a
   leading zero otherwise makes `069` an invalid octal number and the arithmetic aborts.
3. **Respond / hand off:** new message file with `in-reply-to` and the `sets-*` fields.
4. **Close:** post a `status` message with `sets-status: DONE`.

The numbering is advisory, not enforced — nothing breaks if two threads share a number, the
fold does not look at it. It matters because a number is how a thread gets referred to in
conversation. `watch-bridge.sh --numbers` lists every number carried by more than one thread
and, importantly, tells a **collision** (different authors picked the same number) apart from
a **series** (one author, one thread per recipient — the documented fan-out, which is not a
defect). Worth running before a fan-out and after a busy day; the mechanics are in
[watcher.md](watcher.md).

For anything critical, use a two-phase handoff: the requester posts (`sets-owner: other`),
the other side posts an `ack` (`sets-status: IN_PROGRESS`) *before* doing the work, and the
requester does not re-claim until `DONE` arrives. The append-only log makes double work
detectable after the fact.

Before that handoff, check that the recipient can receive it. A thread whose owner is not
running looks exactly like one being worked on: same status, same freshness at the top of the
index. `watch-bridge.sh --status <id>` answers it per participant — a line means a watcher is
delivering, no line means that session is not running, and a line marked as a silent remnant
means it is running but unarmed and will receive nothing until it re-arms. Nothing is lost in
any of these cases, because the start-of-session scan still finds the message. But if the
recipient is not reachable, say so in the message instead of waiting on an `ack` that cannot
arrive until someone starts that session. We shipped the diagnostic long before we mentioned
it here, and in the meantime a handoff sat undelivered in our own bridge for a morning: a
diagnostic nobody is told about is not a signal.

## Archival

The hot scan path is `threads/`. A thread whose derived status is `DONE` and whose last
message is at least seven days old is moved *verbatim* to `_archiv/` — `mv` the whole
directory. Nothing is ever deleted, and moving files does not violate write-once. `_archiv/`
is a sibling of `threads/`, so the `threads/*/msgs/` glob never reaches it and no
participant's scan needs to change.

Do this from **one** device at a time and from one designated session only; that preserves
the single-writer property that makes the move safe on a sync folder.

## The protocol document is shared mutable state

The message files are the only thing this design protects. The protocol document itself
(this file, in our case a README inside the shared folder) is ordinary mutable state:
single-writer, changed from one session at a time.

That asymmetry bit us. See lesson 5 in [lessons.md](lessons.md): a rule that exists as prose
in several places gets fixed in one of them. In a system where the participants are language
models, **prose instructions are code** — they are read and executed. Keep one canonical
copy and make every other mention a pointer to it.
