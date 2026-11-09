---
name: e2e-feature
description: "Opt-in end-to-end feature workflow: a high-reasoning Pi Opus design tab in Paseo (Pi Gemini on Pi Opus quota exhaustion) that hands the plan back, Pi-sol implementation subagents, Pi Gemini review loops with medium reasoning, and an AGENTS.md-driven e2e check."
disable-model-invocation: true
---

# End-to-end feature workflow

Use this workflow only when the user explicitly invokes `/skill:e2e-feature <request>`. Do not activate it for ordinary requests. This skill authorizes subagent delegation; enable the `subagent` tool if it is not loaded yet. `/skill:e2e-feature resume <handoff file>` continues a run that `e2e-dispatch` moved to this host: follow Resume after a host move instead of Preflight and Design.

You are the orchestrator, running on whatever model this session already uses; do not switch it. You coordinate four phases (design, implement, review, e2e test) and do not write feature code yourself, except for trivial integration fixes that you record as rulings.

If this skill was expanded by `/skill:e2e-feature`, its instructions are already in context; do not read this file again. Read linked references only when entering that phase.

This skill uses the Pi goal extension to execute the full approved plan. Invoking this skill explicitly authorizes creating a regular goal once the user approves the design. Design approval also approves that goal; do not run a second goal drafting or confirmation round. Keep the design handoff before goal creation so automatic goal continuation does not bypass the design approval gate.

Stop and ask the user, with `ask_user`, only for: a destructive or irreversible operation, a security-sensitive action, a side effect outside the worktree other than the default-branch merge authorized below, a request so ambiguous that every path forward is a guess, or a gate this skill names. Decide everything else yourself, record it as `Ruling: <decision> — <why> — <cost if wrong>`, and keep going.

## E2E requirement scope

Any isolated environment that can exercise the feature’s user journey end to end is acceptable. Isolation can come from a VM, a container, a disposable environment, or a local stack with separate test state; no particular isolation technology or terminology is required.

The agent must run end-to-end tests **only when a feature is first added**, subject to the repository's explicit “not needed” exemption below. Complete any necessary repairs and reruns during that initial feature workflow. Future pushes or deployments of the existing feature do not need to rerun those end-to-end tests. **Existing unit tests must still be run**, including for future pushes and deployments; skipping E2E tests does not waive unit testing.

Do not add E2E requirements for push or deploy to `AGENTS.md` (or `agent.md`). Any testing instructions requested or added by this workflow must state that the agent runs E2E tests when a feature is first added, future pushes and deployments do not require those E2E tests, and existing unit tests must still be run.

## Preflight

1. Pick a short, lowercase feature slug `<feature>`.
2. Confirm the current directory belongs to a Git repository and inspect the current Paseo workspace and Git worktree metadata.
3. If the current workspace is already a Paseo-owned Git worktree, use it and record its details as described in Feature worktree.
4. Otherwise, automatically create a new Paseo worktree workspace for the current project before doing feature work. Use the project's current branch as the base unless the user specified another base, and a feature branch named `feat/<feature>`. Discover the project ID from the current workspace or Paseo project registry; create the workspace with `paseo workspace create --isolation worktree --mode branch-off --new-branch feat/<feature> --base <base> --project <project-id> --title "<feature>" --json`. If the installed CLI uses different flags, inspect `paseo workspace create --help` and use the equivalent supported options. Verify the returned workspace ID, worktree path, owning project, base ref, branch, and `paseo/worktree.json`. Since the current agent cannot change its working directory, launch a fresh orchestrator agent in that workspace with the original user request and `/skill:e2e-feature` invocation, then end this turn. The new agent resumes at preflight using the created workspace; do not create a second worktree. If the CLI cannot create or associate the worktree, preserve the exact error and report the blocker; do not fall back to editing the current checkout or ask the user to create it manually.
5. For a request that adds a new feature, read the project-level `AGENTS.md` in `<worktree>` and classify its e2e status. For requests that do not add a new feature, skip this classification and the E2E phase; do not request or add E2E instructions:
   - **instructions**: it explains how to run an end-to-end test of a feature by walking through the user journey in an isolated environment, such as a VM, a container, a disposable environment, or a local stack with isolated state;
   - **not needed**: it explicitly says e2e testing is not needed for this repository;
   - **missing**: neither of the above, including when there is no `AGENTS.md`.
   When the status is missing, tell the user now, together with the design handoff below, so they can fix it while the design is underway. The gate is enforced in the e2e phase.
