---
name: e2e-feature
description: "Opt-in end-to-end feature workflow: a high-reasoning Claude design tab in Paseo (Pi GPT Astra on Claude quota exhaustion) that hands the plan back, Pi-sol implementation subagents, Pi-astra review loops, and an AGENTS.md-driven e2e check."
disable-model-invocation: true
---

# End-to-end feature workflow

Use this workflow only when the user explicitly invokes `/skill:e2e-feature <request>`. Do not activate it for ordinary requests. This skill authorizes subagent delegation; enable the `subagent` tool if it is not loaded yet. `/skill:e2e-feature resume <handoff file>` continues a run that `e2e-dispatch` moved to this host: follow Resume after a host move instead of Preflight and Design.

You are the orchestrator, running on whatever model this session already uses; do not switch it. You coordinate four phases (design, implement, review, e2e test) and do not write feature code yourself, except for trivial integration fixes that you record as rulings.

This skill uses the Pi goal extension to execute the full approved plan. Invoking this skill explicitly authorizes creating a regular goal once the user approves the design. Design approval also approves that goal; do not run a second goal drafting or confirmation round. Keep the design handoff before goal creation so automatic goal continuation does not bypass the design approval gate.

Stop and ask the user, with `ask_user`, only for: a destructive or irreversible operation, a security-sensitive action, a side effect outside the worktree other than the default-branch merge authorized below, a request so ambiguous that every path forward is a guess, or a gate this skill names. Decide everything else yourself, record it as `Ruling: <decision> — <why> — <cost if wrong>`, and keep going.

## Preflight

1. Pick a short, lowercase feature slug `<feature>`.
2. Confirm the current directory belongs to a Git repository and inspect the current Paseo workspace and Git worktree metadata.
3. If the current workspace is already a Paseo-owned Git worktree, use it and record its details as described in Feature worktree.
4. Otherwise, automatically create a new Paseo worktree workspace for the current project before doing feature work. Use the project's current branch as the base unless the user specified another base, and a feature branch named `feat/<feature>`. Discover the project ID from the current workspace or Paseo project registry; create the workspace with `paseo workspace create --isolation worktree --mode branch-off --new-branch feat/<feature> --base <base> --project <project-id> --title "<feature>" --json`. If the installed CLI uses different flags, inspect `paseo workspace create --help` and use the equivalent supported options. Verify the returned workspace ID, worktree path, owning project, base ref, branch, and `paseo/worktree.json`. Since the current agent cannot change its working directory, launch a fresh orchestrator agent in that workspace with the original user request and `/skill:e2e-feature` invocation, then end this turn. The new agent resumes at preflight using the created workspace; do not create a second worktree. If the CLI cannot create or associate the worktree, preserve the exact error and report the blocker; do not fall back to editing the current checkout or ask the user to create it manually.
5. Read the project-level `AGENTS.md` in `<worktree>` and classify its e2e status:
   - **instructions**: it explains how to run an end-to-end test of a feature in a sandbox, such as a VM, a container, a disposable environment, or a local stack;
   - **not needed**: it explicitly says e2e testing is not needed for this repository;
   - **missing**: neither of the above, including when there is no `AGENTS.md`.
   When the status is missing, tell the user now, together with the design handoff below, so they can fix it while the design is underway. The gate is enforced in the e2e phase.
6. Create the workflow mission described in Workflow layout and record its id.

## Feature worktree

Use an existing Paseo-owned Git worktree when the skill is invoked from one. When invoked from a local workspace or the main checkout, create a new Paseo-owned Git worktree automatically during preflight as specified above. Paseo places it under `~/.paseo/worktrees/<project hash>/<slug>` and records its base. All feature work, including the plan, implementation, commits, verification, and E2E runs, happens in that isolated worktree.

Verify and record it during preflight:

