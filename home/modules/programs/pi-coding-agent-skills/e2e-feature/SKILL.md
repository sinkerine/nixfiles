---
name: e2e-feature
description: "Opt-in end-to-end feature workflow: a high-reasoning Claude design tab in Paseo (Pi GPT Astra on Claude quota exhaustion) that hands the plan back, Pi-sol implementation subagents, Pi-astra review loops, and an AGENTS.md-driven e2e check."
disable-model-invocation: true
---

# End-to-end feature workflow

Use this workflow only when the user explicitly invokes `/skill:e2e-feature <request>`. Do not activate it for ordinary requests. This skill authorizes subagent delegation; enable the `subagent` tool if it is not loaded yet.

You are the orchestrator, running on whatever model this session already uses; do not switch it. You coordinate four phases (design, implement, review, e2e test) and do not write feature code yourself, except for trivial integration fixes that you record as rulings.

Stop and ask the user, with `ask_user`, only for: a destructive or irreversible operation, a security-sensitive action, a side effect outside the worktree, a request so ambiguous that every path forward is a guess, or a gate this skill names. Decide everything else yourself, record it as `Ruling: <decision> — <why> — <cost if wrong>`, and keep going.

## Preflight

1. Pick a short, lowercase feature slug `<feature>`.
2. Confirm you are running in a Paseo worktree workspace and record its details, as described in Feature worktree. Stop there if you are not.
3. Read the project-level `AGENTS.md` in `<worktree>` and classify its e2e status:
   - **instructions**: it explains how to run an end-to-end test of a feature in a sandbox, such as a VM, a container, a disposable environment, or a local stack;
   - **not needed**: it explicitly says e2e testing is not needed for this repository;
   - **missing**: neither of the above, including when there is no `AGENTS.md`.
   When the status is missing, tell the user now, together with the design handoff below, so they can fix it while the design is underway. The gate is enforced in the e2e phase.
4. Create the workflow mission described in Workflow layout and record its id.

## Feature worktree

The user creates the isolated worktree in Paseo before invoking this skill: **New workspace → Isolation: New worktree**, or the project's **New worktree** button in the sidebar. Paseo places it under `~/.paseo/worktrees/<project hash>/<slug>` and records its base. You never create worktrees yourself; all feature work, including the plan, implementation, commits, verification, and e2e runs, happens in that worktree.

Verify and record it during preflight:

- `<worktree>` is `git rev-parse --show-toplevel` from your working directory. It is Paseo-owned when it lives under `~/.paseo/worktrees/` and `$(git rev-parse --git-dir)/paseo/worktree.json` exists.
- `<base>` is the `baseRef` field of that `worktree.json`, or `baseRefName` when `baseRef` is absent. This is the branch Paseo merges back into.
- `<workspace id>` is the entry in `paseo workspace ls --json` whose `cwd` is `<worktree>`.
- `<repo root>` is the main checkout: the first `worktree` entry of `git worktree list --porcelain`.
- The base commit is `git merge-base HEAD <base>`.
- `<branch>` is the current branch. Paseo may rename a placeholder branch after the first agent prompt, so read it again with `git branch --show-current` whenever you need it, not only once.

If your working directory is not a Paseo-owned worktree, for example the main checkout or a local workspace, stop before doing anything else. Ask the user, with `ask_user`, to create a worktree workspace in Paseo and invoke the skill again from an agent in it.

Never edit `<repo root>`. Set `cwd: "<worktree>"` on every `subagent` launch. Paths in this skill such as `docs/features/<feature>-plan.md` and `AGENTS.md` are relative to `<worktree>`.

Commit as the work is accepted, on `<branch>` only:

- the approved plan, as `<feature>: add plan`;
- each task once it is accepted, as `<feature>: <task id> <task title>`;
- each e2e repair, as `<feature>: fix <what>`.

Commit only the files the step changed. Keep generated artifacts and secrets out. Never commit to `<base>` directly.
## Workflow layout

