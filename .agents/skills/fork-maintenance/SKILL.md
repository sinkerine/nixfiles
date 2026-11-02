---
name: fork-maintenance
description: "Maintain the user's reviewed Paseo forks: inventory new projects for review, create fresh local workspaces on fork default branches, merge original upstream while preserving customizations, run unit and E2E regressions, install through Nix, sachi Docker, agent-sachi Hermes, or Android, and archive only this run's workspaces. Use for requests to sync/update maintained forks or review the fork project registry."
---

# Maintain forked projects

Read `/nixfiles/forked-projects.md` first. It defines the maintained projects, exclusions, targets, dependency order, and admission policy. Read `references/platforms.md` for testing and installation recipes. Use the `paseo` skill for the current workspace tools/CLI. Recheck each project's own `AGENTS.md`, development/test docs, and release skills at execution time.

Creating or editing this skill does not invoke maintenance. A request to run the complete workflow authorizes clean upstream integration, necessary regression fixes, ordinary commits and non-forced pushes to the reviewed forks, installation to their recorded targets, routine service restarts, and cleanup of this invocation's resources. Respect narrower instructions, existing approvals, and repository-specific restrictions. Never infer approval to add unrelated projects, publish public releases, change signing identities, migrate installation ownership, delete data, or rewrite published history.

## 1. Discover scope and prepare a run record

1. Inspect `hostname`, `/nixfiles` status, and `paseo project ls --json`. Use the calling daemon's registry; do not enumerate remote daemons unless requested or already in the reviewed set. Refresh GitHub metadata for fork and upstream identity and default branches. Resolve repository redirects by canonical name/ID rather than URL spelling.
2. Compare the live projects with every maintained/excluded entry in the registry. Follow its admission policy for unknown projects. Registration in Paseo or having a Docker container does not approve maintenance. For candidates, gather a concrete proposed category, target, tests, and install recipe before asking the user, using `ask_user` and the `ask-user` skill when available. Keep pending candidates out of execution. Work on independent approved entries can continue.
3. Select explicitly requested projects; “all forks” means the maintained entries only. Include required SDK dependencies when updating Element X and report the chain. If upstream and deployed revisions are already current, record a no-op; do not rebuild or restart needlessly.
4. Create a durable run directory outside project workspaces, for example `/home/sinkerine/.local/state/fork-maintenance/<UTC-timestamp>/`. Record the selected projects, fork/upstream defaults and SHAs, original checkout state, workspace IDs created by this run, pre-existing workspace IDs, deployment baseline/rollback handles, test commands/results, log paths, installation evidence, and per-project status. Never store credentials or entire environment/config dumps. Maintain the record after every stage so an interrupted run can resume without duplicate work or deployment.
5. Inspect existing workspaces including background workspaces, active agents, Git status, worktrees, in-progress merges, and local/remote divergence. A local workspace shares its checkout with all other local workspaces; a new Paseo record does not isolate files. Permit only one writer per checkout. Leave dirty/busy checkouts untouched and continue independent projects. Do not stash, reset, clean, abort somebody else's merge, switch a checkout under another agent, or sweep unpushed user commits into a maintenance push.

This workflow does not require delegated agents. Delegate only when the user has requested delegation or applicable instructions explicitly authorize it; read profiles and the relevant delegation skill first. Parallel projects need distinct checkouts and resource budgets. Do not run concurrent builds/activations against one deployment target.

## 2. Create a fresh local workspace on the fork default

Always use `isolation: "local"`, as requested. Resolve the fork default from live forge metadata, not the current branch or cached `origin/HEAD`. Resolve the original upstream branch separately. Element X currently uses `develop` for both the fork default and upstream branch.

Prefer the registered project checkout when it is clean, has no other writer, and its local fork default has no unexpected unpushed commits. Fetch the verified fork remote. Switch to its default branch and fast-forward only from the fork. If ahead/diverged, preserve the checkout and use a clean clone of the fork default for the remote maintenance set, or ask when local work is required for the requested result. Explicitly report any local changes excluded by using a clone. A second local workspace alone does not fix checkout contention.

For a dirty, busy, or otherwise unsuitable checkout, create a separate durable clone under `/home/sinkerine/dev/fork-maintenance/<run-id>/<project>`:

```sh
git clone --single-branch --branch <fork-default> <verified-fork-url> <run-checkout>
```

Clone from the fork remote, not a dirty directory. This is a normal clone, not a Git worktree. Preserve project instructions from the tracked source and follow applicable parent instructions. Do not copy secrets, `node_modules`, or another checkout's build outputs. Use Nix development shells for build/test tools. Keep the run clone's branch on the fork default throughout integration.

Create a new Paseo local workspace owned by the existing project, using discovered values:

```sh
paseo workspace create --isolation local \
  --path <clean-checkout> --project <project-id> \
  --title "Upstream sync: <project> (<run-id>)" --json
```

Equivalent MCP: `create_workspace({isolation:"local", path:"<clean-checkout>", projectId:"<project-id>", title:"..."})`. Record the returned ID immediately and verify its isolation, path, project, and checked-out default branch. Omit background overrides unless requested. If Paseo returns a pre-existing workspace instead of creating a new one, do not label it run-owned or archive it; resolve placement before mutation. If a separate path cannot be associated with the existing project, inspect current CLI support and report the blocker rather than creating a duplicate registered project without a review decision.

## 3. Integrate original upstream and resolve conflicts

