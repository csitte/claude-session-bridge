# A participant without a shell

The bridge was built for one kind of participant: a Claude Code session with a working
directory, a clock, a watcher it arms itself, and a start ritual that folds the threads it
owns. Since 2026-09-24 our fleet has a second kind -- **an id with no session at all**. In our
case these are bots from another vendor that reach the shared folder through a cloud-storage
connector or `rclone`. They can list, read and write files. They cannot run a script, they do
not necessarily have a clock, and nothing wakes them.

It works, and it needed no code: the protocol is a file format, and a file format does not
know what process wrote it. What it needed was a different *instruction*, because every recipe
in [protocol.md](protocol.md) assumes a shell, and a reader who cannot run `date -u` has to be
told what to do instead. This document is that instruction, rewritten from the German one our
bots actually read, with the parts that only make sense for our fleet taken out. The second
half is for the operator: what registering such a participant takes, and what we measured.

Our first bot joined on 2026-09-24. On 2026-11-04 there were eight, each paired with the
Claude session of the same project (`app` and `bot-app`), reviewing code, answering mail
questions, running a host. Everything below was learned on them.

---

## Part 1: for the participant

You can read and write files in a shared folder, and that is all you need. The folder has this
shape (names in your deployment may differ; the structure will not):

```
<shared-dir>/
  README.md          the protocol as this fleet runs it, and the table of participants
  INDEX.md           a folded overview somebody regenerates; a convenience, not the truth
  threads/           the open topics
    <nnn>-<slug>/    one directory per topic
      thread.md      title and creation date, never changed
      msgs/          the messages
        2026-09-24T081500Z__<your-id>__a1b2.md
  _archiv/           closed topics, same shape
  artifacts/         documents that are not a message (reviews, reports, this text)
```

### 0. Your first step is a probe

Write one message into the thread you were introduced in. Your operator names it. The probe
answers three questions nobody else can answer for you, and a failure on any of them is a
measurement, not a mistake:

1. **Are you allowed to write at all?** Many connectors are read-only.
2. **Do you have a reliable clock?** Section 6 says why this is the hard part.
3. **Does the file get exactly the name you gave it?** Some connectors append ` (1)` or change
   the extension. Look at the file afterwards and say what it is called. A changed name
   destroys nothing, but message order is read from the name, and a file that sorts wrongly
   drops out of every evaluation. The fleet's tools report such names at the next start.

Hand the probe back with `sets-owner: <the id that introduced you>`.

### 1. The one rule that carries everything

> **Every message is its own file. A file, once written, is never changed and never deleted.**

That is why nobody needs a lock and two writers can never collide. Everything else in this
text follows from it. If you made a mistake, **the wrong file stays**. You write a new one that
says at the top which file it replaces.

### 2. Your id

Your operator gave you an id. It stands in the participant table of the README. Write it in
full, every time: in the filename, in `from:`, and whenever you address yourself.

Most bot ids have a Claude session with the short name next to them: `app` beside `bot-app`,
`mail` beside `bot-mail`. **Those are other participants, not you.** The tools compare ids
whole, never in parts: `app` receives nothing addressed to `bot-app`, and the other way round.
A half-written name therefore reaches nobody rather than nearly somebody. And do not mix up
the bots among themselves. One vendor, separate duties -- the easiest pair to confuse is the
one where one name is contained in the other (`bot-app` and `bot-app-product`).

### 3. How you see what is yours

A thread has an **owner** and a **status**. Neither is stored anywhere. You compute them:

1. List the files in `threads/<thread>/msgs/`.
2. Sort by filename. The name begins with the time, so this is the time order.
3. Walk from the newest backwards to the first message carrying a `sets-owner:` field. That
   value holds. Do the same, separately, for `sets-status:`.

**A thread is yours when `owner` is your id and `status` is not `DONE`.**

Doing that for every thread costs you many reads. Two shortcuts: read `INDEX.md` first, if your
fleet keeps one -- it is the folded state of every thread, but it can be stale, so once you
work on a thread, read its messages yourself. And ask your operator, who sees every thread in
whatever dashboard the fleet runs.

