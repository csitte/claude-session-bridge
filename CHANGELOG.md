# Changelog

All notable changes to this project.

This repository has **no releases and no version numbers**: you clone it and run the
scripts, so `main` is the supported state and there is nothing to pin. Sections below are
therefore dated by the day the change landed, newest first. The format otherwise follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/): *Added* for new capabilities,
*Changed* for behaviour that already existed, *Fixed* for defects.

Entries describe **what changed for someone using the scripts**. The reasoning behind a
change is in the commit message and in `docs/lessons.md`; if an entry sounds arbitrary, the
commit it names will say why.

## Unreleased

### Added
- **`docs/overview.md` — what this is, in plain words.** A non-technical entry point for
  readers who have not decided yet whether they want any of this: the four capabilities in
  prose, one worked example of three sessions on two machines carrying a breaking change
  between them without a human relaying anything, and an honest comparison with the agent
  frameworks and protocols the large vendors ship (OpenAI Agents SDK, Microsoft Agent
  Framework, CrewAI, LangGraph, A2A, MCP) — including what those do better and when you
  should use them instead. No behaviour change; documentation only.

### Changed
- **The `#off` prefix is gone from the launcher config; the config is only the list.**
  Which projects a fleet start opens is decided solely by `autostart.<host>.local` (written
  by the session manager). If that file is missing on a machine, the fleet start starts
  nothing, says so and opens the session manager (`cc_open_manager`); it is no longer seeded
  from the config. A stale `#off` line in a config is a comment to bash and would hide the
  entry silently — `cc_all_entries`, `start-one.sh` and the session manager now report such
  lines instead of reading them. To migrate an existing config: make sure every machine has
  its `autostart.<host>.local` (the previous version seeded it on the first run), then strip
  the prefix: `sed -i 's/^\(\s*\)#off "/\1"/' projects.<host>.conf`.
- **`--new-thread` now requires `--title "<title>"` and writes the cover sheet `thread.md`
  itself** (`title:` and `created:`). Without a title nothing is created and the command
  prints the form to use, with the caller's own arguments filled in. The forced number for a
  fan-out is still a positional argument (`--new-thread <slug> --title "…" 069`). Reason: in a
  live bridge 64 of 102 threads had no cover sheet, because writing it was a prose step after
  the command. The title is a named option rather than a second positional argument so that
  the old documented fan-out form fails out loud instead of silently turning `069` into a
  title. No `participants:` is written — the command cannot know them, and nothing reads the
  field.

### Added
- **`launcher/link-commands.sh`: link the profile's slash-command folder to the repository
  copy** instead of reconciling two versions of it. `~/.claude/commands/*.md` are ritual texts
  that every session executes, and they live in the machine profile, which does not travel — a
  change applies only where it was typed, with no diff pointing at it and no push that could
  fail. Once linked there is one file: a `git pull` puts new commands in front of every session
  on the machine, and editing one shows up in `git status` and travels with the next commit.
  `--status` reports the state (0 linked, 10 not linked), `--unlink` undoes it, `-n` shows what
  would happen. The tool refuses while anything is in the way: a file that exists only in the
  profile would become invisible behind the link, and a changed profile version that is in no
  commit carries work saved nowhere — only an *older committed* version may pass, decided by
  blob hash rather than mtime. The old folder is moved aside, not deleted, and a failed
  verification through the link rolls back. `cc_check_commands` now stays silent where the
  profile is linked, and otherwise adds one line naming the tool — even at parity, because
  parity only means the divergence has not happened yet.
- `watch-bridge.sh --reap [--dry-run] [--all]`: kills orphaned `conhost.exe` consoles that
  keep spinning after a session ended. Eleven of them once held 3.7 of 4 cores for fourteen
  hours. `--status` reports them as well, and the arm reaps spinners on the way in. Load is
  measured both as the lifetime average and as a short delta sample, so a console that starts
  spinning right after a fleet close is caught within seconds rather than hours; the fleet-close
  script applies the same delta check after killing the windows.
- The launcher can copy a project's `CLAUDE.md` in from a clone of a separate instructions
  repository before the start (`instructions=<key>` as the 4th config field). "Merely
  outdated" is caught up because the clone's history serves as the baseline; a local change
  the history has never seen is left alone and reported; a merge conflict in the clone does
  not stop the start but hands the session the task of resolving it, through the start
  prompt. `instructions-sync.sh` is the write path from the wrap-up ritual.
