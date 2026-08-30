# The launcher — bringing a fleet up, and the cold-start gap

This part is the most environment-specific in the repository (Windows, Git Bash, mintty,
PowerShell). Read it for the *idea* even if you cannot run the scripts: the cold-start gap it
solves will appear in any setup where a capability is armed by the session itself.

## Data and mechanics are separate files

```
_lib.sh                     the ONLY copy of the launch mechanics
projects.<host>.conf        data only: which projects, which directories, which extra dirs
```

One config per machine, mechanics shared. This split existed for operational reasons — the
config differs per host, the mechanics must not drift between them — and it paid twice: when
we opened this repository, the entire mechanics stack turned out to be free of personal data
*by construction*, because everything personal lives in the config files that stayed private.
See `projects.example.conf` for the format:

```bash
projects=(
  "app|/c/code/app|--add-dir \"$HOME/session-bridge\""
  "#off notes|/c/notes|"          # known project, not in autostart
)
```

## The cold-start gap (the interesting part)

A watcher is armed by the session itself, on its first turn, following an instruction in its
`CLAUDE.md`. Our launcher restarted every session with `--continue` and **no prompt**. That
starts the session and restores its history — but it runs **zero turns**. The session is up,
looks perfectly healthy, and has never read its own start ritual.

Measured after one machine restart: **12 sessions running, 1 watcher armed.** The push layer
had quietly hung on the very hand movement it was built to abolish, and nobody noticed until
someone counted processes.

The fix is three lines: the launcher appends a **start prompt**, so exactly one turn happens
per session, unattended. Arming stays the session's own job — a launcher-started watcher
would have no channel into the session, because the notification has to come from the
session's own Monitor task.

Same fleet after the fix: **12 of 12 armed within three minutes, no hand movement.**

Two details that are easy to get wrong and cost us an evening each:

- **The prompt must fence the session in.** Ours says, in effect: run *only* the start
  ritual, begin no task, change no file, commit nothing, send nothing, summarise in five
  lines, then wait. Without that fence, a session whose `CLAUDE.md` starts with a heavy
  ritual will happily run it unsupervised across the whole fleet. See
  `session-startprompt.example.txt` — rename it to `session-startprompt.txt` to activate it;
  if the file is missing, sessions start exactly as before, unarmed but working.
- **Keep the wording in a file, not in the command line.** Ours goes through
  `mintty -e bash -lc "…"`, i.e. two levels of nested quoting, and the backticks that markdown
  wording is full of would be command substitutions there. `$(cat file)` sidesteps all of it.

## Alternating between two machines: pull before the start, memory in the repo

When sessions alternate between two machines, only what is pushed travels — the repo and
the bridge — and **not** the profile under `~/.claude/` (memory, transcripts, settings,
commands). Two pieces of mechanics for that:

**Pull before the start.** `cc_launch` pulls the project repo before the session starts —
fast-forward only. The remote is `CC_PULL_REMOTE` if you set it and the repo has it, else
the branch's upstream, else nothing (said, not pulled). A local lead, a dirty tree or a
sleeping remote are **reported**, and the session starts anyway: a silently skipped pull
would be the worse failure. Not a repo: silent. `--no-pull` (both starters) or
`CC_NO_PULL=1` skips the step, e.g. offline. ssh runs with `ConnectTimeout=5` and
`BatchMode` so that neither a sleeping host nor a passphrase prompt holds up the start.

**Memory in the repo.** Claude Code keeps a project's memory under
`~/.claude/projects/<slug>/memory/`, and the slug is the **path** (`D--work-app` on one
machine, `C--work-app` on the other) — so it never travels. `launcher/link-memory.sh` moves
it to `<repo>/memory/` and turns the profile path into a junction (Windows) or symlink
pointing there; once per machine:

```bash
bash launcher/link-memory.sh /d/work/app            # repo mode:  <repo>/memory/
bash launcher/link-memory.sh --cloud /d/work/app    # cloud mode: <cloud>/_session-memory/<id>/
```

**Which mode?** Repo mode only for infrastructure repos that exist for this purpose alone
(the bridge tooling, a launcher config repo): the memory rides the push the wrap-up makes
anyway, and every memory write shows up as a diff in `git status`. Everything with a public
or private **product** repo takes cloud mode: the memory is Claude's working notes —
customers, prices, failures — and belongs in neither a public nor a shared history, and every
memory write would be a commit there. In cloud mode the sync client carries it without a
commit (with the cloud's own version history); the cloud root is machine-dependent (a short
list in the script, or `SESSION_MEMORY_DIR`, which wins), `<id>` is resolved in this order, all lower-cased: `--name`, else line 1 of `.session-id` in
the tree, else the **participant table of the bridge README** matched by working directory
(set `SESSION_BRIDGE_DIR`), else the directory name. The table matters because a directory
name often differs from the session id; the path is compared as a **whole** path, once as
written and once without its drive letter, so a second machine mirroring the layout under
another drive resolves without a second column of paths nobody can verify. Caveat: the memory is read **once** at session start
with no warning line — after a cold start give the sync client a moment before starting.