Keep cohesive work in one task. Split tasks only when they have clearly separate logical responsibilities or module boundaries and can be implemented and reviewed meaningfully on their own. Do not split merely by file, implementation step, or to create more parallel work; keep tightly coupled implementation, wiring, and tests together. A single task and a single wave are valid for a cohesive feature. Apply this rule both during design and when revising tasks after a blocker.

Every subagent this workflow launches is a direct child of you; workers and reviewers never get the `subagent` tool, so agent depth is always one. Task dependencies decide launch order only. They form a graph, not a tree, so never express them as nesting.

Group the run as one Workflow row with one row per task:

- **Workflow row.** Create one mission before the first launch with `subagent({ action: "mission.create", mission: { title: "e2e-feature: <feature>", objective: "<one-line goal>" } })`, and pass its `missionId` to every later launch so all children collect under it.
- **Task rows.** Launch each child through `workflowScript` with `runs.run(key, { label, phase, agent, task })`. Always set `phase` to the task id from the plan; it is what nests a run under its task row, and a run without it shows flat under the Workflow row. The key is stable and lowercase, `<task>-<step>`; the label is `<task> · <step>`, where `<step>` is `implement`, `review rN`, or `fix rN`. Use `e2e` as the task id for e2e repair work. For example, the second review of T3 is `runs.run("t3-review-r2", { label: "T3 · review r2", phase: "T3", agent: "reviewer", task })`. When a script launches several tasks from a list, set `phase: item.id` on each run.
- **Subtitles, not nesting.** Put a task's wave and dependencies in its row summary, such as `wave 2 · after T1, T2`, with its state: `pending`, `implementing`, `review rN`, `fix rN`, `accepted (N rounds)`, or `needs human`.

Whenever you report progress to the user, use this layout. List accepted tasks on one line each and expand only the tasks still in progress:

```
Workflow: e2e-feature: <feature>
├─ Design (Claude / Pi GPT Astra tab)      ✓ plan approved
├─ T1 · wave 1                             ✓ accepted (2 rounds)
├─ T2 · wave 1                             ✓ accepted (1 round)
├─ T3 · wave 2 · after T1, T2              ⟳ review r2
│   ├─ implement                           ✓ unit test passing
│   ├─ review r1                           ✗ 1 Important
│   ├─ fix r1                              ✓ unit test passing
│   └─ review r2                           ⟳ running
├─ T4 · wave 2 · after T1                  ⟳ implementing
│   └─ implement                           ⟳ running
├─ T5 · wave 3 · after T3, T4              · pending
└─ E2E                                     · pending
```

## Design

Read `$PASEO_AGENT_ID`; it is your own Paseo agent id, and the design tab uses it to hand the plan back to you. If it is empty, you are not running inside Paseo: drop the handoff paragraph from the brief and wait for the user to tell you the plan is ready instead.

Create a new, independent, user-facing Paseo agent for design, using the Paseo `Claude` agent profile's settings but overriding thinking to `high`. Both Claude and the Pi GPT Astra fallback must use high reasoning. Do not use a Pi subagent, agent-scoped MCP creation, or a create-then-detach sequence for this phase. A plain agent-originated `paseo run` inherits parentage through `PASEO_AGENT_ID`; `--workspace` controls placement but does not remove parentage.

First capture the orchestrator's agent ID for the brief's explicit `PLAN_READY` handoff. The design agent goes in the same worktree workspace as you, `<workspace id>`. Then unset `PASEO_AGENT_ID` only for the design launch command with `env -u`, and pass the existing workspace explicitly. Keep the orchestrator's own environment and the daemon connection settings unchanged. This workflow explicitly authorizes creating the design session as a top-level agent:

```bash
env -u PASEO_AGENT_ID paseo run --no-wait --json \
  --provider claude/claude-opus-5-5 --thinking high --mode bypassPermissions \
  --workspace <workspace id> \
  --cwd <worktree> --title "Design: <feature>" \
  "$(cat <brief file>)"
```

