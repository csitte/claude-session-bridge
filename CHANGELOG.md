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
- **`launcher/link-skills.sh` — the profile's skill folder becomes a link to the repository
  copy.** A personal skill is a delivery path for knowledge every session needs without carrying
  it in every context: only its name and description are loaded. That only holds if the skill is
  in `~/.claude/skills` on the machine, and that folder lives in the profile, which does not
  travel. On a freshly set up machine it did not exist at all -- the repository held two skills,
  and only the session started with that repository as an additional directory saw them; for
  every other session they did not exist. Nothing reported it. The tool is `link-commands.sh`
  for skills, with the same guards: a skill only in the profile, a version in no commit, or a
  link pointing elsewhere all refuse and touch nothing; an older committed version is allowed
  through, because its content is in the history. It checks **everything** in the profile, not
  only what counts as a skill: a folder without a `SKILL.md` would be hidden just the same.
  `--status` (0 = linked, 10 = not), `-n`, `--unlink`, `CC_SKILLS_REPO`.
- **The launcher fetches a missing clone instead of skipping the entry
  (`launcher/projects.repos.conf`, see `projects.repos.example.conf`).** Until now a missing
  directory was the only reason to skip a project, and the reason went to stderr where the
  session manager does not show it. On a freshly set up machine that hit 13 of 22 entries:
  the list offered projects that could not be started. Now `cc_launch` looks the project up
  in `projects.repos.conf`, clones it, connects its memory (`link-memory.sh`; repo mode or
  its own repository -- decided by whether the fresh clone tracks a `memory/` directory) and
  starts as usual. The address file is deliberately separate from `projects.<host>.conf`:
  that one is the list and exists per machine, the address is the same everywhere, and two
  copies of one address are two places where it can go stale. **Nothing is guessed** -- with
  no line the entry is skipped as before, but with the reason and the exact fix; an address
  assembled from a project name hits a same-named foreign repository sooner or later, and
  that failure looks like success. `CC_NO_CLONE=1` switches the fetching off. If the clone
  works but the memory cannot be connected, the session is started **and told so** through
  its start prompt -- a launcher note on stderr is read by nobody, and a session writing
  into an unconnected memory directory loses its work silently. Leftovers of aborted attempts
  are cleared on the next launch, identified by the pid in their name: the first real run left
  one behind because the launcher died while the login dialog was open, so the failure branch
  never ran. The sweep happens before the "does the target exist" question -- otherwise a
  leftover beside a clone that later succeeded would sit there forever.
- **`--fold` can stand in for a participant who has no session
  (`WATCH_BRIDGE_VERTRITT=<id>[,<id>]`).** The fold folds on `owner == me`, so anyone without
  a session of their own never folds and their threads fall through every net -- no push,
  no fold -- while the owner field makes it look as though somebody is on it. Common enough
  to matter: the human who decides in conversation, a mailbox, an external party. In the
  fleet this was written for, six threads were waiting on one human and four had been
  sitting for a week. Off by default, because a session that does not bundle decisions
  cannot act on someone else's question. Prints thread, waiting time and last writer, oldest
  first; the waiting time is the age of the handover, not of the last message.
- **`--fold` names threads you write in but do not own
  (`WATCH_BRIDGE_TEILNAHME_TAGE`, default 7, `0` disables).** The same blind spot from the
  other side. A complete working conversation between two sessions once ran past a third for
  seventeen hours -- including a handover it needed -- although it was in the `cc:` of every
  message. The age filter is what makes this usable rather than noisy: without it one thread
  showed up with 61 new messages for a session that had left it 20 days earlier, and with 2
  for a session still in it. Median across six sessions: 1 thread, maximum 8.
- **`docs/overview.md` — what this is, in plain words.** A non-technical entry point for
  readers who have not decided yet whether they want any of this: the four capabilities in
  prose, one worked example of three sessions on two machines carrying a breaking change
  between them without a human relaying anything, and an honest comparison with the agent
  frameworks and protocols the large vendors ship (OpenAI Agents SDK, Microsoft Agent
  Framework, CrewAI, LangGraph, A2A, MCP) — including what those do better and when you
  should use them instead. No behaviour change; documentation only.
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

### Fixed
- **A message that arrives while the watcher is being re-armed is no longer lost.** If whatever
  runs the watcher puts a deadline on it -- the harness this was written for caps every
  background watch at 30 minutes -- the watcher is stopped and started again over and over.
  Everything present at startup is baseline, so a message landing in the gap fell through both
  nets: no push (to the new watcher it is old) and no start scan (that ran hours ago), in
  silence. The watcher now writes the files it has seen to a mark
  (`${TMPDIR:-/tmp}/watch-bridge-seen-<id>-<path-key>`); a fresh mark replaces the baseline, so
  what arrived in the gap is reported. A mark older than `WATCH_BRIDGE_STATE_MAX_AGE`
  (default 3600 s) is not used, and the watcher says so and points at `--fold` -- that pause was
  a session change, not a re-arm. `WATCH_BRIDGE_STATE=0` turns it off. The mark stores names,
  not a timestamp, because a sync client carries the original mtime across a machine boundary
  and a "newer than the last run" comparison would discard exactly the messages that crossed it.
