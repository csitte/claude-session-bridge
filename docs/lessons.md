# Lessons from six weeks of operating a session fleet

Everything below was learned the expensive way: in production, across sixteen participant
ids (thirteen sessions running on the main machine on a typical day) on two Windows
machines, with a file-based message bridge between them. None of it is theory. Where a rule
sounds oddly specific, there was an incident behind it.

## 1. Write-once files are the whole concurrency model

Every message is a new file; nothing shared is ever edited in place. That single rule
replaces locks, coordinators, and conflict resolution — two writers can never touch the
same file, so there is no lost-update race *by construction*. Thread state (owner, status)
is never stored in a mutable field: it is **derived** by folding the message files and
taking the latest one that sets it.

This is also what makes a cloud-sync folder (Google Drive in our case) a safe transport:
sync engines produce conflict copies when two devices edit the same file — which can never
happen here. The write-once rule is not a style preference; it is the load-bearing wall. If
you weaken it, you must also replace the transport.

## 2. One clock reading, two renderings

Message files sort by a UTC timestamp in the filename. Our original recipe generated the
filename but left the human-readable `date:` field inside the file to be typed by hand.
Measured after a few weeks: **92 of 407 messages (23%) carried a `date:` field that did not
match their own filename** — zeroed times, rounded minutes, local time with a `Z` appended.
Two separate incidents inverted a thread's fold result: a closed thread read as open for
half a day, and vice versa.

The fix is not discipline, it is removing the second rendering from human hands:

```bash
ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"                      # the date: field, verbatim
n="$(printf %s "$ts" | tr -d :)__<id>__$(openssl rand -hex 2).md"  # the filename
```

One clock reading, two derived renderings — and a written rule that **the filename is
authoritative** when they disagree.

**It worked, and the residue is instructive.** Of the next 165 messages written after the
recipe changed, 2 still mismatched — and the one still in the live threads is off by a
single second (`…143454Z` vs. `…143455Z`). That is not an invented timestamp; that is
someone calling `date` twice. The failure class the rule was written against is gone; what
remains is harmless drift that the "filename wins" rule already covers.

Corollary: never type a timestamp, and never "align" one with a neighbouring message. The
order is a measurement, not a design choice.

## 3. A running session is not a reachable session

The push layer (a per-session file watcher) is armed by the session itself on its first
turn — an instruction in the session's project memory. After a reboot, our launcher
restarted every session with `--continue` and **no prompt**: the session was up, looked
healthy, and had executed zero turns — so no watcher, no push, for every single one.
Measured: **12 sessions running, 1 watcher armed** after a machine restart.

The fix: the launcher appends a small start prompt, so the first turn (and the arm) happens
without a human touching each window. Same fleet after the fix: **12 of 12 armed within
three minutes, unattended.**

The general lesson: if a capability depends on "someone will do X at session start", it
silently dies at every cold start. Wire it into the thing that performs the start.

## 4. Let the watcher recognise itself; don't build disarm rituals

Background watchers survive more than you expect — ours survive the session ending, context
clears, and process-tree kills (the process tree is detached at spawn on msys/Windows).
Early on we compensated with a "disarm before closing" ritual; it caused the opposite
problem — delivery gaps, and one session that came back up with no watcher at all because
the ritual half-ran.

The stable design inverted the responsibility: **arming is idempotent**. On arm, the script
checks whether a live watcher for the same id already delivers; if so, the new arm steps
aside (exit 0); if the found process is a dead remnant, it is reaped. No disarm ritual
exists. A leftover process and a duplicate are different things — prove liveness, don't
guess from parent PIDs.

**Warning for adopters:** the reaping step kills processes it identifies as stale watchers
of the same id. That is proven on our machines and rude on yours — read the reaping code
before first use, and set `WATCH_BRIDGE_NO_REAP=1` if in doubt. Note that it matches on the
**id alone**: a hand-run with a real id reaches into that session's live watcher even from
another directory or against a test bridge. We shot down our own monitor exactly that way.

## 5. A rule that lives in two places gets fixed in one

Every protocol rule that mattered existed, at some point, as multiple prose copies: in the
protocol README, in per-session memory, in an instruction template rolled out to 14
sessions. When we changed the timestamp rule, the first grep missed two copies — they
*paraphrased* the recipe instead of quoting it. One overlooked copy would have reinstated
the old behaviour at every session start, because for an LLM-operated system, **prose
instructions are code**: a model reads and executes them.

Search rules that came out of this: grep for the *statement* ("UTC", "timestamp"), not for
the code snippet; and even that has a floor — a rule phrased without its own vocabulary
("take the latest") is invisible to any grep. For those you must know *where the quantity
matters* and inspect those places by hand. The worst instance we found was a prose
instruction with a `mv` attached to it: an archival rule that decided what was "old" without
using a single date word. Best of all: keep one canonical copy and make every other location
a pointer.

## 6. Address matching must be token-exact, never substring

Participant ids in a fleet grow prefixes of each other (`app`, `app-b`, `app-product`;
`mail`, `mail-work`). Any substring or prefix match in the delivery path silently wakes the
wrong session — or, in the inverse bug we actually shipped, a comma-separated recipient list
matched **nobody**, so the push failed for every addressee while the message sat correctly
in the thread. Delivery code must tokenize and compare exactly, and the broadcast address
(`all`) should fall through the same check rather than being special-cased.

Related policy that proved right: broadcasts are deliberately **not** pushed (they would
wake the whole fleet at once); they reach readers via the start-of-session scan. Anything
urgent names its recipients explicitly.

One operational corollary, easy to forget: a **running watcher holds its own code in
memory**. Changing the matching rule changed nothing for the twelve watchers already armed;
the new behaviour arrived session by session, at each next start.

## 7. The push is a layer; the file channel is the contract

Design the channel as if delivery were fully asynchronous — durable, ordered, scanned at
session start — and add the push watcher purely as latency reduction. Ours is built on
Claude Code's Monitor primitive; if the harness changes, the push disappears and the channel
still works, degraded to scan-at-start. Because the watcher only ever *reads*, it cannot
corrupt the channel it accelerates. Keeping the guarantees separate is what made the push
safe to roll out session by session.

## 8. Split data from mechanics — it pays twice

Our launcher keeps the project registry as a data-only config file ("data only; mechanics
live in `_lib.sh`"), one per host. That split existed for operational reasons: each machine
carries its own file, and the shared mechanics cannot drift between them. It paid a second
time at publication: the entire mechanics stack was **PII-free by construction** — an audit
before this release found **0 hits in 9 of 10 files**, the tenth being a README with a path
example — because everything personal (names, paths, hosts) lives in the data files that
stay private. If you may want to open-source your tooling some day, this split is the
cheapest preparation you can make years in advance.

## 9. A session cannot grant itself permissions

Rolling the watcher out to the fleet, the permission classifier blocked the arm command in
**6 of 8** sessions — and a session cannot add an allow-rule for itself; that has to come
from outside. Both the permissions helper and a direct edit of its own settings file were
refused, correctly. The installer therefore writes both the instruction paragraph *and* the
allow-rules into each target session's config. If you automate anything across sessions,
treat permissions as part of the rollout artifact, not as a one-time manual step.

---

*The numbers in this chapter were measured on the authors' fleet (Windows 11, Git
Bash/mintty, Claude Code) between July and August 2026. Your mileage will vary; the failure
modes won't.*
