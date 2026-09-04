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

Nothing yet.

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