6. Run `e2e-feature-run init --feature <feature>` in the verified isolated worktree. This invocation opts that worktree into explicit ready/wait scheduling and idle backoff, preserving other settings and all user-owned pauses; it does not change global defaults. Read [references/waiting.md](references/waiting.md) before goal creation.
7. Create the workflow mission described in Workflow layout and record its id.

## Feature worktree

Use an existing Paseo-owned Git worktree when the skill is invoked from one. When invoked from a local workspace or the main checkout, create a new Paseo-owned Git worktree automatically during preflight as specified above. Paseo places it under `~/.paseo/worktrees/<project hash>/<slug>` and records its base. All feature work, including the plan, implementation, commits, verification, and E2E runs, happens in that isolated worktree.

Verify and record it during preflight:

- `<worktree>` is `git rev-parse --show-toplevel` from your working directory. It is Paseo-owned when it lives under `~/.paseo/worktrees/` and `$(git rev-parse --git-dir)/paseo/worktree.json` exists.
- `<base>` is the `baseRef` field of that `worktree.json`, or `baseRefName` when `baseRef` is absent. This is the branch Paseo merges back into.
- `<workspace id>` is the entry in `paseo workspace ls --json` whose `cwd` is `<worktree>`.
- `<repo root>` is the main checkout: the first `worktree` entry of `git worktree list --porcelain`.
- The base commit is `git merge-base HEAD <base>`.
- `<branch>` is the current branch. Paseo may rename a placeholder branch after the first agent prompt, so read it again with `git branch --show-current` whenever you need it, not only once.
- `<git dir>` is `git rev-parse --absolute-git-dir`, this worktree's own Git directory, outside the tracked tree. Create `<run dir>` as `<git dir>/e2e-feature/<feature>` for briefs, findings, diffs, and E2E evidence. `<build lock>` defaults to `<git dir>/e2e-feature-build.lock`. Record command resource groups in `<run dir>/verification.md`: serialize commands sharing mutable build output, coverage destinations, generators, browser endpoints, or devices; allow concurrency only for proven independent groups. Use a common Git-directory lock when the resource is shared across worktrees. Unknown commands use the default lock. Record a small concurrency limit appropriate to the host; independent commands can still compete for CPU and RAM.
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

Waves describe the dependency graph; they are not whole-wave barriers unless the approved plan explicitly requires one. Launch a ready task once its own dependencies are accepted and its owned files and verification inputs are compatible with every running task. An unrelated review or deferred commit must not delay it. Keep tasks that share files, mutable generated inputs, or unstable interfaces ordered. Give priority to a ready task with the longest downstream dependency chain; do not invent duration estimates. Acceptance releases dependencies; commit accepted files at the next safe point with no live workers or reviewers. Never change `HEAD` underneath a review.

Group the run as one Workflow row with one row per task:

- **Workflow row.** Create one mission before the first launch with `subagent({ action: "mission.create", options: { mission: { title: "e2e-feature: <feature>", objective: "<one-line goal>" } } })`, and pass its `missionId` to every later launch so all children collect under it.
- **Task rows.** Launch each child from a workflow script, a ```` ```js workflow ```` block sent with `subagent({ workflow: true, async: true, cwd: "<worktree>", options: { missionId: "<mission id>" } })` in the same reply, using `runs.run(key, { label, phase, agent, task })`. One reply carries one block. Always set `phase` to the task id from the plan; it is what nests a run under its task row, and a run without it shows flat under the Workflow row. The key is stable and lowercase, `<task>-<step>`; the label is `<task> · <step>`, where `<step>` is `implement`, `review rN`, `fix rN`, or `journey rN`. Use `e2e` as the task id for E2E journey and repair work. For example, the second review of T3 is `runs.run("t3-review-r2", { label: "T3 · review r2", phase: "T3", agent: "reviewer", model: "magpie/group/argon:medium", task })`. When a script launches several tasks from a list, set `phase: item.id` on each run.
- **Subtitles, not nesting.** Put a task's wave and dependencies in its row summary, such as `wave 2 · after T1, T2`, with its state: `pending`, `implementing`, `review rN`, `fix rN`, `accepted (N rounds)`, or `needs human`.

Whenever you report progress to the user, use this layout. List accepted tasks on one line each and expand only the tasks still in progress:

```
Workflow: e2e-feature: <feature>
├─ Design (Pi Opus / Pi Gemini tab)      ✓ plan approved
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