- **A session is now told when it starts without its project instructions.** For a project
  whose `CLAUDE.md` is kept outside its own repository (`instructions=<key>`), four things can
  go wrong: the instructions clone is missing on this machine, the key is not in it, the file
  was never committed, or copying it in fails. Each case was reported loudly -- on stderr,
  into a console that nobody inside the session reads -- and the session then ran a whole day
  without its rules. It happened on a freshly set up machine: the clone was missing and the
  project only noticed because it went looking for the file itself. All four cases now set
  `CC_INSTRUCTIONS_NOTE`, the same path into the start prompt that a merge conflict already
  used. The note states the **state**, not the intent: with a file in the working tree it says
  the file may be outdated, with none that the session is running without instructions -- a
  different job in each case. The fix comes last in the text because it is usually a command,
  and a sentence behind it sticks to the path.
- **A shell without its script no longer counts as delivering.** `watch-bridge.sh <id>`
  treated a live wrapper under `claude.exe` as proof that a watcher was delivering, without
  requiring a script process of that id. A wrapper whose script has died delivers nothing,
  so the new arm stepped aside — printing `already delivering (PID ?)` — and the session
  received no pushes at all until someone armed it a second time by hand. `--status` said
  "no watcher" for the same machine state at the same moment, because it has always required
  a script. Both now ask the same question: wrapper **and** script. This is the mirror image
  of the id-less-arm case fixed earlier (there a live arm was mistaken for a remnant); that
  behaviour is unchanged, since arms without a determinable id never reach this test.

  The same wrong test sat in `delivery_state`, and therefore in the arm reminder printed as
  the **last line of every `--fold`** — the one reminder every session reads at startup. It
  stayed silent for a shell without its script, i.e. in exactly the failure it exists to
  catch. If you change what "delivering" means, change all three readers:
  `handle_existing`, `delivery_state`, `status_report`.
- **`cc_check_commands` compares places, not spellings.** It decided whether the profile is
  linked to the repository copy by comparing two `pwd -P` results as strings. Git Bash mounts
  `C:/Users/<user>/AppData/Local/Temp` as `/tmp` (type `usertemp`), so one place has two
  spellings and `pwd -P` returns a different one depending on the way in — through the junction
  `/tmp/x/target`, directly the long path. The reporter then said "not linked" immediately after
  linking. It now asks `-ef` (same device and inode) first and keeps the string comparison as a
  fallback. Harmless in the field, since neither `~/.claude` nor a repository lives under that
  mount; visible in the suite, where one case went red whenever `TMPDIR` pointed there. The
  function is now listed in the canonicalisation check that already covers every other
  path-comparing function.

### Changed
- **`docs/protocol.md`: the message recipe now puts the timestamp in the body itself.** The
  recipe computed `$ts` for the `date:` field and then wrote the body through a *quoted*
  heredoc, which expands nothing -- so the one value it had just computed could not reach the
  text. Authors were left with two ways out, and both are bad: type the timestamp by hand
  (the section right below forbids exactly that, and 92 of 407 messages had a `date:` that
  disagreed with their own filename), or drop the quotes and let the shell eat the backticked
  paths that bridge messages consist of. The recipe now lets `sed` read the heredoc: the
  delimiter stays quoted, `sed` substitutes a `__TS__` placeholder, and the redirect hangs on
  the `sed` call, so there is no temp file and no second pass through the shell. The rule
  worth taking away is not the recipe: **a rule the neighbouring example cannot follow is not
  a rule, it is a wish.**
- **`docs/protocol.md`: `cc:` is documented as delivering nothing.** A field that is not part
  of the protocol but grows in a deployment anyway: no tool reads it, so a cc'd session is
  neither pushed (the push matches `to:`) nor folded (the fold goes by `owner`). In the bridge
  this was written for, it had reached 356 of 2,646 messages before anyone checked, 57 of them
  carrying a ruling in the title -- corrections and withdrawals whose authors believed they had
  circulated them. Documentation only; no behaviour change. The general rule is stated with it:
  a field no tool reads should either get a reader or be declared inert.
- **`docs/watcher.md`: read the whole fold output — the checks print above the table.** No
  behaviour change; the document now says why the advisory lines sit above the thread list and
  what a `| tail -N` on the fold costs. Both maintainer sessions filtered their own diagnostic
  that way on the same morning, independently: one lost a `Namensform:` warning from line 2 and
  heard about it from the outside eleven minutes later, the other missed a duplicate thread
  number that every fold had printed at the top for two days. Includes the filter form that
  survives — signal words, never a position.
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
