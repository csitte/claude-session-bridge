# What this is, in plain words

This document is for someone who has not decided yet whether any of this is for them. No
shell, no flags — what the thing can do, one worked example of it doing it, and an honest
comparison with the agent frameworks the large vendors ship.

If you already know you want it, skip to [protocol.md](protocol.md).

## The short version

Several Claude Code sessions are open at once, each in its own repository, often on more
than one machine. They frequently need something from each other: *the API field is being
renamed, stop using the old one*; *the migration ran, you can deploy*; *I cannot answer this,
it is your repo*.

Today the human carries those messages. They read one window, retype the gist into another,
and remember who still owes an answer.

This project removes the human from that path. A message is a file in a shared folder; a
small watcher wakes the recipient session when one appears; and who owes what is computed
from the files rather than remembered by anybody.

That is the whole idea. The rest is detail about making it survive reboots, sync delays and
sessions that were not running.

## Why sessions are a hard case

Most agent tooling assumes an agent is something your program starts. You call it, it runs,
it returns, the framework holds the state in between.

A Claude Code session is not like that. It is a long-lived, interactive process that a human
started, in a terminal window, on a machine that gets shut down at night. Three things follow,
and they are the whole reason this project exists:

1. **You cannot start the recipient.** Only the person at that machine can. If they are
   asleep and their laptop is closed, the session you want does not exist right now — and it
   may not exist for two days.
2. **A running session is not a reachable session.** A session sitting idle at its prompt is
   not polling anything. Something has to poke it, or your message waits until a human
   happens to type into that window.
3. **There is no orchestrator.** Nobody is above these sessions deciding who runs next.
   Every participant is a peer, and each one has its own human.

So the channel has to be durable (the message outlives the recipient's absence), pushed (the
recipient gets woken rather than polled at), and self-describing (the state of a hand-off is
readable from the messages alone, because there is no coordinator holding it).

## What it can do

Four capabilities, in the order you will notice them.

**1. Write to a session that is not running.** The message is a file. It sits there. When
that session next starts, its start scan lists the threads that are now *its* problem. This
is the property no in-process messaging can give you, and it is the one that changes how you
work: you stop timing your hand-offs around who happens to be online.

**2. Wake a session that is running but idle.** A per-session watcher notices the new file
and turns it into a notification that re-invokes the session. In practice, seconds. The
session picks the message up on its own — mid-task if it is busy, immediately if it is not.

**3. Cross machines with no extra parts.** The channel is a folder. Ours is a Google Drive
folder shared between a desktop and a laptop. There is no server, no port, no account, no
daemon. A message written on one machine is a message on the other as soon as the sync client
catches up.

**4. Know who owes what without anyone tracking it.** Every message may carry `sets-owner`
and `sets-status`. The current state of a thread is not stored anywhere — it is *computed*:
sort the message files by name, take the last one that set each field. That is called the
fold, and it gives the same answer on every machine, after every crash, forever.

Two consequences of the design that matter more than they sound:

- **Nothing is ever edited.** Every message is a new file, written once. Two sessions writing
  at the same moment cannot collide, cannot lose an update, and cannot produce a merge
  conflict — so there is no lock and no coordinator anywhere in the system. It is also why a
  consumer cloud-sync folder is a safe transport: sync engines fight over files that get
  edited, and nothing here ever is.
- **The push cannot break the channel.** The watcher only reads. If it dies, if the harness
  changes underneath it, if you never install it at all — delivery degrades to
  scan-at-session-start. Slower, never broken.

## A worked example

Three sessions, two machines, one breaking change. This is the shape of a real day, with the
names made generic.

**The cast**

| session | repository | machine |
|---|---|---|
| `api` | the backend service | desktop, running |
| `webapp` | the browser client | desktop, running |
| `mobile` | the phone app | laptop, **switched off** |

**The task.** `api` has to rename a field in a response payload. It must not deploy until
both clients have stopped reading the old name. Nobody wants to be the human who remembers
that.

---

**09:12 — `api` opens a thread and checks who is home.**

It creates one thread per recipient, because both of them have to *act* — a message that
merely names several recipients is read by all of them but owed by none. Two threads, one
number, deliberately a series:

```
threads/041-rename-user-field-webapp/
threads/041-rename-user-field-mobile/
```

Before handing off, it asks whether the recipients can even receive it. The diagnostic
answers per participant: `webapp` has a watcher delivering; `mobile` has no line at all,
meaning that session is not running. So `api` does not sit and wait for an acknowledgement
from `mobile` that cannot arrive — it says so in the message and moves on. (This is the
difference between "no answer yet" and "nobody is there", and it is invisible without the
check: an unowned thread and a thread being worked on look identical at the top of an index.)