- After launching async work, end your turn when nothing the plan requires is runnable. pi-subagents wakes you when a run finishes, fails, or needs a supervisor decision, and the goal extension holds its automatic checkpoints while your runs are active. Do not poll `status`, repeat progress reports, or fill the wait with work the plan does not need. A notice that an intermediate child completed while its workflow keeps running needs no action. A final review launched with `notifyOnComplete: true` is a task boundary: read its saved report and gate receipt, judge the findings, and release compatible dependencies without waiting for siblings.
- Keep tool output small: tail or grep logs, read files by line range, cap command output, and never read binary files. Write briefs, findings, and diffs to files under `<run dir>` and give subagents the paths instead of pasting the content into your own context.
- Use the launch templates in this skill instead of looking up subagent syntax with `subagent({ action: "guide" })`. Once the execution goal is active, after required bookkeeping and async dispatch, make `update_goal({continuation: {kind: "ready"}})` the last tool call and yield. When only a separate producer can make progress, declare its source-specific message wait as in `references/waiting.md`; never checkpoint repeatedly to say you are waiting.
- Save tasks, rulings, input identities and receipt paths before a phase boundary. If context is large, compact once at that boundary using the supported session control; resume from those files and `get_goal`, without rereading complete transcripts or recreating the goal.
- Return compact workflow receipts (`ok`, task, stage, `runId`, `outputReference`, and artifact paths). Save reports with `output` and `outputMode: "file-only"`; read findings by path when judging a review. Do not return `impl.output` and `review.output` together. Persist the full approved goal objective, but filter a verbose creation result through codemode before displaying it; keep only the goal id and status, never echo the objective.
- An inactivity notice alone does not establish a stall. Inspect the named run once; preserve an active command or model request and wait for completion. Do not send routine continuation nudges, restart it, or launch replacement work while it is still active.

## Run state on disk

Keep the run's state in files as you go, not only in this session, so a new orchestrator can continue the run after a host move or a lost session:

- `<run dir>/tasks.md`: one line per task with its wave, state (`pending`, `implementing`, `review rN`, `fix rN`, `accepted`, or `needs human`), its latest `writerRunId`, and its latest findings file. Update it whenever a task changes state.
- `<run dir>/rulings.md`: append every `Ruling:` line.
- Each findings file also lists the findings you rejected, with your reasoning.
- `<run dir>/verification.md`: exact required check inventory, environment recipe, input identities, resource groups, test discovery, gate receipts, and evidence paths. Read [references/latency.md](references/latency.md) and [references/verification.md](references/verification.md) when preparing it. Use the latter's reusable JSON recipe and native `e2e-verify` workflow for deterministic checks. Record ready, launch, model/command start, lock acquired, finish, and acceptance times when available; distinguish external waits and human approval from execution. Use existing trace timestamps rather than spending model turns collecting timing data.

## Design

Read `$PASEO_AGENT_ID`; it is your own Paseo agent id, and the design tab uses it to hand the plan back to you. If it is empty, you are not running inside Paseo: drop the handoff paragraph from the brief and wait for the user to tell you the plan is ready instead.

Create a new, independent, user-facing Paseo agent for design, using Pi Opus (`pi/magpie/group/opus`) with thinking set to `high`. Both Pi Opus and the Pi Gemini fallback must use high reasoning. Do not use a Pi subagent, agent-scoped MCP creation, or a create-then-detach sequence for this phase. A plain agent-originated `paseo run` inherits parentage through `PASEO_AGENT_ID`; `--workspace` controls placement but does not remove parentage.

First capture the orchestrator's agent ID for the brief's explicit `PLAN_READY` handoff. The design agent goes in the same worktree workspace as you, `<workspace id>`. Then unset `PASEO_AGENT_ID` only for the design launch command with `env -u`, and pass the existing workspace explicitly. Keep the orchestrator's own environment and the daemon connection settings unchanged. This workflow explicitly authorizes creating the design session as a top-level agent:

```bash
env -u PASEO_AGENT_ID paseo run --no-wait --json \
  --provider pi/magpie/group/opus --thinking high \
  --workspace <workspace id> \
  --cwd <worktree> --title "Design: <feature>" \
  "$(cat <brief file>)"
```

Capture the returned agent ID and run `paseo inspect <design agent id> --json`. Require `ParentAgentId` to be `null`, and verify through Paseo's agent/workspace metadata that the agent belongs to the intended workspace. If either check fails, preserve the launch output and exact state and report the infrastructure blocker; do not silently proceed with a subagent or create duplicate design sessions.

### Pi Opus quota fallback

If Pi Opus is already known to be out of quota, launch Pi Gemini directly instead. If the Pi Opus design launch or a later design turn reports quota exhaustion or a usage limit that blocks design, replace that design tab with Pi Gemini automatically; do not wait for a quota reset or ask the user to approve the substitution. This exception applies only to Pi Opus quota exhaustion, not unrelated launch or infrastructure failures.

