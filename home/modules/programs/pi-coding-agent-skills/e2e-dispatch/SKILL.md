---
name: e2e-dispatch
description: Move registered Pi e2e-feature agents and their work from kazuki to sachi before suspend, bring them back to kazuki, or check where they run. Use for requests to move, migrate, dispatch, or return these agents between hosts with the e2e-dispatch script.
---

# Move e2e-feature runs between hosts

Use the installed `e2e-dispatch` command. Its source is `/nixfiles/pkgs/e2e-dispatch/e2e-dispatch.py`, packaged and installed through Nix. This operates on registered `e2e-feature` runs in Paseo worktrees; it does not migrate arbitrary agents or preserve live Pi sessions.

## Choose the command

Run `out` on **kazuki**. Run `back` on **kazuki or sachi**: on sachi it forwards the command and its options to kazuki over SSH, streaming the same dispatcher source. Kazuki still drives the transfers. Check `hostname` first. Returning from sachi requires batch-mode SSH access from sachi to kazuki as well as the existing kazuki-to-sachi access. If kazuki is asleep or unavailable, report that it must be woken before a return can run.

```bash
# Read-only inventory; on kazuki this includes runs currently on sachi.
e2e-dispatch status

# Preview moving every eligible run from kazuki to sachi.
e2e-dispatch out --dry-run

# Move every eligible run to sachi.
e2e-dispatch out

# Move only the named feature runs.
e2e-dispatch out <feature> [<feature> ...]

# From kazuki or sachi, preview returning runs to their retained worktrees on kazuki.
e2e-dispatch back --dry-run

# Return all away runs, or only the named features.
e2e-dispatch back [<feature> ...]
```

Use names from `status`, not agent IDs. Preserve the user's selection in both the preview and the actual command. If they request all agents, explain that this script covers registered e2e-feature runs and report any eligibility skips. Creating or explaining this skill does not authorize a move.

## Execute a requested move

1. Run `status`, then the matching `out --dry-run` or `back --dry-run`. Check the preview and blockers. These commands can contact SSH and Paseo even in preview mode. Both hosts need reachable Paseo daemons; the destination needs Pi and the `e2e-feature` skill, and the remote shell needs `python3`, Git, and rsync. The script streams its own Python source over SSH, so it uses the same dispatcher version on both sides.
2. For an authorized move, run the matching command without `--dry-run`. Moving or returning agents is sufficient authorization; do not ask for another confirmation after a successful preview. Do not suspend kazuki until the move finishes.
3. Run `status` again and report each moved feature's host and replacement agent ID, plus skipped or failed features. Exit status zero can include skipped runs, so inspect the output as well. A destination agent reaching `running` or `idle` confirms startup, not completion of its resumed work.

The dispatcher freezes the source orchestrator, subagent runners, and descendants; snapshots commits plus uncommitted and nonignored untracked files; transfers the branch, run artifacts, and a transcript copy; verifies the destination files; and starts a fresh orchestrator with `/skill:e2e-feature resume <handoff file>`. After destination startup, it kills the frozen source processes and archives the old orchestrator. Pi goals and subagent runtime state are host-local; the resumed orchestrator reconstructs its work from the handoff and creates fresh tracking.

The kazuki worktree stays in place while the run is away. Leave it untouched until the return. Ignored build files stay on their original host. On return, the script restores incoming work in the retained kazuki worktree and archives the sachi workspace. Delivery and merging belong to the resumed `e2e-feature` workflow on kazuki.

## Skips and recovery

- **No registered run or missing orchestrator:** registration belongs in that run's own orchestrator session and worktree: `e2e-dispatch register --feature <feature>`. It records `PASEO_AGENT_ID` and, when available, `PI_SESSION_FILE`. Do not register another agent from this operator session or fabricate `run.json`.
- **Design phase:** outgoing runs need the committed `<feature>: add plan` commit and no open `Design:` agent in their worktree. Let the existing design workflow finish; do not bypass its approval or archive its agent to force a move.
- **Paused goal:** `out` skips it by default. Use `--include-paused` only when the user explicitly includes paused runs. That flag moves the run; the resumed workflow still asks before continuing paused work.
- **Git operation in progress:** resolve it through the owning workflow before moving. Do not abort it automatically.
- **Branch already checked out on sachi:** inspect the reported workspace and its work before any cleanup. Do not archive an unrelated or active workspace to force a move.
- **Kazuki worktree changed while away:** returning refuses to overwrite it. Inspect and preserve both versions before resolving the difference; do not reset or clean it to bypass the check.
- **Move failure:** failures during transfer/startup attempt to thaw the source and clean up the partial destination. Inspect `status`, the exact error, and any cleanup warnings before retrying. Failures after destination startup may leave partial bookkeeping or cleanup; verify which agent owns the run before taking further action. Preserve `refs/e2e-dispatch/<feature>/` snapshots and handoff files for recovery.

Normally retain the original provider and thinking level and the default resume prompt. Use `--provider`, `--thinking`, or `--resume-prompt` only when requested or needed for a diagnosed issue; a custom prompt must retain the handoff and resume contract. This workflow is manual: the script does not install suspend/resume hooks.