- `<worktree>` is `git rev-parse --show-toplevel` from your working directory. It is Paseo-owned when it lives under `~/.paseo/worktrees/` and `$(git rev-parse --git-dir)/paseo/worktree.json` exists.
- `<base>` is the `baseRef` field of that `worktree.json`, or `baseRefName` when `baseRef` is absent. This is the branch Paseo merges back into.
- `<workspace id>` is the entry in `paseo workspace ls --json` whose `cwd` is `<worktree>`.
- `<repo root>` is the main checkout: the first `worktree` entry of `git worktree list --porcelain`.
- The base commit is `git merge-base HEAD <base>`.
- `<branch>` is the current branch. Paseo may rename a placeholder branch after the first agent prompt, so read it again with `git branch --show-current` whenever you need it, not only once.
- `<git dir>` is `git rev-parse --absolute-git-dir`, this worktree's own Git directory, outside the tracked tree. Create `<run dir>` as `<git dir>/e2e-feature/<feature>` for briefs, findings, diffs, and E2E evidence. `<build lock>` is `<git dir>/e2e-feature-build.lock`; concurrent workers run builds and tests under it.
- Write `<run dir>/snap.sh`, which prints a tree id for the given paths (tracked and untracked, honoring `.gitignore`) without touching the index or the working tree:

  ```sh
  idx=$(mktemp -u) && GIT_INDEX_FILE=$idx git read-tree HEAD && GIT_INDEX_FILE=$idx git add -A -- "$@" && GIT_INDEX_FILE=$idx git write-tree; status=$?; rm -f "$idx"; exit $status
  ```
- Run `e2e-dispatch register --feature <feature>` from `<worktree>`. It records this run, your Paseo agent id, and your session in `<run dir>/run.json`, so `e2e-dispatch out` can move the run to another host overnight and `e2e-dispatch back` can bring it home. Skip this step when the command is not installed.

