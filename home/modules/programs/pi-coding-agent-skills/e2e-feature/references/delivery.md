## Merge into the default branch

Unless the user explicitly asked not to merge, proceed automatically after all required work and checks are complete. Use `<default branch>` as the target in every step below (even when the worktree's recorded `<base>` differs):

1. **Update from the default branch.** With a clean tree, run `git merge <default branch>` on `<branch>`. When the default branch tracks a remote, run `git fetch` first and merge the remote-tracking ref. Resolve conflicts in `<worktree>`: trivial ones yourself, substantive ones through a `worker`, and ask the user when a conflict changes behavior. If the merge brought in changes, rerun the plan's Test and verification checks. Rerun the e2e journey only when this run adds a new feature and the E2E phase is required; merging, pushing, or deploying alone does not introduce an E2E requirement.
2. **Find the target checkout.** Find the worktree that has `<default branch>` checked out with `git worktree list --porcelain`; usually that is `<repo root>`. Merge only if `git -C <target> status --porcelain` is empty. Otherwise ask the user; never stash, reset, or discard work in their checkout. If `<default branch>` is not checked out anywhere, merge in `<worktree>` itself: check out `<default branch>`, merge, then check out `<branch>` again, as Paseo does.
3. **Merge to the default branch.** Run `git -C <target> merge <branch>`. Squash only when `AGENTS.md` or the user asks for it: `git -C <target> merge --squash <branch>`, then `git -C <target> commit -m "Squash merge <branch> into <default branch>"`. If the merge conflicts, run `git -C <target> merge --abort` and go back to step 1.
4. **Confirm.** `git -C <target> log --oneline -n 20 <default branch>` shows the feature commits or the squash commit. Push only when the user asked for it.
## Clean up the worktree

In Paseo, cleanup means archiving the workspace. Archiving runs the teardown commands from the project's `paseo.json`, force-removes the Paseo-owned worktree with `git worktree remove --force`, prunes it, and archives every agent and terminal in the workspace. It keeps the branch.

Because the removal is forced, archive only after the branch is merged, or after the user explicitly says to discard it, and only once `git status` is clean, so nothing uncommitted is lost. If the user chose to keep the branch, leave the workspace in place and say so.

1. Confirm every worker and the design tab are archived, and tear down any test environment the e2e instructions started.
2. You run inside this workspace, so archiving it stops you too. Deliver your final report first. Then tell the user to archive the workspace from Paseo, from the workspace's Archive action in the sidebar. If they ask you to do it, run `paseo workspace archive <workspace id>` as your very last command.
3. Paseo leaves `<branch>` in place. Delete it only when the user asks: `git -C <repo root> branch -d <branch>`, which refuses unmerged work.

For a subagent or Paseo infrastructure failure, preserve the exact error and the Git and worktree state, and use the tool's supported recovery path before retrying. Beyond the pi-subagents workflow scripts described here, do not build custom scripts, schedulers, daemons, or automatic production changes. This workflow handles one feature at a time and stops when recovery makes no progress.