Before replacing an existing Pi Opus tab, preserve its agent ID, exact quota error, and any available design context. Prepare a replacement brief containing the original brief, the current plan file if present, and the design decisions, unresolved questions, and approval status available from the Pi Opus session. Archive the blocked Pi Opus agent with `paseo archive <old design agent id>` before launching the replacement, so only one design tab remains active. If Pi Opus never created an agent, skip the archive step.

Launch the replacement as an independent agent in the same workspace and worktree, keeping the original title and orchestrator's `PLAN_READY` handoff:

```bash
env -u PASEO_AGENT_ID paseo run --no-wait --json \
  --provider pi/magpie/group/argon --thinking high \
  --workspace <workspace id> \
  --cwd <worktree> --title "Design: <feature>" \
  "$(cat <replacement brief file>)"
```

Apply the same independence and workspace checks to the replacement, then record its ID as the current design agent ID for all later messages and cleanup. Tell the user Pi Opus exhausted its quota and the design tab now uses Pi Gemini with high reasoning. Continue the existing design and approval process from the preserved context; replacing the tab does not approve the plan. If the fallback fails, preserve the exact error and report the blocker rather than repeatedly creating agents.

### Design brief and handoff

The independent agent should be available in the workspace's agent list. Do not claim it is open or focused in the user's client merely because creation succeeded. `paseo agent open` is optional and requires a Desktop installation on the CLI machine; its failure on a remote or headless host does not invalidate the independent agent. Do not install Desktop or change daemon configuration to focus a tab.

Write the brief to a temporary file first. It contains the user's request, what you learned in preflight, and these instructions:

> You are the design agent for this feature. You work in the feature worktree `<worktree>` on branch `<branch>`; do not edit anything outside it. Work with the user in this tab to design it, exploring the code as needed. Do not implement the feature or commit. The outcome of this session is one file, `<worktree>/docs/features/<feature>-plan.md`, which you keep up to date as the design evolves. It must contain these sections:
> - **Goal and acceptance criteria**: target behavior and measurable criteria.
> - **Design**: implementation details, including module boundaries, data flow, interfaces with exact signatures, error handling, and the conventions to follow.
> - **Tasks**: keep cohesive work in one task; split only at clearly separate logical responsibilities or module boundaries that can be implemented and reviewed meaningfully on their own. Do not split merely by file, implementation step, or to increase parallelism. Keep tightly coupled implementation, wiring, and tests together; one task in one wave is valid. For each task, include an id, its goal, the files it owns, the interfaces it consumes and produces, its dependencies on other task ids, and the unit test command that proves it is done. Group tasks into waves for presentation, with explicit dependencies and file/build conflicts controlling launch. Concurrent tasks must own disjoint files and their checks must pass while others are mid-edit; otherwise order them explicitly. A ready task may start before unrelated tasks in an earlier wave finish. Identify external dependencies and which local tasks can proceed without them.
> - **Test and verification**: the complete unit, integration, lint, type, build, coverage, and visual check inventory required by the repository and request. Include exact commands, current runner and test-project discovery, environment prerequisites, generated inputs, concurrency conflicts, and which commands generate or rewrite files. Identify equivalent coverage/unit commands and reusable checks without reducing test scope. Include an isolated smoke check and cross-project dependency compatibility requirements.
> - **E2E journey**: the user journey that proves the feature works end to end, written as steps with expected results.
>
> When the user approves the plan, save the final file and hand it to the orchestrator by running exactly this command; `--no-wait` matters, because the orchestrator's turn lasts the whole implementation:
>
> `paseo send <orchestrator agent id> --no-wait --prompt "PLAN_READY <worktree>/docs/features/<feature>-plan.md: approved by the user. <one-line summary and any open notes>"`
>
> Then tell the user the plan has been handed off. If the orchestrator later sends you questions about the plan, update the file and send `PLAN_READY` again.

Record the design agent's ID and workspace ID after verifying independence and placement. Tell the user the independent `Design: <feature>` agent is available in that workspace's agent list, to open it and work out the plan there, and that it will hand the plan back to you when they approve it. While design is underway, use at most 60 seconds for an environment smoke check from the existing project recipe: validate runner discovery, one existing test, browser/device availability, ports, and generated dependencies as applicable. Keep logs under `<run dir>`, avoid product edits and shared-state mutations, and report blockers for the design to resolve; do not launch a long suite or install software outside this workflow's authority. This check is setup evidence, not final feature verification. Then end your turn. Do not poll the tab. On a notification or user report that Pi Opus is blocked by quota exhaustion, apply the Pi Opus quota fallback above and hand the replacement tab back to the user. Otherwise ignore turn-finished notifications from the design tab; continue into implementation only on a `PLAN_READY` message or when the user tells you the plan is ready.