Capture the returned agent ID and run `paseo inspect <design agent id> --json`. Require `ParentAgentId` to be `null`, and verify through Paseo's agent/workspace metadata that the agent belongs to the intended workspace. If either check fails, preserve the launch output and exact state and report the infrastructure blocker; do not silently proceed with a subagent or create duplicate design sessions.

### Claude quota fallback

If Claude is already known to be out of quota, launch Pi GPT Astra directly instead. If the Claude design launch or a later design turn reports quota exhaustion or a usage limit that blocks design, replace that design tab with Pi GPT Astra automatically; do not wait for a quota reset or ask the user to approve the substitution. This exception applies only to Claude quota exhaustion, not unrelated launch or infrastructure failures.

Before replacing an existing Claude tab, preserve its agent ID, exact quota error, and any available design context. Prepare a replacement brief containing the original brief, the current plan file if present, and the design decisions, unresolved questions, and approval status available from the Claude session. Archive the blocked Claude agent with `paseo archive <old design agent id>` before launching the replacement, so only one design tab remains active. If Claude never created an agent, skip the archive step.

Launch the replacement as an independent agent in the same workspace and worktree, keeping the original title and orchestrator's `PLAN_READY` handoff:

```bash
env -u PASEO_AGENT_ID paseo run --no-wait --json \
  --provider pi/magpie/group/astra --thinking high \
  --workspace <workspace id> \
  --cwd <worktree> --title "Design: <feature>" \
  "$(cat <replacement brief file>)"
```

Apply the same independence and workspace checks to the replacement, then record its ID as the current design agent ID for all later messages and cleanup. Tell the user Claude exhausted its quota and the design tab now uses Pi GPT Astra with high reasoning. Continue the existing design and approval process from the preserved context; replacing the tab does not approve the plan. If the fallback fails, preserve the exact error and report the blocker rather than repeatedly creating agents.

### Design brief and handoff

The independent agent should be available in the workspace's agent list. Do not claim it is open or focused in the user's client merely because creation succeeded. `paseo agent open` is optional and requires a Desktop installation on the CLI machine; its failure on a remote or headless host does not invalidate the independent agent. Do not install Desktop or change daemon configuration to focus a tab.

Write the brief to a temporary file first. It contains the user's request, what you learned in preflight, and these instructions:

> You are the design agent for this feature. You work in the feature worktree `<worktree>` on branch `<branch>`; do not edit anything outside it. Work with the user in this tab to design it, exploring the code as needed. Do not implement the feature or commit. The outcome of this session is one file, `<worktree>/docs/features/<feature>-plan.md`, which you keep up to date as the design evolves. It must contain these sections:
> - **Goal and acceptance criteria**: target behavior and measurable criteria.
> - **Design**: implementation details, including module boundaries, data flow, interfaces with exact signatures, error handling, and the conventions to follow.
> - **Tasks**: keep cohesive work in one task; split only at clearly separate logical responsibilities or module boundaries that can be implemented and reviewed meaningfully on their own. Do not split merely by file, implementation step, or to increase parallelism. Keep tightly coupled implementation, wiring, and tests together; one task in one wave is valid. For each task, include an id, its goal, the files it owns, the interfaces it consumes and produces, its dependencies on other task ids, and the unit test command that proves it is done. Group tasks into ordered waves; tasks in the same wave have no dependencies on each other, touch disjoint files, and can run in parallel.
> - **Test and verification**: the unit, integration, lint, type, and build checks for the whole feature.
> - **E2E journey**: the user journey that proves the feature works end to end, written as steps with expected results.
>
> When the user approves the plan, save the final file and hand it to the orchestrator by running exactly this command; `--no-wait` matters, because the orchestrator's turn lasts the whole implementation:
>
> `paseo send <orchestrator agent id> --no-wait --prompt "PLAN_READY <worktree>/docs/features/<feature>-plan.md: approved by the user. <one-line summary and any open notes>"`
>
> Then tell the user the plan has been handed off. If the orchestrator later sends you questions about the plan, update the file and send `PLAN_READY` again.