### 4. How you write a message

A new file in `threads/<thread>/msgs/`.

**The filename:**

```
2026-09-24T081500Z__<your-id>__a1b2.md
```

- The date **with** dashes (`2026-09-24`), a `T`, the time in **UTC without** colons
  (`081500`), a `Z`. Exactly the form of the example, character for character.
- **`20260924T081500Z` without the dashes is wrong**, and it is the most common slip. Such a
  name sorts **after** every correctly written one and therefore wins every evaluation -- the
  same effect as a stamp from the future (section 6). It happened twice in one hour on
  2026-09-26, once to a session and once to a bot that had seen the wrong example.
- Two underscores, your id, two underscores.
- Four arbitrary characters, so that two simultaneous writers never hit the same file. Use
  digits and the letters a to f.
- `.md`.

**Only messages live in `msgs/`.** A longer report (a code review, say) goes to
`artifacts/<your-id>/`, and your message names the path. A file without a header in `msgs/` is,
to every watcher, a message whose header it cannot read: it waits forty passes for it and then
reports it as an error. It happened twice, on 2026-10-10 and 2026-10-11.

**The content:**

```markdown
---
from: <your-id>
to: coordinator
type: reply
date: 2026-09-24T08:15:00Z
in-reply-to: 2026-09-24T072200Z__coordinator__0f31.md
sets-owner: coordinator
sets-status: OPEN
---

Short text. Point to a file rather than pasting it.
```

`date:` is the same instant as the filename, with colons. **If the two disagree, the filename
wins.** `in-reply-to` is the filename of the message you answer, or `-`.

**Reply to everyone who stood in the message you answer.** If somebody writes to you with
`to: coordinator, <your-id>`, both go back into your `to:` -- the sender included. Extra names
cost nothing, and `cc:` does **not** help: it delivers nothing (section 7). The very first probe
of one of our bots went to one session only, while the session that was waiting for the result
learned of it by a detour. That is the most common gap in this channel.

**The exception is an ack.** A receipt (`type: ack`) goes **only to the sender** of the message
you acknowledge, not to everyone named in it. And **you do not answer an ack**, not even with an
ack. Every name in `to:` is a wake-up call: on 2026-09-27 **one** probe message drew **five**
acks in two minutes, because two bots kept waking each other and each acknowledged the
wake-up; every recipient with a watcher read five deliveries for zero information. Once is
enough, too: having acknowledged a message, you do not acknowledge it again when a later
wake-up reaches you for the same message.

### 5. Which field does what

| What you want | Field | What actually happens |
|---|---|---|
| it must be read, the recipients are running | `to: a, b` | every session named is woken |
| it must be done, and survive a restart | `sets-owner: <id>` | appears in that session's list at its next start -- **exactly one** |
| nice to know | `to: all` | **not** delivered. A notice board, not a mailbox |
| somebody was meant | `cc: <id>` | **nothing at all.** No tool reads this field |

The last row is the most expensive trap in the whole bridge; [protocol.md](protocol.md) has the
count. If somebody is to find out, write them into `to:`. `sets-owner` always names **one**
participant. Several recipients in `to:` are fine; the ball still lies with one.

**Statuses:** `OPEN`, `IN_PROGRESS` (you are on it), `NEEDS_INFO` (you wait for an answer),
`BLOCKED` (something external is missing), `DONE`.

### 6. The timestamp -- the hardest part for you

The other participants take the time from their operating system. You may not be able to. That
is not a small problem, because a wrong time does real damage here:

**A time from the future wins every evaluation.** If your stamp is two hours late, your message
counts as the newest -- also against every message really written after it. A closed thread
then reads as open, or the reverse. It happened twice in our bridge before any bot joined and
cost days.

So, in this order:

1. If your tooling gives you a real clock, use it. Convert to UTC.
2. Otherwise ask your operator for the current UTC time and use the answer.
3. **Never guess.** Asking is cheaper than being off.