Never edit `<repo root>` during feature work; the final default-branch merge below is authorized. Set `cwd: "<worktree>"` on every `subagent` launch. Paths in this skill such as `docs/features/<feature>-plan.md` and `AGENTS.md` are relative to `<worktree>`.

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
- **Task rows.** Launch each child from a workflow script, a ```` ```js workflow ```` block sent with `subagent({ workflow: true, async: true, cwd: "<worktree>", options: { missionId: "<mission id>" } })` in the same reply, using `runs.run(key, { label, phase, agent, task })`. One reply carries one block. Always set `phase` to the task id from the plan; it is what nests a run under its task row, and a run without it shows flat under the Workflow row. The key is stable and lowercase, `<task>-<step>`; the label is `<task> · <step>`, where `<step>` is `implement`, `review rN`, `fix rN`, or `journey rN`. Use `e2e` as the task id for E2E journey and repair work. For example, the second review of T3 is `runs.run("t3-review-r2", { label: "T3 · review r2", phase: "T3", agent: "reviewer", task })`. When a script launches several tasks from a list, set `phase: item.id` on each run.
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

## Orchestrator turns

Every turn you take re-reads this whole session, so turns get more expensive as the run grows. Keep them few and small:

- After launching async work, end your turn when nothing the plan requires is runnable. pi-subagents wakes you when a run finishes, fails, or needs a supervisor decision, and the goal extension holds its automatic checkpoints while your runs are active. Do not poll `status`, repeat progress reports, or fill the wait with work the plan does not need. A notice that a child completed while its workflow keeps running needs no action.
- Keep tool output small: tail or grep logs, read files by line range, cap command output, and never read binary files. Write briefs, findings, and diffs to files under `<run dir>` and give subagents the paths instead of pasting the content into your own context.
- Use the launch templates in this skill instead of looking up subagent syntax with `subagent({ action: "guide" })`.

## Run state on disk

Keep the run's state in files as you go, not only in this session, so a new orchestrator can continue the run after a host move or a lost session:

- `<run dir>/tasks.md`: one line per task with its wave, state (`pending`, `implementing`, `review rN`, `fix rN`, `accepted`, or `needs human`), its latest `writerRunId`, and its latest findings file. Update it whenever a task changes state.
- `<run dir>/rulings.md`: append every `Ruling:` line.
- Each findings file also lists the findings you rejected, with your reasoning.

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
> - **Tasks**: keep cohesive work in one task; split only at clearly separate logical responsibilities or module boundaries that can be implemented and reviewed meaningfully on their own. Do not split merely by file, implementation step, or to increase parallelism. Keep tightly coupled implementation, wiring, and tests together; one task in one wave is valid. For each task, include an id, its goal, the files it owns, the interfaces it consumes and produces, its dependencies on other task ids, and the unit test command that proves it is done. Group tasks into ordered waves; tasks in the same wave have no dependencies on each other, touch disjoint files, and run in parallel in this one checkout, so each one's unit test must build and pass while the others are mid-edit (for example, tasks in separate modules or packages). Otherwise put them in separate waves.
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
3. When the plan is complete, commit it on `<branch>`, archive the design tab with `paseo archive <design agent id>`, create the execution goal as described below, and proceed straight into implementation without waiting for further confirmation.

## Execution goal

Before launching implementation, call `create_goal` with `mode: "regular"`. The `objective` must contain the user's request and the entire approved `docs/features/<feature>-plan.md` verbatim, including its acceptance criteria, design, every task and dependency, verification commands, and E2E journey. A file path, short summary, or just the next task is not sufficient. Include this skill's remaining execution requirements as well: implementation waves, review and repair limits, commits, full verification, E2E evidence, delivery, the automatic final default-branch merge unless the user explicitly opts out, and cleanup rules. Preserve the order and all user-approved constraints. Do not set a token budget unless the user supplied one.

Create and focus this goal directly through the extension's `create_goal` tool; do not invoke the guided `/goal` drafting flow or ask the user to confirm the already-approved objective again. Record the returned goal id alongside the workflow mission id. The goal covers the entire workflow, rather than one goal per worker or task. Leave unrelated open goals unchanged. If the extension or tool is unavailable, report the blocker instead of silently running without a goal.

Use the extension's task and progress tools as available to track the approved tasks, accepted reviews, commits, and verification evidence. After interruption or compaction, use `get_goal` and read the approved plan to resume the same goal without creating a duplicate. Do not claim the goal is complete while required work or checks remain outstanding. Goal continuation must respect every human-input gate in this skill. Once all required work and checks are complete, merge into the repository's default branch without another approval prompt unless the user explicitly asked not to merge. An explicit choice to keep the branch or open a PR instead can finish delivery without a merge; apply the corresponding cleanup rules.

## Resume after a host move

`e2e-dispatch` moves a running run between hosts. It freezes the old orchestrator and its subagents, moves the branch, the uncommitted work, and `<run dir>` with paths rewritten for this host, and then starts you with `/skill:e2e-feature resume <handoff file>`. The old orchestrator, its goal, and its subagent runs are gone, and their run ids do not work here.

1. **Orient.** Read the handoff file, a JSON record of the move: the feature, the two hosts, `home` (the host that delivers the run), the branch, the plan path, the accepted task commits, the subagent steps that were in flight, and the path of a copy of the old transcript. Redo the Feature worktree record for this worktree; it reuses the copied `<run dir>` and `snap.sh`, and its `e2e-dispatch register` step records you. Do not create a worktree, a design tab, or a new plan.
2. **Rebuild the state** from `<run dir>/tasks.md`, `<run dir>/rulings.md`, the findings files, the `<feature>: <task id>` commits in `git log`, and `git status`; the uncommitted work moved with the run. Search the transcript copy only for details those files lack, and never read it whole.
3. **Restart tracking.** Create a new workflow mission, and a new execution goal as in Execution goal whose objective says it continues a moved run.
4. **Restart the steps that were in flight:** an implement step as a fresh worker told to continue from the task's current files, a review round from its start, and a fix round as a fresh worker given the same findings file. Then continue the workflow from where it stands.
5. **Away from home.** On a host other than `home`, do not merge into the default branch, push, or archive the workspace. When only delivery remains, or the E2E instructions need something this host lacks, such as an emulator, devices, or a display, stop and call `ask_user` with `<feature> is ready to go home: run e2e-dispatch back on <home>.` Waiting in `ask_user` costs nothing, while ending the turn would only wake you again. Once back on `home`, deliver as usual.

## Implement

Work through the waves in order. A task starts only when every task it depends on has been accepted.

Launch every task of a wave at once, each as its own async workflow (template below), with a `worker` on `magpie/gpt-6.1-sol` at thinking `medium` (`high` for a task the plan marks as subtle, or after a failed attempt). All of them run in `<worktree>`. The plan guarantees that tasks in one wave own disjoint files, so this skill authorizes concurrent writers in `<worktree>` and overrides pi-subagents' one-writer-per-worktree default; do not serialize a wave for that reason. Use pi-subagents' worktree isolation (`worktree: true`) only when the plan says a wave's tasks cannot share a checkout. It branches from a clean `HEAD` and returns a patch that you apply and commit yourself, so commit accepted tasks first.

Give each worker only its own brief, not the session history. Write it to `<run dir>/<task>-brief.md`: the task entry from the plan, the relevant parts of the Design section, the interfaces it depends on, the unit test command, the absolute path `<worktree>`, and the files the other tasks of its wave are editing concurrently. Require it to:

- edit only the files its task owns, inside `<worktree>`, and leave every other file alone, even when it looks wrong;
- not commit, and not run commands that rewrite the index or other files: `git add`, `stash`, `checkout`, `restore`, `reset`, or `clean`, or repository-wide formatters and code generators (format only its own files);
- run every build and test command as `flock <build lock> <command>`, so concurrent workers never build at the same time;
- when a failure comes from a file another task owns, rerun after a while instead of editing that file, and report the failure if it persists;
- implement the task and add or update its unit test, and keep iterating until that unit test passes;
- finish with exactly one status, `DONE`, `DONE_WITH_CONCERNS`, `NEEDS_CONTEXT`, or `BLOCKED`, followed by the files it changed and the last test output.

Each task's workflow implements the task, has the host run its unit test as a `gate`, and starts review round 1 when the gate passes. Write the review round 1 brief (see Review) before launching. The gate is host-run evidence, so you do not rerun the test after the implement step; a worker's own success message is never evidence. On `NEEDS_CONTEXT`, `BLOCKED`, or a failed gate, change something before relaunching: add context or raise thinking; split the task only if it has clearly separate logical responsibilities or module boundaries, following Workflow layout. A gate that fails because of a file another task owns needs a later rerun, not a repair.

```js workflow
const impl = await runs.run("t3-implement", {
  label: "T3 · implement", phase: "T3", agent: "worker", model: "magpie/gpt-6.1-sol:medium",
  task: "Implement T3. Read your brief at <run dir>/t3-brief.md and follow it exactly.",
  gate: "flock <build lock> <T3 unit test command>",
});
if (!impl.ok) return { task: "T3", stage: "implement", writerRunId: impl.runId, implement: impl.output };
const review = await runs.run("t3-review-r1", {
  label: "T3 · review r1", phase: "T3", agent: "reviewer",
  task: "Review T3. Read your brief at <run dir>/t3-review-r1.md and follow it exactly.",
});
return { task: "T3", stage: "review r1", writerRunId: impl.runId, implement: impl.output, review: review.output };
```

## Review

Each task gets up to 3 review rounds. Round 1 starts as soon as the task's implementation passes its gate; reviews of different tasks run in parallel. A failed launch does not count as a round. The `reviewer` agent can read files and `watchdog_diff` but cannot run commands, so give it everything it needs as files.

1. **Review round 1.** A full review by the `reviewer`, configured to run on `magpie/group/astra` with `high` thinking. Its brief, `<run dir>/<task>-review-r1.md`, holds the task entry, the acceptance criteria, the files the task owns, and the unit test command. Tell it to read the task's changes with `watchdog_diff`, passing each owned file or directory as a repo-relative `path`, and to read the untracked files it lists; other tasks may be changing other files at the same time. Ask for findings ranked Critical, Important, or Minor, each with location, evidence, and the smallest fix.
2. **Judge.** Check each finding against the code yourself and reject wrong ones with your reasoning. If no Critical or Important findings remain, accept the task.
3. **Fix and verify (rounds 2 and 3).** Record `before=$(sh <run dir>/snap.sh <owned files>)`. Write the confirmed findings, with their root causes and expected fixes, to `<run dir>/<task>-findings-rN.md`, where N is the round that found them. Then launch the fix-and-verify workflow below. It resumes the worker that implemented the task, so the fix starts from that worker's context instead of re-reading the code. Pass the latest `writerRunId`, which changes every round. The worker reruns the unit test and saves the fix delta. Then a verification review on `magpie/group/astra:medium` checks each earlier finding. Its brief, `<run dir>/<task>-review-r<N+1>.md`, holds the findings file, the delta path, the owned files, and the acceptance criteria. It asks for each finding as resolved or unresolved, with evidence from the delta or the code, with `watchdog_diff` for context. It asks for new findings only when they are Critical, or Important and introduced by the fix, and for no Minor findings. If the delta is missing or empty, the reviewer verifies each finding from the code instead. If the resume is rejected, run the same round with a fresh `worker` given the task brief and the findings.
4. **Accept.** The task is accepted when the latest round has no Critical or Important findings and the unit test passes in a run you make yourself after the last edit, as `flock <build lock> <unit test command>`. Commit only the task's files, as described in Feature worktree, and only while no worker or reviewer is running in `<worktree>`. Commit hooks such as lint-staged stash unstaged changes, which would pull other workers' edits out from under them, and a new `HEAD` stops running reviewers' `watchdog_diff`. Queue the commit until the running subagents settle. Carry Minor findings to the delivery report.
5. **Cap.** If Critical or Important findings remain after round 3, stop work on that task and ask the user with `ask_user`. Include the open findings, what each round tried, and the current test output. Do not run a fourth round without their answer.

```js workflow
const fix = await runs.run("t3-fix-r1", {
  label: "T3 · fix r1", phase: "T3", resume: "<latest writerRunId>",
  task: "Fix the confirmed findings in <run dir>/t3-findings-r1.md, editing only T3's files and following your original brief. Then run `flock <build lock> <T3 unit test command>` and save the fix delta with `git diff <before> \"$(sh <run dir>/snap.sh <owned files>)\" -- <owned files> > <run dir>/t3-fix-r1.diff`. Finish with your status, the files you changed, and the last test output.",
});
const review = await runs.run("t3-review-r2", {
  label: "T3 · review r2", phase: "T3", agent: "reviewer", model: "magpie/group/astra:medium",
  task: "Verify the T3 fixes. Read your brief at <run dir>/t3-review-r2.md and follow it exactly.",
});
return { task: "T3", stage: "review r2", writerRunId: fix.runId, fix: fix.output, review: review.output };
```

After all tasks are accepted, run the plan's full Test and verification checks yourself. Evidence must come from a run made after the last edit.

## E2E test

Re-read the project-level `AGENTS.md` in `<worktree>`, because the user may have changed it since preflight.

- **missing**: ask the user with `ask_user` to either add instructions to `AGENTS.md` on how to test a feature end to end in a sandbox, or add a note to `AGENTS.md` that e2e testing is not needed for this repository. Wait for their answer, then re-read the file. Do not deliver while the status is still missing.
- **not needed**: skip this phase and record that in the report.
- **instructions**: hand the journey to a fresh `worker` on `magpie/gpt-6.1-sol` at thinking `medium`, launched as `runs.run("e2e-journey-r1", { label: "E2E · journey r1", phase: "e2e", agent: "worker", model: "magpie/gpt-6.1-sol:medium", task })`, so the sandbox's commands and logs stay out of your context. Its brief, `<run dir>/e2e-brief.md`, holds the `AGENTS.md` e2e instructions, the plan's E2E journey, `<worktree>`, and `<branch>`. Require the worker to:
  - run everything from `<worktree>`, so the sandbox runs the feature branch;
  - bring up the sandbox and walk through the journey step by step, keeping the evidence (commands, output, screenshots, or logs) under `<run dir>/e2e/`;
  - report each step's expected result, actual result, and evidence paths;
  - not edit product code;
  - on a failed step, reproduce it once and state its root-cause hypothesis;
  - leave the sandbox up when a step failed, so the rerun can reuse it.

  Check the reported results against the expected ones yourself, spot-checking key evidence by path rather than reading all of it. Confirm the root cause of each failure and send the fix to a `worker` on `magpie/gpt-6.1-sol`, under the same rules as task workers. Then rerun the affected unit tests yourself and resume the journey worker for the rerun: `resume: "<its latest runId>"`, key `e2e-journey-rN`. Allow at most three repair attempts, then ask the user. When the journey passes, have the journey worker tear the sandbox down if the instructions say to.

## Deliver

On a host other than the run's `home`, stop before this section, as Resume after a host move describes.

Inspect the final diff with `git diff <base commit>...HEAD` and confirm `git status` is clean. Report the changed files and behavior, the commits on `<branch>`, each task with its review rounds, verification and e2e evidence, rulings made, deferred Minor findings, and unresolved risks. Never claim completion while required checks remain unverified.

As the final delivery step, once all required work and checks are complete, automatically merge the completed commits from `<branch>` into the repository's default branch unless the user explicitly asked not to merge (including a request to keep the branch or open a PR instead). This workflow authorizes that merge without another approval prompt. Identify `<default branch>` from the remote's HEAD or repository metadata; do not assume `<base>` is the default branch. If the default branch cannot be determined, ask the user to identify it. Follow the merge procedure below, then include the target branch, resulting commit, and verification results in the final report. If merging is blocked, report the blocker and keep the worktree. Push or open a PR only when the user explicitly asked for it.

## Merge into the default branch

Unless the user explicitly asked not to merge, proceed automatically after all required work and checks are complete. Use `<default branch>` as the target in every step below (even when the worktree's recorded `<base>` differs):

1. **Update from the default branch.** With a clean tree, run `git merge <default branch>` on `<branch>`. When the default branch tracks a remote, run `git fetch` first and merge the remote-tracking ref. Resolve conflicts in `<worktree>`: trivial ones yourself, substantive ones through a `worker`, and ask the user when a conflict changes behavior. If the merge brought in changes, rerun the plan's Test and verification checks and the e2e journey.
2. **Find the target checkout.** Find the worktree that has `<default branch>` checked out with `git worktree list --porcelain`; usually that is `<repo root>`. Merge only if `git -C <target> status --porcelain` is empty. Otherwise ask the user; never stash, reset, or discard work in their checkout. If `<default branch>` is not checked out anywhere, merge in `<worktree>` itself: check out `<default branch>`, merge, then check out `<branch>` again, as Paseo does.
3. **Merge to the default branch.** Run `git -C <target> merge <branch>`. Squash only when `AGENTS.md` or the user asks for it: `git -C <target> merge --squash <branch>`, then `git -C <target> commit -m "Squash merge <branch> into <default branch>"`. If the merge conflicts, run `git -C <target> merge --abort` and go back to step 1.
4. **Confirm.** `git -C <target> log --oneline -n 20 <default branch>` shows the feature commits or the squash commit. Push only when the user asked for it.
## Clean up the worktree

In Paseo, cleanup means archiving the workspace. Archiving runs the teardown commands from the project's `paseo.json`, force-removes the Paseo-owned worktree with `git worktree remove --force`, prunes it, and archives every agent and terminal in the workspace. It keeps the branch.

Because the removal is forced, archive only after the branch is merged, or after the user explicitly says to discard it, and only once `git status` is clean, so nothing uncommitted is lost. If the user chose to keep the branch, leave the workspace in place and say so.

1. Confirm every worker and the design tab are archived, and tear down any sandbox the e2e instructions started.
2. You run inside this workspace, so archiving it stops you too. Deliver your final report first. Then tell the user to archive the workspace from Paseo, from the workspace's Archive action in the sidebar. If they ask you to do it, run `paseo workspace archive <workspace id>` as your very last command.
3. Paseo leaves `<branch>` in place. Delete it only when the user asks: `git -C <repo root> branch -d <branch>`, which refuses unmerged work.

For a subagent or Paseo infrastructure failure, preserve the exact error and the Git and worktree state, and use the tool's supported recovery path before retrying. Beyond the pi-subagents workflow scripts described here, do not build custom scripts, schedulers, daemons, or automatic production changes. This workflow handles one feature at a time and stops when recovery makes no progress.
