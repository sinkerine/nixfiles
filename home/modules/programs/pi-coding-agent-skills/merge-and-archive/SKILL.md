---
name: merge-and-archive
description: Commit the current worktree's task changes, merge them into the repository's local default branch, then archive the current Paseo workspace. Use when asked to merge and archive, finish a worktree and close its workspace, or explicitly invoke /skill:merge-and-archive.
---

# Merge and archive

Deliver the current worktree to the repository's local default branch, verify delivery, then archive exactly the current Paseo workspace. Invocation authorizes the task commit, local merge, and workspace archival without another routine confirmation. Push only when the user explicitly requests it. Creating or editing this skill does not invoke it.

Use the `paseo` skill for the current tool/CLI reference. Respect repository instructions and required checks. Preserve the source worktree and workspace whenever delivery fails or a prerequisite cannot be established. Do not reset, force-update refs, force-push, discard files, or remove worktrees manually.

## 1. Identify the source and workspace

Before changing anything:

- Record the canonical source root (`git rev-parse --show-toplevel`), common Git directory, source branch (or detached HEAD), and source commit. Inspect `git status --short`, staged and unstaged diffs, untracked files, submodule status, and `git worktree list --porcelain`.
- Resolve the invoking Paseo agent using `PASEO_AGENT_ID` and `get_agent_status`, then obtain its workspace descriptor from `list_workspaces` with `includeBackground: true`. Check that the workspace path resolves to the source root on this host. Use caller-scoped MCP tools; CLI fallback is `paseo workspace ls --background --json`, retaining the session's daemon connection environment. Never infer the workspace from its title or branch name alone. If agent identity is unavailable, an exact canonical path match must uniquely identify the current workspace; otherwise stop and ask which workspace to archive.
- Record the exact workspace ID and inspect its agents, terminals, and scripts. Archival stops all of them. If another agent is actively editing or a live process may still produce valuable changes, resolve that activity before committing; do not silently terminate another task.
- Check for a merge, rebase, cherry-pick, revert, or unresolved index already in progress. Stop for an unrelated unfinished operation. Preserve dirty submodules until their changes are safely committed in their own repositories and recorded in the parent.
- Inspect ignored files for valuable local-only work such as notes, data, or generated deliverables. Ordinary disposable build caches are fine. Paseo may delete an owned worktree during archival: preserve valuable files outside it or commit appropriate files before proceeding. Never blindly force-add ignored files or secrets.

If this is not a Git repository, or the current Paseo workspace cannot be established, stop before changing the repository.

## 2. Determine the default branch and destination

Use repository metadata rather than assuming `main` or `master`:

1. Identify the repository's primary remote from its configuration and project context, preferring `origin` when unambiguous. Do not accidentally target a fork's upstream remote instead of the repository's own remote.
2. Query its advertised HEAD with `git ls-remote --symref <remote> HEAD`. Fall back to an existing symbolic `refs/remotes/<remote>/HEAD` when the remote cannot be reached. With no remote, use explicit repository configuration/documentation. If evidence conflicts or no default can be established, ask rather than guessing.
3. Fetch the chosen remote's default branch when reachable. If it cannot be reached but a known local default exists, continue locally and report that remote freshness was not checked. Do not claim remote synchronization.
4. Find the worktree holding `refs/heads/<default>` using the porcelain worktree list. Require its index and working directory, including untracked files, to be clean. Do not stash or overwrite someone else's changes. If the branch is not checked out, create a temporary integration worktree outside the source workspace, using the local default ref or creating it from the fetched remote default when no local ref exists.
5. Ensure the integration checkout and repository's persistent common Git directory will survive archival. In particular, do not merge into a checkout that is inside a managed workspace about to be deleted, or use a repository whose only persistent storage would be deleted. If the source already holds the default branch, verify its commits there and require a persistent checkout/repository outside the deletion scope before archival; never remove the only surviving copy of the result.

When fetched remote default is ahead, fast-forward the local default with `git merge --ff-only <remote-default-ref>`. If local and remote default have diverged, stop and report the divergence rather than choosing a history policy. A local default already ahead is acceptable for a local merge.

## 3. Commit, check, and merge

- Review all pending changes and distinguish task work from unrelated user edits. Commit the task changes with a descriptive message you generate yourself. Include relevant new files, respect ignore rules, and never use an indiscriminate add when unrelated files are present. If unrelated valuable changes remain, preserve them and stop before archival rather than committing or deleting them as part of this task.
- Run checks required by the repository and appropriate to the change, reusing valid results from this session when the tested content is unchanged. Fix task-related failures before delivery. Do not bypass hooks or required checks. If the content changes during a fix, commit the fix and repeat affected checks.
- Require a clean source status, then record the final source SHA with `git rev-parse HEAD`. For a detached HEAD, create a uniquely named local preservation branch at that SHA before integration, so a failed attempt never leaves the work reachable only from a removable worktree.
- Recheck that the destination is clean and on the expected default branch. Merge the recorded immutable source SHA there with `git merge --no-edit <source-sha>`, allowing a fast-forward or normal merge as Git determines. Do not squash or rebase unless requested.
- If this merge conflicts, inspect the conflict and resolve only when the intended result is clear from the task and both sides. Run affected checks and finish the merge. If it cannot be resolved confidently, abort only the merge this invocation started, report the conflict, and leave the source workspace active. Never archive after a failed merge.
- If integration changes the tested content (for example the default branch has additional commits), run the relevant checks against the integrated result. Record the default branch tip and confirm `git merge-base --is-ancestor <source-sha> refs/heads/<default>` succeeds. Verify the destination is clean and no Git operation remains in progress.
- If pushing was explicitly requested, perform a normal push of the default branch and verify success before archival. On rejection or failure, keep the workspace and report that local delivery succeeded but the requested push did not.

## 4. Archive last

Immediately before archival, recheck all of these:

- The source still has the recorded source SHA and has no staged, unstaged, untracked, submodule, or valuable ignored changes that would be lost. If it changed, integrate those changes and reverify first.
- The source SHA is still an ancestor of the local default branch tip and that ref is held by the surviving repository.
- The current workspace ID still matches the same canonical source path on the same daemon, and no other task has started writing there.

Remove only a clean temporary integration worktree created by this invocation, after its result is held by the local default branch in persistent repository storage. Never delete the source branch or source worktree manually.

Report the source branch/SHA, default branch/tip, checks, and push status before archiving, because archiving this workspace can interrupt this agent. Then call `archive_workspace` with the verified `workspaceId` as the final mutating operation. CLI fallback: run `paseo workspace archive <workspace-id> --json` from a surviving directory outside the source worktree, retaining the same daemon connection settings.

Archival closes the workspace's agents and terminals; local directories remain, while a Paseo-owned worktree may be removed after its final active workspace reference is archived. Do not archive other workspaces or separately archive individual agents. Do not require further work inside the archived directory. If the call returns, check its result and report success only when confirmed. If archival fails, report that the merge succeeded and the workspace remains active; do not undo the merge. When retrying, first check whether archival already completed rather than repeating a failed lookup blindly.