- The launcher pulls repositories passed with `--add-dir` before the start, not only the
  project repository.
- The autostart selection lives in `autostart.<host>.local` (ignored by git), written by
  the session manager and seeded once from the config's `#off` lines. Toggling a checkbox
  no longer changes a versioned file.

### Changed
- The process inventory behind `--status` is fetched once per run and cached for a few
  seconds, and it carries the live `claude` pids, so a `--status` opens one PowerShell
  console instead of two. Simultaneous arms are serialised through a local lock.
- The fleet start refuses to run with an empty selection and says so, instead of
  silently starting nothing.

### Fixed
- **`--retire` now refuses when the linked memory does not belong to `--name`.** `--name` says
  which sync folder is retired; the working directory says what it is checked against — and only
  the second has a default (`.`). A call that left out `<repo-dir>` therefore compared one
  project's sync folder against *another* project's memory, and retired it whenever the contents
  happened to be a subset. It now aborts and prints the call with the project directory filled
  in. Names are compared by basename, lowercased, never as a substring, so sibling ids such as
  `app` and `app-product` cannot be confused.
- **An arm whose session id cannot be determined no longer disappears from the inventory —
  and nothing is reaped around it.** Two checkouts sharing one `CLAUDE.md` have to pass the
  id as `$(head -1 .session-id)`, which stands unexpanded and without a path in the wrapper's
  command line. Such an arm used to be dropped entirely: `--status` then reported a
  *delivering* session as a silent remnant, and the next arm killed its live script —
  measured in the field as half an hour of lost delivery. `--status` now reports these arms
  in a block of their own (pid and arming time), and the arming path leaves everything alone
  while one of them is running, saying why. The duplicate watcher that may result is visible
  (`--status` reports a double arm); severed delivery is not. The id is deliberately **not**
  guessed: resolving a relative `.session-id` would use the reading process's working
  directory and could attribute a foreign id, and the wrapper is not the live parent of the
  script, so there is no process chain to follow either (both measured before choosing).
  Where a `CLAUDE.md` is *not* shared, name the id literally in the arming paragraph and the
  note disappears; never put a concrete id into a shared one.
- **`link-memory.sh` no longer vouches for the profile path when `autoMemoryDirectory` is
  set.** Claude Code's own settings key relocates the auto-memory folder; where it is set,
  the profile path is a leftover and everything derived from it describes the wrong folder.
  `--stamp` used to stamp that leftover with exit 0 and a success message, and the launcher's
  shortfall warning is built on that stamp — so a wrap-up reported green while the real memory
  was never committed and never pushed. Every mode that reasons from the profile path now
  refuses and names the file the key is set in (`--mark-only` excepted; it never touches the
  profile path), and `cc_memory_state` reports the situation once at start-up instead of
  deriving a shortfall warning from a stale stamp. Only a string value triggers it: `null`
  means "not set" to the resolver itself, and a non-string Claude Code rejects, so in both
  cases the profile path stays valid. A `--settings <file>` on the command line is invisible
  to the check, and the message says so. See `docs/launcher.md`, "A setting can move the
  memory out from under all of this".
- `projects.example.conf` showed the `#off` prefix inside the quotes, where bash would have
  read it as an active entry named `#off scratch`. The prefix stands before the quotes,
  which is what `start-one.sh` and the session manager have always parsed.

## 2026-09-04

### Added
- `--fresh` (both starters): start every session without `--continue` — an empty context,
  but a newly created remote-control session that takes its name from the config.
- The launcher now passes `--name`, so a session carries its config name in the prompt box,
  in the `/resume` picker and in the session registry.

### Changed
- The launcher only passes `--continue` when the directory actually has a transcript, and
  says which projects start fresh. Previously a project with no transcript aborted
  interactively ("No conversation found") and the window sat there empty — the session
  never started at all.
- The session manager's RUN marker reads the session registry with a live-pid check instead
  of mintty window titles. A window outlives the session it hosted, so the old marker could
  claim a session that had already exited.
- CI additionally parses the PowerShell scripts with **Windows PowerShell 5.1**. PowerShell 7
  reads a BOM-less UTF-8 file correctly and cannot see the ANSI decoding trap that breaks
  such a file under 5.1, so the existing `pwsh` job proved nothing about that class.

### Fixed
- `cc_has_transcript` no longer answers "not resumable" merely because `cygpath` is absent.
  On a non-Windows host that turned a missing answer into a silently wrong one.

## 2026-08-31