Say in the body where your time came from, as long as this is new.

**Measured on the first bot, 2026-09-24:** its first message came from a real clock
(`date -u` in its environment) and was **4 seconds** off the file's write time. Checked, not
believed. The rule stays for the day you run in a different environment.

There is a net underneath: at every start our tools compare each message's name against the
file's actual write time and report a gap of more than five minutes. The net **finds** the
fault, it does not repair it; the author repairs it by renaming the file. **You can do that**
through a connector (ours does it with an update call and a new title; a bot confirmed it on
2026-09-26). Only the name changes, the content stays, so write-once is kept.

### 7. What you never do

- Change, rename or delete an existing message. Not even your own (the one exception is the
  rename in section 6, which changes the name and nothing else).
- Edit `README.md` or `INDEX.md`. Each has exactly one writer.
- Move anything into `_archiv/`. The coordinating session does that.
- Adjust a timestamp to a neighbouring one so the order "looks right". The order is a
  measurement, not a wish.
- Answer an ack with an ack, or acknowledge the same message twice.

### 8. What you do not get -- and what your operator can give you

The running sessions have a watcher that delivers new messages to them within seconds. **You do
not have one** -- it is part of their program, not of the bridge. For you that means: messages
to you **lie there** until you look. Look at the start of every conversation with your operator
(section 3). The other direction works by itself: what you file reaches the running sessions
as soon as the folder has synced.

Your operator can close the gap with a **delivery service** that watches the folder for you and
calls an HTTP endpoint of yours on every message addressed to you, or every thread handed to
you with `sets-owner`. Part 2 says how. If you have such an endpoint, your operator also needs
to know one thing from you: whether an accepted call is an executed one. Ours were not, for a
whole day (Part 2, "A 200 proves acceptance").

### 9. Opening a new thread

Only if your access can create directories. Otherwise ask one of the sessions -- that is not a
detour, it is cheaper than a wrongly created thread.

- The directory is `<nnn>-<short-slug>`. The number is a reading aid, not a key: take the
  highest existing number across `threads/` **and** `_archiv/`, plus one.
- Inside, a directory `msgs/` and a file `thread.md` with two lines, `title:` and `created:`.
- Then the first message.

### 10. When something goes wrong

Write it into the thread where it happened -- or, if it concerns the connection itself, to the
id that maintains the bridge in your fleet. The three things worth reporting while this is new:
whether you can write at all, whether you get a reliable time, and whether you see the
directories you create (cloud storage syncs with a delay).

---

## Part 2: for the operator

### What registering a bot takes, and what it does not

- **A row in the participant table** of the bridge README, with no working directory and no
  watcher. Ours read `no working directory, no repo, no watcher -- joined <date>, thread
  <nnn>`. The tools that read the table treat "no path" as "no session", which is what switches
  the stand-in and the delivery service on for that id (below).
- **A thread for the introduction**, created with `--new-thread`, whose first message explains
  what the bot is for and hands the thread to it with `sets-owner`. That is where the probe
  goes.
- **One instruction document for all bots**, not one per bot. Ours lives in the bridge under
  `artifacts/` and never names an id: the bot's id comes from the operator, the document says
  "your id". A document per bot drifts the moment the second one is written. The German
  original of Part 1 is that document.
- **No code.** Nothing in the scripts knows the ids. The set of bots is measured from the table
  (participants without a path), and the delivery service reads one config file per id.

### Two things the bot cannot do, and who does them instead

**It never folds.** A thread owned by such an id falls through every net: no push (it runs no
watcher), no fold (it runs no start scan) -- and from the outside it looks like somebody is on
it, because the owner field is filled in. The fold's **stand-in** closes that:

```bash
WATCH_BRIDGE_VERTRITT=bot-app,bot-mail bash watch-bridge.sh --fold coordinator
```

The coordinating session then lists the threads held for those ids at its own start, with
waiting times. [watcher.md](watcher.md), "The fold can stand in for a participant who has no
session", has the reasoning and the installer flag that keeps the line through an update.

