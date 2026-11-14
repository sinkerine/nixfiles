---
name: merge-push-and-archive
description: Finish completed Git workspace work by committing, merging into the repository default branch, pushing, archiving the current Paseo workspace, and deleting its project registration only if no other active workspaces remain. Supports dispatched workspaces on sachi so kazuki can later pull the default branch instead of returning agents.
---

# Merge, push, and archive

Use this skill when the user wants completed work delivered through Git rather than returning its workspace to kazuki. Invoke with `/skill:merge-push-and-archive` in the workspace to finish. Invocation authorizes task commits, the default-branch merge and normal push, current-workspace archival, and removal of its empty Paseo project registration without another routine confirmation. Creating or editing this skill does not invoke it or authorize delivering the current task.

For a dispatched run on sachi, this explicit invocation overrides the e2e-feature home-host delivery restriction for this delivery only. It does not authorize unrelated work, bypass required checks or pending approvals, resume user-paused tasks, or deliver other workspaces. Do not infer permission merely because an agent has become idle. If follow-up work remains, finish it first or report the blocker and preserve the workspace.

Read [merge-and-archive](../merge-and-archive/SKILL.md) for source/workspace identification, preservation, commit, verification, and integration rules, and use the `paseo` skill for CLI/tool reference. Apply the additional requirements below. The cleanup sequence here replaces merge-and-archive's requirement that archival be the final mutating operation: a detached one-shot cleanup job may subsequently delete the verified empty project registration.

## 1. Identify and preserve the workspace

- Resolve the current agent from `PASEO_AGENT_ID`, its exact workspace ID, canonical Git source root, persistent common Git directory, owning project ID and registered path, source branch, and task. Include background workspaces in inventory. Never choose a project by display name: dispatched projects can share the same heading.
- Establish that no follow-up remains and every required review, unit check, verification, and applicable E2E journey has passed. E2E tests may run on sachi. A merge or push alone does not introduce a new E2E requirement.
- Inspect other tabs, descendants, terminals, scripts, Git operations, tracked changes, untracked files, submodules, and valuable ignored files. Resolve active writers and preserve valuable local-only files outside the owned worktree before cleanup. Do not silently interrupt unrelated tasks or force-add ignored files or secrets.
- Record the dedicated dispatch ID and original kazuki checkout, when applicable, from the matching handoff/dispatch record. Preserve dispatch records, handoffs, Git snapshot refs, the persistent transfer repository, and the original kazuki checkout. This flow does not return agents or overwrite that retained checkout.

## 2. Resolve the original remote and default branch

A dedicated transfer repository may have no remote configured. Inspect its remotes and the matching dispatch record's `origin` and original repository identity. The upstream for delivery must be the original project's intended writable repository, not the kazuki SSH transfer path, an unrelated same-named project, or a fork's upstream remote.

If no remote exists and the original origin URL is unambiguously established from that record, configure `origin` with that URL. If an existing remote disagrees, or the URL/default branch is ambiguous, stop and ask for the intended repository rather than replacing it. Never print credentials embedded in URLs.

Query the chosen remote's advertised HEAD with `git ls-remote --symref <remote> HEAD`; discover the default branch rather than assuming `main`. Fetch its default branch. Remote access and push authentication must work for this flow; offline local delivery is insufficient.

Use a clean integration worktree outside the workspace being archived, backed by the persistent common repository. Reuse a clean checkout already holding the local default branch where appropriate. Initialize a missing local default from the fetched remote default. Fast-forward an existing local default when behind; if it and the remote default diverged, stop rather than resetting, rebasing, or overwriting either history. Inspect local default commits ahead of remote and ensure they belong to the intended delivery before pushing.

## 3. Commit, merge, and verify the remote result