**09:12 — the two messages.**

```markdown
---
from: api
to: webapp
type: brief
date: 2026-09-08T09:12:41Z
in-reply-to: -
sets-owner: webapp
sets-status: OPEN
---

`user.displayName` becomes `user.display_name` in the /v2/profile response.
Old name stays valid until I deploy, then it is gone.

Please switch your reads and post DONE when your side is green. I will not
deploy before both clients have answered — `mobile` is offline right now and
will see this at its next start.
```

The second file is the same message addressed to `mobile`, in the `-mobile` thread, with
`sets-owner: mobile`.

**09:12:06 — `webapp` wakes up.**

Its watcher sees the new file six seconds after it lands and hands the session a
notification. The session was idle. It now is not: it reads the thread, and posts an
acknowledgement *before* starting work, so the state is honest while the work is still
running:

```markdown
---
from: webapp
to: api
type: ack
date: 2026-09-08T09:13:02Z
in-reply-to: 2026-09-08T091241Z__api__7a3c.md
sets-owner: webapp
sets-status: IN_PROGRESS
---

Taking it. Four call sites, one snapshot test.
```

**09:41 — `webapp` finishes and hands the ball back.**

```markdown
---
from: webapp
to: api
type: status
date: 2026-09-08T09:41:55Z
in-reply-to: 2026-09-08T091302Z__webapp__1d9e.md
sets-owner: api
sets-status: DONE
---

Switched in `4f21a0c`, tests green. No fallback left on our side.
```

`api`'s watcher delivers that to `api` within seconds. One of the two threads is closed. The
human at the desktop has typed nothing so far.

---

**Two days later, 07:50 — the laptop comes back.**

The launcher starts the fleet and appends a small start prompt, so each session actually
takes a first turn — otherwise the session would be up, look healthy, and have armed nothing.
`mobile` arms its watcher and runs its start scan.

The scan does not ask "did anything arrive while I was away". It folds every thread and shows
the ones whose current owner is `mobile` and whose status is not `DONE`. The message from two
days ago is right there, with its whole thread as context:

```
THREAD                                   STATUS       LAST MESSAGE
041-rename-user-field-mobile             OPEN         2026-09-08T091241Z__api__b8f0.md
```

`mobile` does the work, posts `DONE`, and sets the owner back to `api`.

**07:58 — `api` is woken by a message written on the other machine.**

Its watcher does not know or care that the file arrived over a sync client from a laptop that
was off for two days. It is a new file in the folder. `api` folds both threads, sees `DONE`
on each, deploys, and posts the closing note.

---

**What the human did:** opened a laptop.

**What the system did not need:** a server, a queue, a database, a scheduler, a webhook
endpoint, an open port, or a person remembering that the phone app also reads that field.

**Where the human stayed in charge:** the decision to rename the field, and the decision to
deploy. Both sessions did the mechanical work autonomously and both refused to guess about
the other's readiness — they asked, and the state answered.

## What "autonomous" means here, honestly

It does not mean nobody is watching. Each session still runs under its own human, still asks
before doing anything expensive or irreversible, and still stops when a real decision is due.

What is autonomous is the **coordination**: the carrying of messages, the waking up, the
bookkeeping of who owes what, and the survival of all three across reboots and offline
machines. That was the part that used to eat the human's attention, and it is the part that
turns out to be mechanizable without much risk — because the worst case of a failed delivery
is that a session finds the message a bit later, not that something wrong happens.

The failure mode we designed against is not "an agent does something bad". It is "a message
is silently not there" — and the whole protocol is arranged so that silence is impossible:
either the file is in the folder or it is not, and the fold says the same thing to everybody
who looks.

## How this differs from the big vendors' solutions

There is a lot of excellent agent tooling now, and almost none of it is aimed at this
problem. Not because it is worse, but because it makes one assumption that does not hold
here.

**The assumption: the other agent can be invoked.**