### Changed
- Paths are canonicalised before they are compared or turned into a profile slug — an 8.3
  short name and the long form of one directory otherwise look like two. Applies to
  `norm()`, `cc_memory_state` and `cc_session_running`, with a structural test that holds
  every path-comparing function to the rule.
- `--fold` annotates archive ripeness and stays quiet about the participant id when it is
  run from inside the bridge itself.
- `--fold` explains a missing INDEX slug from both directions and names the rename candidate.
- `link-memory.sh` names the profile-only files before a conflict aborts the run, and tells a
  second machine that an empty profile is the normal case rather than an error.

## 2026-08-30

### Added
- `link-memory.sh --cloud`: keep the memory in a sync folder instead of the repository, for
  projects whose repository is a product repository.
- `link-memory.sh --relink`: move an existing link to a different target.
- `link-memory.sh --stamp` plus a state line the launcher prints before the start, so you can
  see how old the memory is and whether it has fully arrived.
- The launcher compares the global slash commands against the copy in the repository. On a
  name collision the global file wins, so a command file can travel with a repository and
  still do nothing.
- `--fold` reports thread numbers handed out twice while both threads are still open.

### Changed
- `--status` treats an unarmed session as unreachable by message, not merely unwatched.
- `link-memory.sh` resolves the id from the participant table and hands a conflict to the
  session instead of only printing filenames.
- The shipped configuration carries no site-specific details any more (empty `CLOUD_ROOTS`,
  `CC_PULL_REMOTE`, no remote names in the starter headers).

### Fixed
- `--status` no longer mistakes live watchers for remnants when a session armed through the
  `.session-id` form. The next arm would then have reaped a working watcher.
- Counting through a link uses `ls`, not `find`; the empty case aborted the run.
- Tests enforce LF line endings on shipped scripts, where a CRLF script fails confusingly.

## 2026-08-29

### Added
- `--fold` names files in `msgs/` whose name does not sort with the rest, and stamps that lie
  ahead of their own write time. Both decide which message wins a fold.
- The launcher pulls the project repository before the start (fast-forward only) and reports
  a failure without blocking the start.
- `link-memory.sh`: keep the memory in the repository so it travels between machines.

### Changed
- The launcher does not start a project that already has a running session. An entry only
  counts with a live pid — after a reboot the leftover registry files are not sessions.

## 2026-08-27

### Changed
- `--new-thread` names the sibling threads of a series it just created.

## 2026-08-26

### Added
- `--status` reports sessions that are running without a watcher — the dangerous state, and
  the one that is invisible from outside.
- `--fold` names threads that have no owner. Such a thread falls through every fold,
  including those of its own participants.
- `--fold` checks the arming id against the working directory and warns when they disagree;
  `install-watcher.sh -s` writes an id read from `.session-id` for checkouts that share one
  CLAUDE.md.

### Changed
- `--status` distinguishes a young arm ("starting") from two old ones ("DUPLICATE").
- Docs name the settings file explicitly instead of saying "the settings".

## 2026-08-25

### Added
- `--new-thread` hands out the next thread number instead of leaving callers to guess it,
  looking in both the active and the archived folders.

### Fixed
- The watcher re-reads a file whose name arrived before its content. Where a sync client
  showed the name first, the message was marked seen and lost without a trace.

## 2026-08-20

### Changed
- The start ritual is arm first, fold second, and the fold itself warns when no watcher is
  delivering for the id.

### Added
- `--numbers` tells a deliberate fan-out apart from two sessions picking the same number,
  by author rather than by slug.

## 2026-08-16

### Added
- `watch-bridge.sh --fold <id>` as the start-scan command: two greps and a find instead of a
  loop over the bridge, which ran into timeouts on a sync folder.

### Changed
- `to: all` is documented as a notice board, not a delivery path: it is neither pushed nor
  folded, because folding goes by owner and nothing reads `to:`.
- The canonical message recipe uses a quoted heredoc. The previous one demonstrated the very
  trap it warned about — backticks and `$` in a message body were eaten by the shell.

## 2026-08-15

### Changed
- The reachability check is documented where senders read, not only where operators do.

## 2026-08-14

### Added
- First public snapshot: the bridge protocol, `watch-bridge.sh`, `install-watcher.sh`, the
  launcher scripts, docs, an example bridge, tests and CI on Linux and Windows.

### Fixed
- Outside review of the first snapshot: a false claim, a hidden gate and three gaps.