When the plan arrives:

1. Read `<worktree>/docs/features/<feature>-plan.md`. If it is missing, ask the design tab to write it with `paseo send <design agent id> --no-wait --prompt "..."` and end your turn.
2. Check that every section is present, every task has a unit test command, the dependency graph has no cycles, task boundaries follow the cohesion rule in Workflow layout, and the full required check inventory and environment recipe are explicit. Check file and build-input conflicts across tasks that can overlap, including tasks in different waves. Prepare `<run dir>/verification.md` from the approved inventory and smoke evidence. Send gaps or unnecessary task splits back to the design tab the same way, or ask the user if a gap needs their decision.
3. When the plan is complete, commit it on `<branch>`, archive the design tab with `paseo archive <design agent id>`, create the execution goal as described below, and proceed straight into implementation without waiting for further confirmation.

## Execution goal

Before launching implementation, call `create_goal` with `mode: "regular"`. The `objective` must contain the user's request and the entire approved `docs/features/<feature>-plan.md` verbatim, including its acceptance criteria, design, every task and dependency, verification commands, and E2E journey. A file path, short summary, or just the next task is not sufficient. Include this skill's remaining execution requirements as well: implementation waves, review and repair limits, commits, full verification, E2E evidence, delivery, the automatic final default-branch merge unless the user explicitly opts out, and cleanup rules. Preserve the order and all user-approved constraints. Do not set a token budget unless the user supplied one.

Create and focus this goal directly through the extension's `create_goal` tool; do not invoke the guided `/goal` drafting flow or ask the user to confirm the already-approved objective again. Record the returned goal id alongside the workflow mission id. The goal covers the entire workflow, rather than one goal per worker or task. Leave unrelated open goals unchanged. If the extension or tool is unavailable, report the blocker instead of silently running without a goal.

Use the extension's task and progress tools as available to track the approved tasks, accepted reviews, commits, and verification evidence. After interruption or compaction, use `get_goal` and read the approved plan to resume the same goal without creating a duplicate. Do not claim the goal is complete while required work or checks remain outstanding. Goal continuation must respect every human-input gate in this skill. Once all required work and checks are complete, merge into the repository's default branch without another approval prompt unless the user explicitly asked not to merge. An explicit choice to keep the branch or open a PR instead can finish delivery without a merge; apply the corresponding cleanup rules.

## Resume after a host move

Read [references/host-move.md](references/host-move.md) only for `/skill:e2e-feature resume <handoff file>`. Reconstruct the existing run; preserve user pauses and the home-host delivery restriction.

## Implement

Follow the approved dependency graph. A task starts only when every task it depends on has been accepted and the file/build-input conflict checks in Workflow layout allow it.

Launch all compatible ready tasks together in one async workflow call, with a `worker` on `magpie/gpt-6.1-sol` at thinking `medium` (`high` for a task the plan marks as subtle, or after a failed attempt). Chain each task's implement → gate → review with plain helpers returning promises, and observe those chains with `Promise.all`; the installed sandbox rejects nested async functions. Do not await a batch of implementations before starting reviews. Set `notifyOnComplete: true` only on each task's final review, so its completion wakes you for acceptance while siblings continue. `emit()` can persist a compact receipt but does not itself wake the parent. Launch newly ready tasks in a later turn through the same mission, after consuming the completion; do not poll. All tasks run in `<worktree>`. The plan's file/build-input conflict checks authorize concurrent writers with disjoint ownership in `<worktree>` and override pi-subagents' one-writer-per-worktree default; do not serialize compatible tasks for that reason. Use pi-subagents' worktree isolation (`worktree: true`) only when the plan says a wave's tasks cannot share a checkout. It branches from a clean `HEAD` and returns a patch that you apply and commit yourself, so commit accepted tasks first.

Give each worker only its own brief, not the session history. Write it to `<run dir>/<task>-brief.md`: the task entry from the plan, the relevant parts of the Design section, the interfaces it depends on, the unit test command, the absolute path `<worktree>`, and the files every other active task is editing concurrently. Require it to:

- edit only the files its task owns, inside `<worktree>`, and leave every other file alone, even when it looks wrong;
- not commit, and not run commands that rewrite the index or other files: `git add`, `stash`, `checkout`, `restore`, `reset`, or `clean`, or repository-wide formatters and code generators (format only its own files);
- run development build/test commands as `flock <build lock> <command>`; independent host gates use the recipe helper, which claims both the legacy guard and all assigned resources. A narrower flock alone is insufficient. Acquire each lock once, never nest it;
- when a failure comes from an active task's files or a missing external artifact, report the exact dependency with `NEEDS_CONTEXT` or `BLOCKED`; wait for a producer completion before rerunning, instead of timed retries or editing another task's files;
- implement the task and add or update its unit test, and keep iterating until that unit test passes;
- finish with exactly one status, `DONE`, `DONE_WITH_CONCERNS`, `NEEDS_CONTEXT`, or `BLOCKED`, followed by the files it changed and the last test output.

Each task's workflow implements the task, has the host run its unit test as a `gate` using its assigned resource lock, and starts review round 1 when the gate passes. Launch producer work for external dependencies as soon as its approved inputs are ready, while independent local tasks proceed. Require a handoff with the exact revision, existing-plus-new API compatibility, artifact digest, and a copied verification report; check compatibility before an expensive build. Write the review round 1 brief (see Review) before launching. The gate is host-run evidence, so you do not rerun the test after the implement step; a worker's own success message is never evidence. On `NEEDS_CONTEXT`, `BLOCKED`, or a failed gate, change something before relaunching: add context or raise thinking; split the task only if it has clearly separate logical responsibilities or module boundaries, following Workflow layout. A gate that fails because of a file another task owns needs a later rerun, not a repair.

```js workflow
const impl = await runs.run("t3-implement", {
  label: "T3 · implement", phase: "T3", agent: "worker", model: "magpie/gpt-6.1-sol:medium",
  task: "Implement T3. Read your brief at <run dir>/t3-brief.md and follow it exactly.",
  gate: "e2e-feature-run verify --feature <feature> --recipe <run dir>/verification.json --check T3",
  output: "<run dir>/t3-implement-result.md", outputMode: "file-only",
});
if (!impl.ok) return { task: "T3", stage: "implement", ok: false, writerRunId: impl.runId, report: impl.outputReference, artifacts: impl.artifactPaths };
const review = await runs.run("t3-review-r1", {
  label: "T3 · review r1", phase: "T3", agent: "reviewer", model: "magpie/group/argon:medium",
  task: "Review T3. Read your brief at <run dir>/t3-review-r1.md and follow it exactly.",
  notifyOnComplete: true,
  output: "<run dir>/t3-review-r1-result.md", outputMode: "file-only",
});
const receipt = { task: "T3", stage: "review r1", ok: review.ok, writerRunId: impl.runId, reviewRunId: review.runId, report: review.outputReference, artifacts: review.artifactPaths };
emit(receipt);
return receipt;
```

## Review

Use Pi Gemini (`magpie/group/argon:medium`) with medium reasoning for every reviewer launch, explicitly overriding the reviewer agent's default model. The bounded comparison in `references/reviewer-benchmark.md` is an opt-in performance experiment, never an extra stage of every feature; retain this default until representative, adjudicated evidence supports a change. Each task gets up to 3 review rounds. Round 1 starts as soon as the task's implementation passes its gate; reviews of different tasks run in parallel. A failed launch does not count as a round. The `reviewer` agent can read files and `watchdog_diff` but cannot run commands, so give it everything it needs as files.

