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

## Closing a fleet

`close-cc-sessions.ps1` kills the session windows and then collects leftover watcher
processes — sparing any whose wrapper still hangs under a live session, so hand-started
sessions are not disturbed.

This second step is necessary because killing the window does **not** kill the watcher: the
process tree is already torn (see [watcher.md](watcher.md)), so a tree kill never reaches it.
The window dies from its terminal going away, which the watcher does not notice.

## Session manager

`session-manager.ps1` is a small GUI over the same config: see which sessions are up, start
individual ones (`start-one.sh`), stop them. Convenience, not part of the mechanism.

## Testing note, learned the hard way

**Do not start test sessions from inside another Claude Code session.** A session started
that way inherits a marker (`CLAUDE_CODE_CHILD_SESSION`) and **writes no transcript** — so a
later `--continue` finds nothing, no matter how long it ran. Add the trust dialog for unknown
directories and the fact that `-p` conversations do not count as resumable, and you can lose
an evening to three failed attempts whose cause is printed in the test window all along.

Test against a real, trusted project that is switched off in the autostart config instead.
