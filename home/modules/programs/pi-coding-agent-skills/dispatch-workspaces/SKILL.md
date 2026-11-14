---
name: dispatch-workspaces
description: Move all active Paseo workspace agent tabs and their files from kazuki to sachi before suspend, bring them back, or check where they run. Covers ordinary agents, local directories, Git worktrees, and registered e2e-feature runs. Use for requests to move, migrate, dispatch, or return workspace agents between these hosts.
---

# Move workspace agents between hosts

Use the Nix-installed `workspace-dispatch` command. Its source is `/nixfiles/pkgs/e2e-dispatch/e2e-dispatch.py`. `e2e-dispatch` remains a CLI alias for compatibility. No registration or feature plan is required for ordinary tabs.

The scope is all **running and idle agent tabs**, including background workspaces and any provider exposed by Paseo, **always excluding the current tab invoking this skill**. Tabs sharing a Git checkout or directory move together so their files are transferred once; skip the entire workspace containing the current tab to preserve that rule. This exclusion applies to outgoing moves, returns, previews, and explicit workspace or feature selections. Closed and archived tabs are excluded. Terminal tabs stay on their original host and appear separately in `status`.

The outgoing dispatch project denylist includes `tiny-llm`. Always leave its workspaces on kazuki, including when explicitly selected; do not move them manually to bypass the denylist. Existing dispatched copies can still be returned with `back` for recovery.

This starts replacement agents with transferred files and per-tab transcript handoffs. Live provider sessions, terminal processes, Pi goals, and subagent runtime IDs do not transfer. Registered e2e-feature agents with committed plans use `/skill:e2e-feature resume`; design-phase and ordinary tabs continue from their transcript without inventing feature registration or bypassing approval.

## Choose the command

Check `hostname`. Run `out` on **kazuki**. Run `back` on **kazuki or sachi**; on sachi it forwards the same dispatcher source and options to kazuki over SSH. Kazuki drives the file transfers and must be awake for a return. Both hosts need batch-mode SSH access for a return initiated on sachi.

```bash
# Read-only inventory of workspace IDs, tab IDs, hosts, and terminals.
workspace-dispatch status

# Preview eligible workspace agents moving to sachi (current workspace stays).
workspace-dispatch out --dry-run

# Move all eligible workspace agents.
workspace-dispatch out

# Select whole workspaces using IDs from status.
workspace-dispatch out <workspace-id> [<workspace-id> ...]

# Preview and return dispatched workspaces from either host.
workspace-dispatch back --dry-run
workspace-dispatch back [<workspace-id> ...]
```

Selectors also accept exact workspace names or registered feature names when unambiguous. Prefer the dispatch ID printed by `status`. Selecting a workspace or feature includes every active tab sharing its files, unless it contains the current tab, in which case the entire workspace is skipped. Preserve the user's selection between preview and execution. Creating or editing this skill does not authorize moving agents.

## Execute an authorized move

1. Identify the current tab from `PASEO_AGENT_ID` before dispatch. Preserve this environment variable when invoking the command; the dispatcher also carries it over SSH for forwarded returns. If it is unavailable, resolve the current tab's ID through Paseo and pass it as `PASEO_AGENT_ID`; if the identity cannot be established, stop before moving agents. Run `status` and the matching `out --dry-run` or `back --dry-run`. Review every workspace, tab, skip, and blocker. Preview contacts SSH and Paseo but does not freeze processes, create transfer files, or launch agents. Both daemons must be reachable; the destination needs each tab's provider/model and any skills its resumed task uses. Remote shells need `python3`, Git, and rsync.
2. Run the same command without `--dry-run`. A request to move or return agents is authorization; do not ask again after a successful preview. Do not suspend kazuki until all requested workspaces finish moving. The dispatcher skips the workspace containing its invoking tab. Never bypass this exclusion, even when that workspace is explicitly selected. Report the skipped workspace and current tab ID.
3. Run `status` again and inspect the destination's Paseo workspace and project inventories. Verify that both the project display name (the sidebar heading) and workspace title match the source; `status` alone does not verify the project heading. Dedicated transfer paths and internal IDs may contain dispatch IDs, but visible names must retain the originals. If a heading differs, rename only the dedicated transfer project with `paseo --host <destination-endpoint> project rename <project-id> <original-project-name>`; repair a workspace title with `paseo --host <destination-endpoint> workspace rename <workspace-id> <original-workspace-title>`. Report each workspace's host and replacement tab IDs, and all skips or failures. Exit status zero may include skips. A replacement reaching `running` or `idle` confirms startup, not completion of its task.

The dispatcher exports each tab's Paseo history, freezes the workspace's agent processes and descendants, snapshots and transfers the files, verifies them, and launches every replacement. It records destination ownership before killing and archiving the old agents. Each destination workspace retains the source project display name and workspace title, including for plain directories and reused transfer repositories. Each replacement retains its tab title, provider/model, thinking level, and nondefault mode unless explicitly overridden.

Git workspaces transfer commits, tracked edits, and nonignored untracked files into a dedicated away repository and worktree. The original branch and checkout remain on kazuki; ignored build files and `.pi` runtime changes stay on their original host. Plain directories transfer files and symlinks, excluding the root `.pi` runtime directory. Directories containing the dispatcher's own state, such as the entire home directory, require a narrower workspace to prevent recursive copies.

On return, changed home files or Git HEAD/branch block overwriting the retained workspace. Active home tabs using it also block return. Include active tabs opened in the away workspace after dispatch; restore files without restarting tasks whose tabs have closed. Archive only the dedicated away workspace after its agents and files have returned. Plain-directory recovery copies remain on the away host.

## Skips and recovery

- **Paused goal:** detect session goals in `${XDG_STATE_HOME:-~/.local/state}/pi-goal/goals/*.json` whose `repoRoot` or `cwd` equals the worktree. Legacy `.pi/goals` is ignored and left intact. Source goals are archived in place after their agents stop; the store never transfers. Outgoing workspaces with paused goals skip by default. Use `--include-paused` only when the user explicitly includes them. The handoff still preserves the pause; moving does not authorize continuing paused work.
- **Git operation in progress:** let the owning workflow resolve it; do not abort automatically.
- **Home changed while away or a home tab is using it:** preserve both versions and resolve the conflict before returning. Do not reset, clean, or stop unrelated agents just to bypass the check.
- **Partial destination workspace:** inspect the reported path and tabs before retrying. Do not archive unrelated workspaces. Another dispatch in progress is protected by a host-local transfer lock.
- **Transfer or startup failure:** replacement agents are archived before the source is thawed. If destination cleanup fails, the source stays frozen to prevent simultaneous writers; inspect the exact warnings and replacement ownership before manually thawing the reported PIDs.
- **Failure after ownership is recorded:** inspect both hosts' dispatch records and actual tab states before retrying. Preserve `~/.local/state/workspace-dispatch/`, handoff files, directory snapshots, and `refs/e2e-dispatch/<dispatch-id>/` Git snapshots for recovery.

Normally retain each tab's original launch settings and default resume prompt. Use `--provider`, `--thinking`, or `--resume-prompt` only when requested or needed for a diagnosed issue. A custom prompt must read its `{packet}` handoff and respect pauses and pending approvals. Transfers are manual; no suspend/resume hooks are installed.