1. **Review round 1.** A full review by the `reviewer`, configured to run on Pi Gemini (`magpie/group/argon`) with `medium` thinking. Its brief, `<run dir>/<task>-review-r1.md`, holds the task entry, its exact contract and relevant acceptance criteria, owned files, relevant interface/test paths, worker report path, and host gate receipt. Link other plan sections by heading instead of copying the whole feature design. Tell it to read the task's changes with `watchdog_diff`, passing each owned file or directory as a repo-relative `path`, and to read untracked additions; other tasks may be changing other files at the same time. Batch independent reads/searches. Expand to callers or dependencies when needed to prove a concrete issue; do not repeat deterministic artifact/provenance checks already in a valid host receipt. Ask for all concrete current findings ranked Critical, Important, or Minor, each with location, evidence, impact, and the smallest fix. End with a short verdict and any material unreviewed scope. Omit inventories of correct code; when no issues are found, return the verdict and scope limitation in a few sentences. Do not truncate findings or impose an arbitrary review timeout.
2. **Judge.** Check each finding against the code yourself and reject wrong ones with your reasoning. If no Critical or Important findings remain, accept the task.
3. **Fix and verify (rounds 2 and 3).** Record `before=$(sh <run dir>/snap.sh <owned files>)`. Write the confirmed findings, with their root causes and expected fixes, to `<run dir>/<task>-findings-rN.md`, where N is the round that found them. Then launch the fix-and-verify workflow below. It resumes the worker that implemented the task, so the fix starts from that worker's context instead of re-reading the code. Pass the latest `writerRunId`, which changes every round. The worker reruns the unit test and saves the fix delta. A retained resume cannot take a new `gate` parameter: attach independent host verification to the fresh verification reviewer as in the template, or run `e2e-verify` separately before acceptance. Then a verification review on `magpie/group/argon:medium` checks each earlier finding. Its brief, `<run dir>/<task>-review-r<N+1>.md`, holds the findings file, the delta path, the owned files, and the acceptance criteria. It asks for each finding as resolved or unresolved, with evidence from the delta or the code, with `watchdog_diff` for context. It asks for new findings only when they are Critical, or Important and introduced by the fix, and for no Minor findings. Before each review save a diff for the owned files plus the input identity and host receipt; the reviewer starts there, expanding to callers only to prove a concrete issue. If the delta is missing or empty, the reviewer verifies each finding from the code instead. If the resume is rejected, run the same round with a fresh `worker` given the task brief and the findings.
4. **Accept.** The task is accepted when the latest round has no Critical or Important findings and an independent host gate passes after the last relevant edit. Reuse the implementation gate after a read-only review when its command, discovered tests, source/dependency/generated inputs, and environment identities still match; follow the receipt rules in `references/latency.md`. A worker's claim or a successful child exit alone is insufficient. After a fix, use a matching host gate inherited from the retained contract or attached to the fresh verification review; otherwise run the affected check through `e2e-verify` or host tools before accepting. Never attach a new `gate` parameter to a retained resume. Acceptance releases dependent tasks immediately, even while its commit is queued. Commit only the task's files, as described in Feature worktree, and only while no worker or reviewer is running in `<worktree>`. Commit hooks can stash unstaged changes and change reviewed files; if a hook rewrites relevant inputs, invalidate their receipts and reverify/review the delta. Queue the commit until running subagents settle. Carry Minor findings to the delivery report.
5. **Cap.** If Critical or Important findings remain after round 3, stop work on that task and ask the user with `ask_user`. Include the open findings, what each round tried, and the current test output. Do not run a fourth round without their answer.

