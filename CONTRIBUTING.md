# Contributing

This repository is a **declared snapshot** of a system that is in daily use elsewhere, not
a product with a roadmap. That shapes what is easy to contribute and what is not — please
read this before spending an evening on a pull request.

## What is most welcome: other platforms

We run Windows 11 with Git Bash/mintty and PowerShell. We have **no macOS or Linux machine
running this**, so we cannot write, test, or honestly review a port — but the design is not
Windows-bound, and the Windows-bound parts are small:

| part | what a port needs |
|---|---|
| `bridge/watch-bridge.sh` — `watcher_inventory()` | a `pgrep`/`ps` equivalent of the PowerShell process inventory: for each watcher process, its id, age, and whether it still hangs under a live session process |
| `--status` and the reaping step | follow from the inventory; the decision logic above them is platform-neutral |
| `launcher/` | mintty windows, `taskkill`, a WinForms UI. A tmux/iTerm/systemd equivalent shares the *idea*, not the code |
| transport | we use a cloud-sync folder; Syncthing or a network mount should work equally well — a report from someone actually running one is valuable in itself |

Restructuring our code to make room for a second platform is fair game. If a clean
abstraction means moving things around, say so in the issue first and we will not fight
over layout.

**A port is judged by its tests, not by our review.** We cannot run your platform, so
`tests/run.sh` has to pass there and any new platform-specific behaviour needs a test of
its own. The suite is deliberately dependency-free (bash, sed, awk, grep) so it can run
anywhere.

## Ground rules that are not up for negotiation

Two properties carry the whole design. A change that weakens either of them will be
declined, however convenient it is:

1. **Write-once.** A message file is never edited, renamed or deleted after creation, and
   the watcher never writes to the bridge at all. This is what makes a sync folder a safe
   transport and what removes the need for locks. If you find yourself wanting to update a
   field in place, the answer is a new message that supersedes it.
2. **The push is a layer, never a guarantee.** Delivery must keep working — degraded to
   scan-at-session-start — if the watcher is dead, never armed, or the harness drops the
   primitive it stands on. Do not build anything that assumes a message was pushed.

Two more, softer but meant seriously:

3. **Anything that kills processes states so, loudly**, and has an opt-out. The reaper is
   the one genuinely rude thing in here; it is documented at the top of the README, and it
   stays documented.
4. **Explain the why in the code.** Most comments here record an incident — a torn process
   tree, a doubled arm, a timestamp that inverted a thread. That is the part you cannot
   re-derive from reading the code, and it is why the comments are long.

## Practical

- Run `bash tests/run.sh` before opening a PR; CI runs it on Linux and Windows.
- Add a line to `CHANGELOG.md` under `## Unreleased` when the change is visible to someone
  running the scripts — a new flag, changed behaviour, a fixed defect. Write what changed
  for them, not what you edited; the reasoning belongs in the commit message. Purely
  internal work (a refactor, a test, a typo) needs no entry.
- `shellcheck --severity=error` must pass. Warnings are printed but do not block; where
  word splitting is deliberate, use a targeted `# shellcheck disable=` **with a reason**.
- Keep the scripts dependency-free. `node` is used for one optional step (writing JSON
  allow-rules) and degrades to printing the rules instead — that is the bar.
- Issues describing a failure mode we have not seen are as useful as patches. So are
  reports that something did *not* work: the numbers in `docs/lessons.md` exist because
  somebody counted, and we would rather hear the counter-example than not.