1. Review and commit all remaining task-owned changes with a descriptive message you generate. Stage explicit paths. Preserve unrelated edits and stop before cleanup if they would otherwise be lost. Require a clean source and record its immutable source SHA; preserve detached work with a local branch.
2. Merge that source SHA into the clean default-branch checkout using a fast-forward or ordinary merge. Follow the conflict recovery and required checks from merge-and-archive. Never force-update refs or force-push. If integration changes tested content, rerun affected verification against the integrated result.
3. Record the integrated SHA and verify the source SHA is its ancestor, the integration checkout is clean, and no Git operation remains. Push the explicit default-branch ref normally: `git push <remote> refs/heads/<default>:refs/heads/<default>`. Do not push unrelated branches or tags.
4. Fetch the remote default again and verify it contains the integrated SHA with `git merge-base --is-ancestor <integrated-sha> <fetched-remote-default>`. An equal remote tip or a newer tip containing the integration is acceptable. A rejected push, inaccessible remote, or failed ancestry check blocks cleanup; retain the workspace and report the exact remaining step.
5. Recheck the source SHA, clean source status, ignored-file preservation, and absence of new writers immediately before cleanup. If the source changed, integrate and push those changes and reverify first. Remove only clean temporary integration worktrees this invocation created; keep the persistent repository and branch refs.

## 4. Archive, then delete the project only when empty

Archiving the invoking workspace can kill this agent. Prepare cleanup before invoking it; do not rely on running another tool call after self-archival.

Create a bounded one-shot cleanup script and durable receipt/log directory outside both the source workspace and its project deletion scope, for example under `~/.local/state/workspace-delivery/<unique-id>/`. Record the source/workspace/project identities, chosen remote without credentials, source and integrated SHAs, verified remote tip, checks, backup locations, and dispatch ID. Do not store credentials in the script, arguments, or log.

The script must:

1. Revalidate the exact source path, workspace ID, owning project ID, source SHA and cleanliness, preserved files, and verified Git ancestry. Keep the same explicit Paseo daemon endpoint/home as the inspected workspace; use absolute executable paths or the established Nix environment. Fail closed if identity or repository state changed.
2. Archive exactly that workspace with `paseo workspace archive <workspace-id> --json`, from a surviving directory outside it. Require a successful response and confirm it is no longer active. On failure, record the failure and stop without deleting a project.
3. Re-list all active workspaces, including background workspaces, on the same daemon. Identify their owning projects by exact project ID, never display heading. If the CLI omits project IDs, resolve the descriptors through supported Paseo tools/API or compare canonical registered paths and common Git directories for every candidate; if ownership cannot be proved, retain the project.
4. If any other active workspace belongs to the recorded project, retain the project and record why. Otherwise recheck the project identity/path and fresh workspace inventory immediately before `paseo project delete <project-id> --json`. The CLI deletes a project's workspaces too, so never use it without the empty-project check. If another workspace appears or concurrent creation is detected, retain the project. Delete only the registration; never recursively delete repository directories, dispatch records, snapshots, or the retained kazuki checkout.
5. Write durable step results and errors. If project deletion fails, leave the pushed work and archived workspace intact, record that the project remains, and do not undo delivery. A retry must inspect existing state before repeating cleanup.

Launch the prepared cleanup script with a detached transient user unit (`systemd-run --user --collect`, a unique unit name, and a surviving working directory), so workspace archival cannot kill it. The helper performs only the reviewed cleanup steps; it is not another agent, a recurring service, or a general scheduler. If reliable detached execution is unavailable, preserve the workspace and report the cleanup blocker instead of relying on a shell background process tied to this tab.

Before launching, report the source SHA, default branch, integrated/verified remote SHAs, passing checks, exact workspace/project IDs, and durable receipt location. Explain that cleanup is about to run and that the project will remain if another workspace uses it. If this agent survives, inspect the unit and receipt and report actual results. Do not claim archival or project deletion succeeded merely because the cleanup job launched.

## Kazuki afterward

Report the repository and actual default branch that received the push. Kazuki can later fetch and fast-forward a clean checkout of that branch, typically with `git pull --ff-only` in its ordinary main checkout. Do not run that pull, modify kazuki's retained feature checkout, or start replacement agents unless separately requested. Preserve delivery receipts and dispatch recovery state; do not falsely mark the workspace as returned. Dispatcher status may still show its archived away record, which is not evidence of an active replacement tab.