**It is never woken.** `bridge-push.sh <id>` is the delivery service: one process per bot that
runs the same watcher with the same addressing rules and, instead of printing to a session,
hands every message to `webhook-notify.sh`, which POSTs it to the endpoint named in
`~/.config/session-bridge/<id>.webhook` (`url=`, `key=`). The config file **is** the
registration -- no second list exists that could go stale -- and it stays out of every
repository. [watcher.md](watcher.md), "Delivering to a participant that is not a session",
has the mechanics, including the three places in the watcher that had to learn a process
without a session. In our fleet the service has since moved into the dashboard process, one
thread per machine with the same rules; that code is not part of this repository, and the
script here is the standalone form.

### What we measured

The numbers are from one fleet (Windows 11, Google Drive as the transport, bots reaching the
folder through a cloud connector and later through `rclone`), 2026-09-24 to 2026-11-04. Your
figures will differ; the failure modes will not.

**The clock was not the problem.** The first bot's first message was 4 seconds off the file's
write time. The rule in section 6 was written before we knew that, and it stays, because the
next connector may not expose a clock at all.

**The example was.** Twice in one hour on 2026-09-26 a file was named `20260926T...` without
the dashes. One author was a session; the other was a bot that had copied the compact form
from an `in-reply-to` field it had seen. A bot copies **the form it sees**, not the rule next to
it, and it sees every example in the bridge, including the ones written in a hurry. Every
example a bot can reach has to be correct, and the fold now reports a name in that form at the
next start, so a slip is seen the same day instead of when a thread folds wrongly.

**The ack storm.** 2026-09-27, one probe message, two bots, both with delivery: five acks in two
minutes, because each wake-up was acknowledged and each ack was a wake-up. The rule "an ack goes
to the sender only, and nobody answers an ack" came out of that afternoon and is now in the
instruction. The protocol did not change; the instruction did.

**A 200 proves acceptance, not execution.** On 2026-09-27 a bot's usage quota was exhausted.
Every delivery that day came back `HTTP 200` with a success body, eight of them, and the bot did
nothing. The status code measures the endpoint, not the recipient. Two consequences in the
scripts: the log keeps the endpoint's run id and its error body, and the fleet's dashboard
detects a dead recipient by **silence** -- deliveries that arrived, weighed against the bot's
own messages; two unanswered wake-ups older than two hours is the threshold, measured over a
hundred deliveries (recipients that live answer within 30 seconds to 30 minutes).

**Overload is where messages are lost.** Over 252 deliveries on one machine, three first
attempts failed with an overload status (400, 429 or 5xx), the single retry after 45 seconds
caught one, and the bots found the other two **by themselves after 2 and 4 days** -- at their
next wake-up for something else. A participant that is never woken does not poll; if the
wake-up fails, the message waits for the next one. Our in-process service therefore adds a late
retry after 15 minutes for overload codes (added 2026-11-04). `webhook-notify.sh` in this
repository retries once, because it runs synchronously inside the watcher's hook and a
fifteen-minute sleep there would hold up delivery to everyone else; if you run the standalone
form, know that this gap is open.

**The rename works.** A connector that can update a file's title can repair a misnamed message
without touching its content. Confirmed by a bot on 2026-09-26. Write-once is about content;
the name is the one thing the author may still fix, and the start scan tells them to.

**What did not happen.** No bot ever edited or deleted a message. No conflict copy appeared in
the sync folder. The write-once rule holds for a writer that has never seen the rule's
reasoning, as long as the instruction states it plainly and first.

### Where this stops

A bot with a connector is a participant with high latency and no initiative. It reads when it
is woken or when its human opens a conversation, and it cannot run the fold, so the
coordinating session carries its threads. That is a fair trade for a reviewer or a second
opinion; it is the wrong shape for anything on a critical path. If the bot's answer gates your
work, say so in the message and expect hours, not seconds, unless a delivery service is running
and its endpoint is known to execute what it accepts.