**Moving an existing link: `--relink`.** If the profile path already links somewhere else the
run aborts; with `--relink` the link is moved and the files come along. Two cases: a project
leaving repo mode for cloud mode, and a second checkout that shares another session's memory
by junction and should point at the same cloud folder. The **old** target folder is moved
aside (`….pre-link`) only if it lies **inside** the repo you passed — otherwise it is left
untouched and only named, because there it may be another session's memory. If it was
versioned, `git rm -r --cached memory` and `memory/` in `.gitignore` follow — and then
`git check-ignore -v memory/`: an ignore rule that silently does nothing looks exactly like
one that works. If the machine already has a memory of its own, its files
move along; a `MEMORY.md` that differs on both sides — the normal case for a second machine —
is merged (repo lines first, then the lines only the profile has). Any other file that differs
on both sides aborts the run with nothing touched -- and the abort hands over what is needed
to resolve it: both full paths and how many lines differ. **Merging is not the script's job.**
A line tool would have to guess which version holds; the session wrote both versions and
understands the content, so it consolidates them itself: read both, write the result into the
target version, delete the profile version, run again. The script only refuses to guess and
keeps both sides intact until then. A second run reports "already linked", and
every run cross-checks by listing the repo **through** the link. Removing the junction again: `rm <path>` in Git
Bash (msys treats it as a link; `rmdir` says "Not a directory"). Checked: `rm` and `rm -rf`
in Git Bash do **not** follow the junction, the repo stays intact — with PowerShell
`Remove-Item -Recurse` that depends on the version, so do not delete there.

**The stamp, and what the launcher makes of it.** As the last step on the memory, your
wrap-up ritual runs `link-memory.sh --stamp`, which writes `<memory>/.last-wrap` with
`<host> <UTC> <file count>`. Before each start `cc_memory_state` reads it and says two
things, staying silent otherwise:

```
[memory] app: 402 file(s) expected, 387 present -- sync still running (state other-host 2026-08-30T07:11:51Z (25 min ago)).
[memory] app: state from other-host, 2026-08-30T07:11:51Z (25 min ago), 55 file(s).
```

Why the **file count** and not just the time: a sync client transfers file by file, there is
no atomic state — the stamp is itself a file and can arrive *before* the ones it vouches for.
A pure freshness display would then say "up to date" over a half-loaded folder, falsely
reassuring at exactly the dangerous moment. More files than stamped is normal (written
locally since the wrap) and is not reported. In repo mode, exclude `memory/.last-wrap` in
`.gitignore`: there git guarantees completeness itself, and the stamp would only be conflict
fodder between two machines that both wrap.

The counterparts when leaving a machine belong in the wrap-up ritual: WIP commit and push
are mandatory, the hand-over goes into a file that travels (the memory), the session is
closed (two live sessions in one project both answer the same threads and both commit),
and the sync client is given time to upload before the machine sleeps.

## A running session is not started twice

Neither the launcher nor the session manager used to check whether a project already had a
session; the only skip reason was a missing directory. A second window means two sessions in
one tree — and the second one is **silent**: its watcher arm steps aside because one already
delivers for that id (the same picture as [two checkouts sharing one id](watcher.md#two-checkouts-one-claudemd--the-wrong-id),
from a different cause).

`cc_session_running` in `_lib.sh` reads Claude Code's own session registry,
`~/.claude/sessions/*.json` — one file per running session with `pid`, `cwd` and `name`, a
by-product of native cross-session messaging — and compares `name` and `cwd` **exactly**, never
as a substring (`app` is contained in `app-product`). `cc_launch` returns its own **2** for
"already running": that is the normal case on a second run and must not keep the starter
console open as an error; `--force` starts anyway.

**Not the mintty window title.** The title belongs to the *window*, not the session, and
`exec bash` keeps the window open after claude exits — measured once: 16 windows, 15
sessions.

**An entry counts only with a live pid.** The registry file disappears only on a clean exit.
After an unattended reboot the entries of every killed session were still on disk; the
launcher took each one for running and started nothing — a second attempt worked only because
Claude Code prunes dead entries when it starts. So the pid is checked against the running
`claude` processes (`ps -W`, no PowerShell call per project); the process name matters, or a
pid reused after the reboot would count. An **empty** process list means "nothing is alive",
not "check broken" — after a reboot it is rightly empty, and exactly then the start must go
through. `CC_LIVE_PIDS` injects the list for tests.

Two traps met while building it: the config carries msys paths (`/d/work/x`), the registry
Windows paths (`D:\work\x`) — without the rewrite the `cwd` branch would have been dead and
only the name would ever have matched, and a comparison that never matches looks like one that
finds nothing. And test fixtures written with `printf` produced invalid JSON twice; the
bash side greps and tolerated it, PowerShell's `ConvertFrom-Json` failed silently. Write
fixtures with a JSON library, compact form (the registry has no spaces after the colons, and
the grep relies on that).

## Closing a fleet

`close-cc-sessions.ps1` kills the session windows and then collects leftover watcher
processes — sparing any whose wrapper still hangs under a live session, so hand-started
sessions are not disturbed.

This second step is necessary because killing the window does **not** kill the watcher: the
process tree is already torn (see [watcher.md](watcher.md)), so a tree kill never reaches it.
The window dies from its terminal going away, which the watcher does not notice.

## Session manager

`session-manager.ps1` is a small GUI over the same config: see which sessions are up, start
individual ones (`start-one.sh`), stop them. Convenience, not part of the mechanism. Its RUN
marker in this repository still reads mintty window titles — the registry-based marker with
the live-pid check described above lives in our field version and has not been ported yet.

## Testing note, learned the hard way

**Do not start test sessions from inside another Claude Code session.** A session started
that way inherits a marker (`CLAUDE_CODE_CHILD_SESSION`) and **writes no transcript** — so a
later `--continue` finds nothing, no matter how long it ran. Add the trust dialog for unknown
directories and the fact that `-p` conversations do not count as resumable, and you can lose
an evening to three failed attempts whose cause is printed in the test window all along.

Test against a real, trusted project that is switched off in the autostart config instead.