1. Verify `origin` resolves to the reviewed fork and the selected upstream remote resolves to the original repository. A remote called `upstream` may point at the fork. In a run-owned clone, add an unambiguous remote such as `maintenance-upstream` if needed; do not silently repoint existing remotes in the user's checkout.
2. Fetch the fork default and original upstream branch. Record `before`, fork SHA, upstream SHA, merge base, and fork-only changes. Understand the customizations and their regression coverage before merging.
3. Integrate with `git merge --no-edit <verified-upstream-remote>/<upstream-branch>` on the fork default. Preserve fork history; do not rebase or force-push as a routine sync. No merge is needed when the upstream SHA is already an ancestor. Follow a repository's explicit integration policy when compatible with preserving published commits; ask only if it requires an actual policy decision.
4. Resolve understood conflicts by reading both sides and relevant behavior. Preserve fork features while adopting upstream fixes. Never blanket-select ours/theirs, drop a patch because upstream refactored nearby code, or make a lockfile syntactically valid without regenerating it with the pinned package manager. Inspect semantic conflicts even after a clean merge, including prompts/config defaults, generated bindings, migrations, dependency hashes, and platform-specific behavior. Hermes explicitly requires a prompt audit on every sync.
5. Ask the user only when a conflict requires choosing product behavior, removing a customization, changing a target/permission, or accepting a data migration without a safe path. Present the competing behavior and concrete recommendation. Keep that project pending; do not call it complete. Resolve ordinary code conflicts autonomously.
6. Stage only intended conflict resolutions/fixes and finish the merge with a generated message. Preserve author history. Add focused behavior regressions where missing coverage would let a fork feature disappear; avoid tests that only mirror source text.

## 4. Require unit and E2E regression evidence

Construct the test selection from upstream changes, fork-only features, conflicts, affected dependencies, and project policy. Follow `references/platforms.md` and live repository instructions; record exact commands, tested SHA, runtime/platform, exit codes, and artifacts outside disposable workspaces.

- Run the affected unit/integration suites and relevant fork regressions, plus mandated lint/type/build checks. Use the repository's existing runners. Broad suites run in CI when project policy requires it; do not run Paseo's full suite locally.
- Run an end-to-end journey that exercises the affected installed behavior, with isolated state, synthetic data/accounts, and the built candidate. Include existing fork-specific UI journeys where relevant. Browser fixtures establish UI behavior only; supplement them with a real backend journey when the change crosses the API/runtime boundary.
- Establish whether failures predate the sync when needed. Fix introduced failures and rerun affected checks. Distinguish product failures, missing prerequisites, and flaky infrastructure; preserve failed evidence. Do not weaken assertions, regenerate unexplained screenshots, or remove fork coverage to get green.
- Missing credentials, emulator/KVM, fixtures, or infrastructure means **blocked**, never passed. Tests that find no cases are not a pass. Do not install when required unit/E2E checks are incomplete unless the user explicitly accepts the named exception. Continue other independent projects.
- Test the exact commit/artifact selected for deployment. Changes after tests invalidate affected evidence. Preserve reports, screenshots, artifact checksums and CI run URLs before cleanup.

For SDK plus Element X, Rust tests alone do not complete E2E: rebuild the Android SDK, update the consumer pin, and exercise Element X with that exact artifact. Keep this chain pending until both projects pass.

## 5. Publish and install on the recorded platform

Re-fetch the fork before pushing. Require the tested candidate to contain the current fork default; if it advanced, merge the new commits and rerun affected checks before an ordinary push. Verify the remote fork default now equals the tested SHA. Never force-push. Sync-only requests stop at their requested boundary.

Use `references/platforms.md` for each target. Installation must consume the tested SHA or an artifact proven to contain it. Capture the previous runtime revision/image/profile and a feasible rollback procedure before activation. Inspect migration compatibility before relying on rollback. Never delete volumes, user profiles, signing keys or application data. Report partial success per project and platform.

Install SDK artifacts before Element X; finish independent Docker/VM/Android work before restarting Paseo. Perform the Paseo activation/relaunch durably using `paseo-update`; reconnect and verify completion after daemon interruption rather than assuming the restart succeeded. A complete workflow invocation includes that routine restart; narrower requests do not.

A successful build or upload is not installation evidence. Verify running source/image/store paths or installed package version and certificate, service health and a read-only smoke check after activation. If activation fails, retain the workspace and rollback handles, restore the last known good runtime when safely possible within the approved target, and report what is running. Do not repeat failing activation blindly.

## 6. Clean up only this run's resources

1. Stop test servers/emulators and workspace scripts started by this run. Keep persistent user services running. Save the durable report and artifacts first.
2. Archive each successfully completed run-owned workspace by exact recorded ID with `paseo workspace archive <workspace-id> --json`. Failed or pending projects keep their workspaces for diagnosis unless the user requests cleanup after evidence is preserved. Never archive pre-existing workspaces or delete project registrations.
3. Local workspace archival keeps its directory. Preserve the registered checkout. Remove a temporary run clone only if this invocation created it, the worktree is clean, all resulting commits are reachable from the verified fork remote, artifacts are saved, and no active workspace/process references it. Limit removal to the exact recorded clone path; keep it if any condition is uncertain. Do not remove the run report directory.
4. Do orchestration from a workspace outside those being archived. If the current agent belongs to a cleanup target, persist and deliver the result before archiving it as the last action; do not terminate the orchestrator early.
5. Re-list workspaces and verify the run-owned completed IDs are archived and pre-existing IDs remain. Report retained workspaces and why.

Final report: list category/project, upstream and resulting fork SHA, unit/E2E outcome, installed revision/target or blocker, archived/retained workspace IDs, and durable evidence location. Call out pending new-project reviews and any accepted test exceptions. Do not claim all projects are updated when one dependency or platform remains pending.