Record the design agent's ID and workspace ID after verifying independence and placement. Tell the user the independent `Design: <feature>` agent is available in that workspace's agent list, to open it and work out the plan there, and that it will hand the plan back to you when they approve it. Then end your turn. Do not poll the tab. On a notification or user report that Claude is blocked by quota exhaustion, apply the Claude quota fallback above and hand the replacement tab back to the user. Otherwise ignore turn-finished notifications from the design tab; continue into implementation only on a `PLAN_READY` message or when the user tells you the plan is ready.

When the plan arrives:

1. Read `<worktree>/docs/features/<feature>-plan.md`. If it is missing, ask the design tab to write it with `paseo send <design agent id> --no-wait --prompt "..."` and end your turn.
2. Check that every section is present, every task has a unit test command, the dependency graph has no cycles, and task boundaries follow the cohesion rule in Workflow layout. Send gaps or unnecessary task splits back to the design tab the same way, or ask the user if a gap needs their decision.
3. When the plan is complete, commit it on `<branch>`, archive the design tab with `paseo archive <design agent id>`, and proceed straight into implementation without waiting for further confirmation.

## Implement

Work through the waves in order. Inside a wave, launch one `worker` subagent per task in parallel, using model `magpie/gpt-6.1-sol` (thinking `medium`; `high` for a task the plan marks as subtle, or after a failed attempt). Every worker runs with `cwd: "<worktree>"`. Run tasks in parallel in the feature worktree only when the plan says their files are disjoint. Otherwise run them one after another, or use pi-subagents' worktree isolation from `<worktree>` and merge each result back onto `<branch>` yourself; that isolation needs a clean tree, so commit accepted tasks first.

Give each worker only its own brief, not the session history: the task entry from the plan, the relevant parts of the Design section, the interfaces it depends on, the unit test command, and the absolute path `<worktree>`. Require it to:

- work only inside `<worktree>`, and not commit;
- implement the task and add or update its unit test;
- keep iterating until that unit test passes;
- finish with exactly one status, `DONE`, `DONE_WITH_CONCERNS`, `NEEDS_CONTEXT`, or `BLOCKED`, followed by the files it changed and the last test output.

When a worker reports `DONE`, rerun its unit test yourself in `<worktree>`. A worker's success message is not evidence. On `NEEDS_CONTEXT` or `BLOCKED`, change something before relaunching it: add context or raise thinking; split the task only if it has clearly separate logical responsibilities or module boundaries, following Workflow layout. A task starts only when every task it depends on has passed review.

## Review

Start reviewing a task as soon as its implementation passes its unit test; do not wait for the rest of its wave. Reviews of different tasks run in parallel.

For each task, run up to 3 rounds of review, then fix, then test:

1. **Review.** Launch a `reviewer` subagent; it is configured to run on `magpie/group/astra` with `high` thinking. A failed launch does not count as a review round. Give it the task entry, the acceptance criteria, the task's diff in `<worktree>`, and the unit test command, and launch it with `cwd: "<worktree>"`. Ask for findings ranked Critical, Important, or Minor, each with location, evidence, and the smallest fix. Check each finding against the code yourself and reject wrong ones with your reasoning.
2. **Fix.** If any Critical or Important findings remain, launch a `worker` on `magpie/gpt-6.1-sol` with those findings, their root causes, and the expected fixes.
3. **Test.** Rerun the task's unit test yourself, along with any checks the fix could affect.

The task is accepted when a review round has no Critical or Important findings and the test passes. Commit it then, as described in Feature worktree. Carry Minor findings to the delivery report. If Critical or Important findings remain after the third round, stop work on that task and ask the user with `ask_user`. Include the open findings, what each round tried, and the current test output. Do not run a fourth round without their answer.

After all tasks are accepted, run the plan's full Test and verification checks yourself. Evidence must come from a run made after the last edit.

## E2E test

Re-read the project-level `AGENTS.md` in `<worktree>`, because the user may have changed it since preflight.

