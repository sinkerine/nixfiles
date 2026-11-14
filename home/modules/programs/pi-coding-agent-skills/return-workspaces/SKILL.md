---
name: return-workspaces
description: Return dispatched Paseo workspaces and their active agent tabs from sachi to kazuki. Use for requests to bring workspaces home or run workspace-dispatch back from sachi or kazuki, including selected workspace IDs and return previews.
---

# Return workspaces to kazuki

Use the Nix-installed `workspace-dispatch back` command. It works on **sachi or kazuki**. On sachi, it forwards the dispatcher source, options, and invoking tab ID to kazuki over SSH; kazuki drives the return and must be awake and reachable. Both hosts need batch-mode SSH access to each other, working Paseo daemons, and Python 3, Git, and rsync.

Before executing a return, read [the dispatch-workspaces skill](../dispatch-workspaces/SKILL.md) and follow its safety, verification, and recovery rules. Creating or editing this skill does not authorize returning workspaces.

## Usage from a Paseo agent tab on sachi

Invoke this skill from a **different workspace** than the workspace being returned:

```text
/skill:return-workspaces <dispatch-id>
```

Accept one or more dispatch IDs, exact workspace names, or registered feature names; prefer the dispatch IDs shown by `status`. With no selector, return all eligible dispatched workspaces. A preview-only request must not perform a move.

1. Check `hostname` and establish the invoking tab's identity from `PASEO_AGENT_ID`. Preserve this environment variable on every command; the dispatcher forwards it over SSH. If absent, resolve the current tab through Paseo and set it explicitly. Stop if its identity cannot be established.
2. Run `workspace-dispatch status`. Identify the requested records and record their source project display names and workspace titles. Always exclude the invoking tab's entire workspace, even when explicitly selected. If the user wants that workspace returned, explain that they must invoke this skill from another workspace; never bypass the exclusion.
3. Run `workspace-dispatch back <selectors> --dry-run`, omitting selectors only for an all-workspaces request. Review every tab, skip, and blocker. Do not change the selection between preview and execution.
4. For an authorized return after a successful preview, run the same command without `--dry-run`. Do not ask for another confirmation. Respect existing user pauses and pending approvals. Do not return workspaces for a status-only or preview-only request.
5. Run `workspace-dispatch status` again. Inspect kazuki's Paseo workspace and project inventories and verify visible names match the recorded originals. Report returned workspace IDs, replacement tab IDs and states, and all skips or failures. Startup in `running` or `idle` does not mean the task is complete.

## Equivalent shell commands on sachi

Run from a separate Paseo workspace so `PASEO_AGENT_ID` identifies the invoking tab:

```bash
hostname
printenv PASEO_AGENT_ID
workspace-dispatch status
workspace-dispatch back <dispatch-id> --dry-run
workspace-dispatch back <dispatch-id>
```

To return all eligible workspaces, omit `<dispatch-id>` in both the preview and execution commands.

If kazuki is asleep or unreachable, stop and report that it must be awakened. Changed files, HEAD, or branch in the retained kazuki checkout, or an active kazuki tab using it, block a return. Preserve both versions; never reset, clean, or stop unrelated agents to bypass a blocker. Return transfers files and active tabs, includes tabs added after dispatch, and does not restart closed tasks. Only the dedicated away workspace is archived after a successful return. Keep dispatch records, snapshots, and handoffs for recovery.