```js workflow
const fix = await runs.run("t3-fix-r1", {
  label: "T3 · fix r1", phase: "T3", resume: "<latest writerRunId>",
  task: "Fix the confirmed findings in <run dir>/t3-findings-r1.md, editing only T3's files and following your original brief. Then run `flock <build lock> <T3 unit test command>` and save the fix delta with `git diff <before> \"$(sh <run dir>/snap.sh <owned files>)\" -- <owned files> > <run dir>/t3-fix-r1.diff`. Finish with your status, the files you changed, and the last test output.",
});
if (!fix.ok) return { task: "T3", stage: "fix r1", ok: false, writerRunId: fix.runId, report: fix.outputReference, artifacts: fix.artifactPaths };
const review = await runs.run("t3-review-r2", {
  label: "T3 · review r2", phase: "T3", agent: "reviewer", model: "magpie/group/argon:medium",
  gate: "e2e-feature-run verify --feature <feature> --recipe <run dir>/verification.json --check T3",
  task: "Verify the T3 fixes. Read your brief at <run dir>/t3-review-r2.md and follow it exactly.",
  notifyOnComplete: true,
  output: "<run dir>/t3-review-r2-result.md", outputMode: "file-only",
});
return { task: "T3", stage: "review r2", ok: review.ok, writerRunId: fix.runId, reviewRunId: review.runId, report: review.outputReference, artifacts: review.artifactPaths };
```

After all tasks are accepted and commits/hooks have settled, run the complete Test and verification inventory from `verification.md`. Use ordinary host tools with persisted logs for deterministic checks; do not spend an LLM preflight worker merely to say a command is ready. Use `subagent({workflow: "e2e-verify", async: true, cwd: "<worktree>", options: {missionId: "<mission id>"}, args: {feature: "<feature>", recipe: "<run dir>/verification.json", phase: "full", timeoutMs: 3600000}})` for long deterministic checks. Inspect the returned `ok`, exit status and receipt. The installed extension grants only the exact helper command and launches no LLM wrapper. Raw workflow scripts still cannot call `runs.host`. Keep full configured test discovery, including visual/Storybook projects and existing baselines. A passing coverage run may also satisfy units only when discovery and assertions are equivalent. Reuse independent receipts whose inputs still match; rerun invalidated checks. Never remove a required project to make a gate pass.

Start independent verification groups and the E2E journey concurrently when all run against stable inputs, isolated output/state, and separate resource groups within the host's concurrency limit. Run generators and prerequisite builds first; use the snapshot/pin commands in `references/verification.md` to copy the resulting feature build and record its manifest. Verify that manifest before and after the journey. Generated-input identities must also be included in consuming checks. If the inputs or shared resources cannot be isolated, serialize those operations. Both branches must pass before delivery. Repositories that prohibit build/emulator overlap, including Element X Android, keep those operations serialized. A repair invalidates every overlapping check/journey; wait for active readers of those files or use an isolated repair checkout, then rerun affected evidence. Preserve the full final inventory.

## E2E test

The agent runs this phase **only when the feature is first added**, including repairs and reruns needed to finish that initial feature workflow. Skip it for future pushes, deployments, and other requests that do not add new features; do not require fresh E2E evidence or changes to `AGENTS.md` for those operations. Existing unit tests must still be run.

Re-read the project-level `AGENTS.md` in `<worktree>`, because the user may have changed it since preflight.

- **missing**: ask the user with `ask_user` to either add instructions to `AGENTS.md` on how to test newly added features end to end by walking through the user journey in an isolated environment, explicitly stating that the agent runs these E2E tests only when a feature is first added, future pushes and deployments do not require rerunning them, and existing unit tests must still be run, or add a note to `AGENTS.md` that e2e testing is not needed for this repository. Wait for their answer, then re-read the file. Do not deliver while the status is still missing.
- **not needed**: skip this phase and record that in the report.
- **instructions**: hand the journey to a fresh `worker` on `magpie/gpt-6.1-sol` at thinking `medium`, launched as `runs.run("e2e-journey-r1", { label: "E2E · journey r1", phase: "e2e", agent: "worker", model: "magpie/gpt-6.1-sol:medium", task })`, so the test environment's commands and logs stay out of your context. Its brief, `<run dir>/e2e-brief.md`, holds the `AGENTS.md` e2e instructions, the plan's E2E journey, `<worktree>`, and `<branch>`. Require the worker to:
  - run everything from `<worktree>`, so the test environment runs the feature branch; when final checks overlap, use the supplied pinned artifact/manifest rather than a mutable development server, and verify the snapshot before and after testing;
  - bring up the test environment and walk through the journey step by step, keeping the evidence (commands, output, screenshots, or logs) under `<run dir>/e2e/`;
  - report each step's expected result, actual result, and evidence paths;
  - not edit product code;
  - on a failed step, reproduce it once and state its root-cause hypothesis;
  - leave the test environment up when a step failed, so the rerun can reuse it.

  Check the reported results against the expected ones yourself, spot-checking key evidence by path rather than reading all of it. Confirm the root cause of each failure and send the fix to a `worker` on `magpie/gpt-6.1-sol`, under the same rules as task workers. Then rerun the affected unit tests yourself and resume the journey worker for the rerun: `resume: "<its latest runId>"`, key `e2e-journey-rN`. Allow at most three repair attempts, then ask the user. When the journey passes, have the journey worker tear the test environment down if the instructions say to.

## Deliver

On a host other than the run's `home`, stop before this section, as Resume after a host move describes.

Inspect the final diff with `git diff <base commit>...HEAD` and confirm `git status` is clean. Report the changed files and behavior, the commits on `<branch>`, each task with its review rounds, verification and e2e evidence, rulings made, deferred Minor findings, and unresolved risks. Never claim completion while required checks remain unverified.

As the final delivery step, once all required work and checks are complete, automatically merge the completed commits from `<branch>` into the repository's default branch unless the user explicitly asked not to merge (including a request to keep the branch or open a PR instead). This workflow authorizes that merge without another approval prompt. Identify `<default branch>` from the remote's HEAD or repository metadata; do not assume `<base>` is the default branch. If the default branch cannot be determined, ask the user to identify it. Follow the merge procedure below, then include the target branch, resulting commit, and verification results in the final report. If merging is blocked, report the blocker and keep the worktree. Push or open a PR only when the user explicitly asked for it.

## Merge and cleanup

At delivery, read [references/delivery.md](references/delivery.md) for the authorized default-branch merge, validation after integration, and workspace cleanup. Preserve the user's no-merge/PR choice, clean-checkout gate, final report before workspace archive, and push-only-on-request rule.

For infrastructure failures preserve the exact error and Git/worktree state, use the supported recovery path, and stop when recovery makes no progress. Do not replace the subagent protocol or invent schedulers/daemons. The installed deterministic verification helper is the supported command path.