- **missing**: ask the user with `ask_user` to either add instructions to `AGENTS.md` on how to test a feature end to end in a sandbox, or add a note to `AGENTS.md` that e2e testing is not needed for this repository. Wait for their answer, then re-read the file. Do not deliver while the status is still missing.
- **not needed**: skip this phase and record that in the report.
- **instructions**: follow them from `<worktree>`, so the sandbox runs the feature branch, to bring up the sandbox and walk through the plan's E2E journey step by step. Check each step's actual result against the expected result and keep the evidence: commands, output, screenshots, or logs. When a step fails, reproduce it, state the root cause, and send the fix to a `worker` on `magpie/gpt-6.1-sol`. Then rerun the affected unit tests and the journey. Allow at most three repair attempts, then ask the user. Tear the sandbox down when the instructions say to.

## Deliver

Inspect the final diff with `git diff <base commit>...HEAD` and confirm `git status` is clean. Report the changed files and behavior, the commits on `<branch>`, each task with its review rounds, verification and e2e evidence, rulings made, deferred Minor findings, and unresolved risks. Never claim completion while required checks remain unverified.

Then ask the user with `ask_user` whether to merge `<branch>` into `<base>` now, keep the branch for later, or open a PR instead. Merge, push, or open a PR only on their answer, or when repository policy in `AGENTS.md` says what to do. The user can also do the merge from the workspace's Git actions in Paseo; the steps below do the same thing.
## Merge into the base branch

Follow Paseo's own merge-from-base and merge-to-base behavior:

1. **Update from base.** With a clean tree, run `git merge <base>` on `<branch>`; Paseo merges base in rather than rebasing. When the base tracks a remote, run `git fetch` first and merge the remote-tracking ref. Resolve conflicts in `<worktree>`: trivial ones yourself, substantive ones through a `worker`, and ask the user when a conflict changes behavior. If the merge brought in changes, rerun the plan's Test and verification checks and the e2e journey.
2. **Find the target checkout.** Find the worktree that has `<base>` checked out with `git worktree list --porcelain`; usually that is `<repo root>`. Merge only if `git -C <target> status --porcelain` is empty. Otherwise ask the user; never stash, reset, or discard work in their checkout. If `<base>` is not checked out anywhere, merge in `<worktree>` itself: check out `<base>`, merge, then check out `<branch>` again, as Paseo does.
3. **Merge to base.** Run `git -C <target> merge <branch>`; this is Paseo's default merge strategy. Squash only when `AGENTS.md` or the user asks for it: `git -C <target> merge --squash <branch>`, then `git -C <target> commit -m "Squash merge <branch> into <base>"`. If the merge conflicts, run `git -C <target> merge --abort` and go back to step 1.
4. **Confirm.** `git -C <target> log --oneline -n 20 <base>` shows the feature commits or the squash commit. Push only when the user asked for it.
## Clean up the worktree

In Paseo, cleanup means archiving the workspace. Archiving runs the teardown commands from the project's `paseo.json`, force-removes the Paseo-owned worktree with `git worktree remove --force`, prunes it, and archives every agent and terminal in the workspace. It keeps the branch.

Because the removal is forced, archive only after the branch is merged, or after the user explicitly says to discard it, and only once `git status` is clean, so nothing uncommitted is lost. If the user chose to keep the branch, leave the workspace in place and say so.

1. Confirm every worker and the design tab are archived, and tear down any sandbox the e2e instructions started.
2. You run inside this workspace, so archiving it stops you too. Deliver your final report first. Then tell the user to archive the workspace from Paseo, from the workspace's Archive action in the sidebar. If they ask you to do it, run `paseo workspace archive <workspace id>` as your very last command.
3. Paseo leaves `<branch>` in place. Delete it only when the user asks: `git -C <repo root> branch -d <branch>`, which refuses unmerged work.

For a subagent or Paseo infrastructure failure, preserve the exact error and the Git and worktree state, and use the tool's supported recovery path before retrying. Do not build custom workflow scripts, schedulers, daemons, or automatic production changes. This workflow handles one feature at a time and stops when recovery makes no progress.