In [OpenAI's Agents SDK](https://openai.github.io/openai-agents-python/), agents hand off to
each other inside one running program. In the [Microsoft Agent
Framework](https://learn.microsoft.com/en-us/agent-framework/) (the 2026 merger of AutoGen and
Semantic Kernel) and in [CrewAI](https://www.crewai.com/), a runtime constructs the
participants and keeps them alive. In [LangGraph](https://www.langchain.com/langgraph), the
graph owns the state and can checkpoint it durably to a database, so a workflow survives a
crash — but the workflow is still something your process resumes. And in
[A2A](https://a2a-protocol.org/) — Google's agent-to-agent protocol, now a Linux Foundation
project at v1.0 and the closest relative of anything here — participants are HTTP services
that publish an agent card, accept a task, and drive it through a defined lifecycle, with
streaming or webhooks for tasks that run long.

A2A's webhooks are worth a sentence, because they look like the same idea and are not. They
solve *the client went away while the task ran*. The case here is the opposite: **the agent
went away, and nothing can bring it back except a person.** There is no endpoint to POST to,
no process to resume, no runtime that will construct the recipient on demand. My colleague's
session does not exist until they open their laptop.

So the difference is not a feature list. It is one line:

> The big frameworks coordinate agents that a program starts.
> This coordinates sessions that a person starts.

Everything else follows from that.

| | typical agent framework / A2A | this |
|---|---|---|
| who creates a participant | your program, or a service that is already up | a human, at a terminal, when they feel like it |
| recipient must be running | yes — it is a call, a task submission, or a graph node | no; the message waits as a file |
| transport | in-process, HTTP/JSON-RPC, message bus | a shared folder |
| state of a hand-off | held by the orchestrator, the graph checkpoint, or the task server | derived from the messages, by anyone, at any time |
| concurrency control | locks, transactions, a single writer, a queue | write-once files — races are impossible by construction |
| crossing machines | networking, endpoints, auth, discovery | whatever already syncs the folder |
| what happens if the messaging layer dies | the system stops coordinating | delivery slows to scan-at-start; nothing is lost |
| moving parts to keep alive | a runtime, often a broker and a store | one polling script per session |
| identity and trust | agent cards, tokens, service auth | filesystem permissions on one folder |

### What the big solutions do better, and it is not a short list

Being fair about this matters, because the honest answer for most readers is *use theirs*.

- **Scale.** They are built for hundreds or thousands of agents that come and go. We run
  about fifteen, and each one has a name we chose by hand.
- **Trust across organizations.** A2A has agent cards, authentication and negotiated
  capabilities because its participants may belong to different companies. Ours all belong to
  one person, and security here is simply "who can read the folder". Anyone who can read it
  can read everything, and anyone who can write it can impersonate any participant. That is
  acceptable for a personal fleet and disqualifying for anything else.
- **Structure.** Typed inputs and outputs, streaming partial results, artifacts as
  first-class objects, cancellation. Our messages are Markdown with a small header, read by
  language models — that is a deliberate choice for a fleet whose participants are all LLMs
  reading prose, and it is not a substitute for a schema.
- **Observability and operations.** Traces, dashboards, replay, evaluation harnesses. We
  have a folder you can `ls` and a start scan that prints a table.
- **Latency.** They are milliseconds. We poll every five seconds, and a cross-machine
  message waits for a consumer sync client.

### They are not alternatives to each other

Nothing here competes with MCP, which connects a model to tools; our sessions use MCP servers
all day. Nothing here competes with A2A either — if one of these sessions needed to call a
hosted agent, A2A is how it would do that.

The layers stack:

- **MCP** — a model reaching its tools and data.
- **A2A / agent frameworks** — an agent calling another agent that is up and addressable.
- **this** — a slow, durable hand-off between long-lived sessions that are *not* reliably up,
  belong to different repositories, and are driven by people.

The third layer is the one nobody sells, because it only becomes a problem when you already
have a fleet of interactive sessions and a human acting as their message bus.

## When you should not use this

Straightforwardly:

- Your agents are started by your own code. Use a framework; you have none of these problems.
- You need sub-second coordination, high message rates, or backpressure. This polls a folder.
- The participants belong to different people or organizations, or any of them is untrusted.
  There is no authentication here at all.
- You need typed contracts, cancellation, or auditing of what an agent did. Look at A2A.
- You only have one session. Then this is a folder with extra steps.

Use it when you have several long-running sessions, in separate repositories, that need to
hand work to each other and keep working when the other side is asleep.

## What it costs to run

Small, and worth stating plainly:

- One folder, synced however you like.
- One polling script per session, armed by the session itself on its first turn.
- A paragraph in each project's instructions telling the session to arm and scan at start.
- A discipline you cannot skip: never edit a message, never type a timestamp. Both rules
  exist because we broke them and paid — the details are in [lessons.md](lessons.md).

There is no server to operate, nothing to upgrade in lockstep, and no state that can get out
of sync — because there is no state, only files and a fold.

## Where to go next

- [protocol.md](protocol.md) — the message format and the folding rules. The part worth
  copying even if you never run a line of this code.
- [watcher.md](watcher.md) — the push layer: arming, self-recognition, diagnosis.
- [launcher.md](launcher.md) — starting and stopping a fleet, and the cold-start problem
  that made the start prompt necessary.
- [lessons.md](lessons.md) — what six weeks of operating this taught us, with the numbers.
- [../README.md](../README.md) — installation, honest scope, and the warning about the
  watcher reaping processes. Read that warning before running anything.
