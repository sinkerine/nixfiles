---
name: e2e-feature
description: "Opt-in end-to-end feature workflow: a high-reasoning Pi Opus design tab in Paseo (Pi Gemini on Pi Opus quota exhaustion) that hands the plan back, Pi-sol implementation subagents, Pi Gemini review loops with high reasoning, and an AGENTS.md-driven e2e check."
disable-model-invocation: true
---

# End-to-end feature workflow

Use this workflow only when the user explicitly invokes `/skill:e2e-feature <request>`. Do not activate it for ordinary requests. This skill authorizes subagent delegation; enable the `subagent` tool if it is not loaded yet. `/skill:e2e-feature resume <handoff file>` continues a run that `e2e-dispatch` moved to this host: follow Resume after a host move instead of Preflight and Design.

You are the orchestrator, running on whatever model this session already uses; do not switch it. You coordinate four phases (design, implement, review, e2e test) and do not write feature code yourself, except for trivial integration fixes that you record as rulings.

If this skill was expanded by `/skill:e2e-feature`, its instructions are already in context; do not read this file again. Read linked references only when entering that phase.

This skill uses the Pi goal extension to execute the full approved plan. The design model decides whether the design needs human input or explicit approval. If it judges neither is needed, it may finalize the plan and send `PLAN_READY` autonomously; otherwise it asks the user and waits for the required answer or approval before handoff. Honor any explicit user request to review or approve the design. In this skill, an approved plan means either a user-approved plan or a plan finalized by the design model under this policy. Invoking this skill explicitly authorizes creating a regular goal after that design handoff; do not run a second goal drafting or confirmation round. Keep the design handoff before goal creation so automatic goal continuation cannot bypass any human-input or approval gate the design model has chosen.

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

Commit on `<branch>` only, after consolidated review acceptance unless isolation requires a recorded provisional checkpoint:

- the approved plan, as `<feature>: add plan`;
- each task once it is accepted, as `<feature>: <task id> <task title>`; combine ordered tasks sharing files into a coherent integration commit when necessary;
- each e2e repair, as `<feature>: fix <what>`.

Commit only the files the step changed. Keep generated artifacts and secrets out. Never commit to `<base>` directly.
## Workflow layout

Default to one task implemented in one shot. Every split costs a brief, a worker startup, a gate, interface checks, and integration risk, and recent runs show first-pass implementation is only about a quarter of child time. Split only when the plan records a concrete need that one worker cannot meet:

- **Separate producer:** an external repository, service, or artifact another task consumes, or work that must land and be verified first.
- **Real parallel gain:** independent modules with disjoint files and checks, each substantial enough that running them concurrently clearly shortens the critical path.
- **Context limit:** the combined change is too large for one worker to hold and verify coherently.

Do not split by file, layer (model/UI/tests), implementation step, or to create parallel work, and never separate code from its wiring or tests. Each split records its reason as `Split: <reason category> — <why one worker cannot do it>`. Apply this bar both during design and when revising tasks after a blocker.

Every subagent this workflow launches is a direct child of you; workers and reviewers never get the `subagent` tool, so agent depth is always one. Task dependencies decide launch order only. They form a graph, not a tree, so never express them as nesting.

Waves describe the dependency graph; they are not whole-wave barriers unless the approved plan explicitly requires one. Launch a ready task once its dependencies are implemented (independent host gates pass and produced interfaces match the plan) and its owned files and verification inputs are compatible with every running task. Keep shared files, mutable generated inputs, and unstable interfaces ordered. Prioritize ready tasks with the longest downstream chain without inventing duration estimates. Review begins after all implementation finishes; only an explicitly planned early focused review may add an earlier review gate. Acceptance follows consolidated review, and commits wait for a safe point with no live workers or reviewers. Never change `HEAD` underneath a review.

Group the run as one Workflow row with one row per task:

- **Workflow row.** Create one mission before the first launch with `subagent({ action: "mission.create", options: { mission: { title: "e2e-feature: <feature>", objective: "<one-line goal>" } } })`, and pass its `missionId` to every later launch so all children collect under it.
- **Task rows.** Launch each child from a workflow script, a ```` ```js workflow ```` block sent with `subagent({ workflow: true, async: true, cwd: "<worktree>", options: { missionId: "<mission id>" } })` in the same reply, using `runs.run(key, { label, phase, agent, task })`. One reply carries one block. Always set `phase` to the task id from the plan (or `review` for consolidated review); it is what nests a run under its task row, and a run without it shows flat under the Workflow row. The key is stable and lowercase, `<task>-<step>`; the label is `<task> · <step>`, where `<step>` is `implement`, `review rN`, `fix rN`, or `journey rN`. Use `e2e` for E2E journey and repair work and `review` for consolidated review scopes. For example, the second feature review is `runs.run("review-feature-r2", { label: "Review · feature r2", phase: "review", agent: "reviewer", model: "magpie/group/gemini-4:high", task })`. When a script launches several tasks from a list, set `phase: item.id` on each run.
- **Subtitles, not nesting.** Put a task's wave and dependencies in its row summary, such as `wave 2 · after T1, T2`, with its state: `pending`, `implementing`, `implemented (awaiting feature review)`, `fix rN`, `accepted`, or `needs human`. Give the Review row its scope and round.

Whenever you report progress, list completed implementation tasks on one line each and expand only active work. Keep consolidated review in its own row:

```
Workflow: e2e-feature: <feature>
├─ Design (Pi Opus / Pi Gemini tab)      ✓ plan approved
├─ T1 · wave 1                          ✓ implemented · awaiting feature review
├─ T2 · wave 1                          ✓ implemented · awaiting feature review
├─ T3 · wave 2 · after T1, T2            ⟳ implementing
│   └─ implement                        ⟳ running
├─ T4 · wave 2 · after T1                ✓ implemented · awaiting feature review
├─ T5 · wave 3 · after T3, T4            · pending
├─ Review · complete feature            · after all implementation
└─ E2E                                  · pending
```

## Orchestrator turns

Every turn you take re-reads this whole session, so turns get more expensive as the run grows. Keep them few and small:

- After launching async work, end your turn when nothing the plan requires is runnable. pi-subagents wakes you when a run finishes, fails, or needs a supervisor decision, and the goal extension holds its automatic checkpoints while your runs are active. Do not poll `status`, repeat progress reports, or fill the wait with work the plan does not need. A routine intermediate notice needs no action unless it is a designated task boundary. A gated implementation launched with `notifyOnComplete: true` is a task boundary: read its saved report and gate receipt, confirm its produced interface, and release compatible dependencies without waiting for siblings. Review notifications serve the later consolidated review and repair phase.
- Keep tool output small: tail or grep logs, read files by line range, cap command output, and never read binary files. Write briefs, findings, and diffs to files under `<run dir>` and give subagents the paths instead of pasting the content into your own context.
- Use the launch templates in this skill instead of looking up subagent syntax with `subagent({ action: "guide" })`. Once the execution goal is active, after required bookkeeping and async dispatch, make `update_goal({continuation: {kind: "ready"}})` the last tool call and yield. When only a separate producer can make progress, declare its source-specific message wait as in `references/waiting.md`; never checkpoint repeatedly to say you are waiting.
- Save tasks, rulings, input identities and receipt paths before a phase boundary. If context is large, compact once at that boundary using the supported session control; resume from those files and `get_goal`, without rereading complete transcripts or recreating the goal.
- Return compact workflow receipts (`ok`, task, stage, `runId`, `outputReference`, and artifact paths). Save reports with `output` and `outputMode: "file-only"`; read findings by path when judging a review. Do not return `impl.output` and `review.output` together. Persist the full approved goal objective, but filter a verbose creation result through codemode before displaying it; keep only the goal id and status, never echo the objective.
- An inactivity notice alone does not establish a stall. Inspect the named run once; preserve an active command or model request and wait for completion. Do not send routine continuation nudges, restart it, or launch replacement work while it is still active.

## Run state on disk

Keep the run's state in files as you go, not only in this session, so a new orchestrator can continue the run after a host move or a lost session:

- `<run dir>/tasks.md`: one line per task with its wave, state (`pending`, `implementing`, `implemented`, `fix rN`, `accepted`, or `needs human`), its latest `writerRunId`, produced interface, gate receipt/input identity, and latest findings file. Keep consolidated scope coverage, review rounds, report paths, and acceptance in a separate `Review` entry. Update it whenever a task changes state.
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

Capture the returned agent ID and run `paseo inspect <design agent id> --json`. Require `ParentAgentId` to be `null`, and verify through Paseo's agent/workspace metadata that the agent belongs to the intended workspace. Then open it as a visible Design tab using `paseo agent open <design agent id> --json`, following Design brief and handoff below. If independence, placement, or opening fails, preserve the launch output and exact state and report the infrastructure blocker; do not silently proceed with a subagent or create duplicate design sessions.

### Pi Opus quota fallback

If Pi Opus is already known to be out of quota, launch Pi Gemini directly instead. If the Pi Opus design launch or a later design turn reports quota exhaustion or a usage limit that blocks design, replace that design tab with Pi Gemini automatically; do not wait for a quota reset or ask the user to approve the substitution. This exception applies only to Pi Opus quota exhaustion, not unrelated launch or infrastructure failures.

Before replacing an existing Pi Opus tab, preserve its agent ID, exact quota error, and any available design context. Prepare a replacement brief containing the original brief, the current plan file if present, and the design decisions, unresolved questions, and approval status available from the Pi Opus session. Archive the blocked Pi Opus agent with `paseo archive <old design agent id>` before launching the replacement, so only one design tab remains active. If Pi Opus never created an agent, skip the archive step.

Launch the replacement as an independent agent in the same workspace and worktree, keeping the original title and orchestrator's `PLAN_READY` handoff:

```bash
env -u PASEO_AGENT_ID paseo run --no-wait --json \
  --provider pi/magpie/group/gemini-4 --thinking high \
  --workspace <workspace id> \
  --cwd <worktree> --title "Design: <feature>" \
  "$(cat <replacement brief file>)"
```

Apply the same independence and workspace checks to the replacement, and open it as a visible tab with `paseo agent open <replacement design agent id> --json` under the same mandatory opening and failure rules below. Then record its ID as the current design agent ID for all later messages and cleanup. Tell the user Pi Opus exhausted its quota and the design tab now uses Pi Gemini with high reasoning. Continue the existing design and approval process from the preserved context; replacing the tab does not approve the plan. If the fallback fails, preserve the exact error and report the blocker rather than repeatedly creating agents.

### Design brief and handoff

Every design session must open as a visible tab in Paseo Desktop, including a quota-fallback replacement. Creating an agent or finding it in the workspace's agent list does not satisfy this requirement. After verifying independence and workspace placement, run `paseo agent open <design agent id> --json` and require a successful open result before handing design to the user. Do not claim it is open or focused merely because creation succeeded. The open command requires a Desktop installation on the CLI machine; on a remote or headless host, or any open failure, preserve the existing design agent ID and exact error, report that opening the visible Design tab is blocked, and stop the handoff until opening succeeds. Do not substitute an instruction to find the agent in the agent list, create duplicate sessions, install Desktop, or change daemon configuration to satisfy this gate.

Write the brief to a temporary file first. It contains the user's request, what you learned in preflight, and these instructions:

> You are the design agent for this feature. You work in the feature worktree `<worktree>` on branch `<branch>`; do not edit anything outside it. Design the feature in this tab, exploring the code as needed. Use your judgment to decide whether human input or explicit approval is needed. If neither is needed, finalize the design autonomously; if either is needed, ask the user and wait for the required answer or approval. Honor any explicit user request to review or approve the design. Record your decision and rationale in the plan, including any human-input or approval gate and its resolution. Do not implement the feature or commit. The outcome of this session is one file, `<worktree>/docs/features/<feature>-plan.md`, which you keep up to date as the design evolves. It must contain these sections:
> - **Goal and acceptance criteria**: target behavior, then numbered criteria `AC1`, `AC2`, … that define feature readiness. Each criterion states one observable behavior or robustness property (correct results, error and failure handling, recovery, data integrity, concurrency, compatibility with existing callers), every user entry path or variant it must hold on (for example each editor, room vs thread, encrypted vs plain), and the exact evidence that proves it: a unit test, a check from Test and verification, or an E2E journey step. Write verification criteria, such as baseline comparisons, in the exact wording acceptance will be judged by. Do not add criteria for code style, naming, formatting, or speculative hardening; repository lint and format checks cover style. Number required decisions `D1`, … and required documentation items so they can be traced the same way.
> - **Design**: implementation details, including module boundaries, data flow, interfaces with exact signatures, error handling, and the conventions to follow.
> - **Tasks**: default to a single task `T1` covering the whole feature, implemented in one shot. Split only for a separate producer (an external repo, service, or artifact consumed later), a real parallel gain (independent substantial modules with disjoint files and checks that clearly shorten the critical path), or a context limit (too large for one worker to hold and verify coherently). Never split by file, layer, implementation step, or for parallelism alone, and never separate code from its wiring or tests. Give each additional task a `Split: <reason category> — <why one worker cannot do it>` line. For each task, include an id, its goal, the files it owns, the interfaces it consumes and produces, its dependencies on other task ids, and the unit test command that proves it is done. Group tasks into waves for presentation, with explicit dependencies and file/build conflicts controlling launch. Concurrent tasks must own disjoint files and their checks must pass while others are mid-edit; otherwise order them explicitly. A ready task may start once its dependencies pass independent host gates and their produced interfaces match this plan, before unrelated tasks finish and without waiting for review. Default to consolidated review after all implementation; explicitly identify any consequential interface or architectural uncertainty requiring an early focused review. Identify external dependencies and which local tasks can proceed without them.
> - **Test and verification**: the complete unit, integration, lint, type, build, coverage, and visual check inventory required by the repository and request. Include exact commands, current runner and test-project discovery, environment prerequisites, generated inputs, concurrency conflicts, and which commands generate or rewrite files. Identify equivalent coverage/unit commands and reusable checks without reducing test scope. Include an isolated smoke check and cross-project dependency compatibility requirements.
> - **E2E journey**: the user journey that proves the feature works end to end, written as steps with expected results.
>
> When the plan is complete and any required human input or approval has been received, save the final file and hand it to the orchestrator by running exactly this command; `--no-wait` matters, because the orchestrator's turn lasts the whole implementation:
>
> `paseo send <orchestrator agent id> --no-wait --prompt "PLAN_READY <worktree>/docs/features/<feature>-plan.md: <finalized autonomously; human input/approval not required | approved by the user | finalized after required human input>. <one-line summary and any open notes>"`
>
> Choose the status that accurately describes the handoff; never claim user approval unless the user actually gave it.
>
> Then tell the user the plan has been handed off. If the orchestrator later sends you questions about the plan, update the file and send `PLAN_READY` again.

Record the design agent's ID, workspace ID, and successful `paseo agent open` result after verifying independence, placement, and opening. Tell the user the `Design: <feature>` tab has been opened, that the design model will decide whether it needs their input or approval, and that it will hand the plan back when ready. While design is underway, use at most 60 seconds for an environment smoke check from the existing project recipe: validate runner discovery, one existing test, browser/device availability, ports, and generated dependencies as applicable. Keep logs under `<run dir>`, avoid product edits and shared-state mutations, and report blockers for the design to resolve; do not launch a long suite or install software outside this workflow's authority. This check is setup evidence, not final feature verification. Then end your turn. Do not poll the tab. On a notification or user report that Pi Opus is blocked by quota exhaustion, apply the Pi Opus quota fallback above and hand the replacement tab back to the user. Otherwise ignore turn-finished notifications from the design tab; continue into implementation only on a `PLAN_READY` message or when the user tells you the plan is ready.

When the plan arrives:

1. Read `<worktree>/docs/features/<feature>-plan.md`. If it is missing, ask the design tab to write it with `paseo send <design agent id> --no-wait --prompt "..."` and end your turn.
2. Check that the plan records the design model's decision about human input and approval, that any required answer or approval has been received, that every section is present, every acceptance criterion has an id, its entry paths, and mapped evidence, every task has a unit test command, the dependency graph has no cycles, every task beyond T1 has a `Split:` line meeting the bar in Workflow layout, and the full required check inventory and environment recipe are explicit. Check file and build-input conflicts across tasks that can overlap, including tasks in different waves. Prepare `<run dir>/verification.md` from the approved inventory and smoke evidence. Send gaps back to the design tab the same way, and ask it to merge any split without a qualifying reason, or ask the user if a gap needs their decision.
3. When the plan is complete, commit it on `<branch>`, archive the design tab with `paseo archive <design agent id>`, create the execution goal as described below, and proceed straight into implementation without waiting for further confirmation.

## Execution goal

Before launching implementation, call `create_goal` with `mode: "regular"`. The `objective` must contain the user's request and the entire approved `docs/features/<feature>-plan.md` verbatim, including its acceptance criteria, design, every task and dependency, verification commands, and E2E journey. A file path, short summary, or just the next task is not sufficient. Include this skill's remaining execution requirements as well: implementation waves, review and repair limits, commits, full verification, E2E evidence, delivery, the automatic final default-branch merge unless the user explicitly opts out, and cleanup rules. Preserve the order and all user-approved constraints. Do not set a token budget unless the user supplied one.

Create and focus this goal directly through the extension's `create_goal` tool; do not invoke the guided `/goal` drafting flow or add a user confirmation gate after the design handoff. The design model's autonomous finalization is sufficient when it judged human input and approval unnecessary. Record the returned goal id alongside the workflow mission id. The goal covers the entire workflow, rather than one goal per worker or task. Leave unrelated open goals unchanged. If the extension or tool is unavailable, report the blocker instead of silently running without a goal.

Use the extension's task and progress tools as available to track the approved tasks, accepted reviews, commits, and verification evidence. After interruption or compaction, use `get_goal` and read the approved plan to resume the same goal without creating a duplicate. Do not claim the goal is complete while required work or checks remain outstanding. Goal continuation must respect every human-input gate in this skill. Once all required work and checks are complete, merge into the repository's default branch without another approval prompt unless the user explicitly asked not to merge. An explicit choice to keep the branch or open a PR instead can finish delivery without a merge; apply the corresponding cleanup rules.

## Resume after a host move

Read [references/host-move.md](references/host-move.md) only for `/skill:e2e-feature resume <handoff file>`. Reconstruct the existing run; preserve user pauses and the home-host delivery restriction.

## Implement

**Single-task plan (default).** Launch one `worker` for the whole feature. Its brief points to the plan path (all acceptance criteria and design) rather than pasting it, and lists the full owned file set and the unit test command. It implements, writes tests, and iterates until its unit tests pass; the host runs the gate as below. There are no dependency releases, interface handoffs, or concurrent-writer rules. If it reports a context or scope blocker, record a ruling and split only along a reason that meets the bar in Workflow layout.

**Multi-task plan.** Follow the approved dependency graph. A task starts when every dependency is implemented: its independent host gate passes and the orchestrator confirms that its produced interface matches the plan. This releases compatible dependent tasks without waiting for review or a commit. Implemented is provisional; accepted requires the completed feature review. Preserve an early focused review only when the approved plan explicitly requires it for a consequential interface or architectural uncertainty.

Launch all compatible ready tasks together in one async workflow call, with a `worker` on `magpie/gpt-6.1-sol` at thinking `medium` (`high` for a task the plan marks as subtle, or after a failed attempt). Each task runs implement → host gate, with no automatic reviewer launch. Use plain helpers returning promises and observe them with `Promise.all`; the installed sandbox rejects nested async functions. Set `notifyOnComplete: true` on implementation runs so their gated completion wakes you to release compatible dependencies while siblings continue. Launch newly ready tasks in a later turn through the same mission; do not poll. All tasks run in `<worktree>`. The plan's file/build-input conflict checks authorize concurrent writers with disjoint ownership in `<worktree>` and override pi-subagents' one-writer-per-worktree default. Use `worktree: true` only when the plan requires isolated checkouts. It branches from a clean `HEAD`; apply its returned patch at a safe idle point, independently gate the integrated result, and record any necessary pre-review checkpoint commit as provisional, not accepted.

Give each worker only its own brief, not the session history. Write it to `<run dir>/<task>-brief.md`: the task entry from the plan, relevant Design sections, consumed and produced interfaces, the unit test command, the absolute `<worktree>`, and the files other active tasks are editing. Require it to:

- edit only its owned files inside `<worktree>`;
- not commit or run commands that rewrite the index or other tasks' files, including `git add`, `stash`, `checkout`, `restore`, `reset`, `clean`, repository-wide formatters, and code generators;
- run development checks as `flock <build lock> <command>`; independent host gates use the recipe helper, which claims the legacy guard and all assigned resources. Acquire each lock once, never nest it;
- report `NEEDS_CONTEXT` or `BLOCKED` with the exact dependency when another task or an external artifact prevents progress; wait for producer completion instead of timed retries or edits to another task's files;
- implement the task and its unit tests, iterating until the test passes;
- finish with one status, `DONE`, `DONE_WITH_CONCERNS`, `NEEDS_CONTEXT`, or `BLOCKED`, followed by changed files, produced interface details, and the last test output.

Have the host run each task's unit test as a `gate` using its assigned resource lock. Inspect its saved report and gate receipt before marking it implemented; a worker's success message is never independent evidence. Reuse a valid host receipt instead of rerunning the same command. If later work changes its relevant inputs, invalidate the receipt and rerun the affected check on stable inputs before acceptance. Launch external producers as soon as approved inputs are ready; require their exact revision, existing-plus-new API compatibility, artifact digest, and copied verification report before an expensive consumer build. On `NEEDS_CONTEXT`, `BLOCKED`, or a failed gate, change the context or approach before relaunching. A failure caused by another active task needs a rerun after that producer finishes, not a speculative repair.

```js workflow
const impl = await runs.run("t3-implement", {
  label: "T3 · implement", phase: "T3", agent: "worker", model: "magpie/gpt-6.1-sol:medium",
  task: "Implement T3. Read your brief at <run dir>/t3-brief.md and follow it exactly.",
  gate: "e2e-feature-run verify --feature <feature> --recipe <run dir>/verification.json --check T3",
  notifyOnComplete: true,
  output: "<run dir>/t3-implement-result.md", outputMode: "file-only",
});
return { task: "T3", stage: "implement", ok: impl.ok, writerRunId: impl.runId, report: impl.outputReference, artifacts: impl.artifactPaths };
```

## Review

Start the consolidated feature review only after all implementation tasks and their required host gates finish, their interfaces match the plan, and no implementation writers remain. An explicit planned early review is a focused exception and never substitutes for this integrated review. Use Pi Gemini (`magpie/group/gemini-4:high`) with high reasoning for every reviewer launch, overriding the agent default. The opt-in experiment in `references/reviewer-benchmark.md` is never an extra feature stage and never changes this setting automatically.

Default to one reviewer for the complete feature diff against the recorded base commit, including uncommitted and untracked additions. For a feature too large for one coherent review, use a few reviewers with explicit nonoverlapping responsibilities and one assigned owner for cross-module integration. Record the coverage map; do not recreate one review per implementation task or add a redundant full review on top of the partitioned reviews. Each review scope gets at most 3 rounds; a failed launch does not count. A round is the initial review or a verification of repairs for confirmed Critical/Important findings or other product-behavior changes. Generated, lint-only, formatting, and test-setup deltas with passing receipts and no product-behavior change do not consume a round: record a ruling, and batch them into one uncounted delta check before acceptance only when their correctness is not obvious from receipts. Do not send verification-evidence adequacy (baselines, provenance) to the code reviewer unless the plan names it as a review item; judge it against the literal criterion with host checks. The reviewer can read files and `watchdog_diff` but cannot run commands, so save its evidence as files first.

1. **Round 1.** Write `<run dir>/feature-review-r1.md` with the approved plan path, acceptance criteria, task/interface map, base commit, stable full-feature diff (including additions), worker report paths, input identity, and host gate receipts. For partitioned reviews, use `<scope>-review-r1.md` with exact scope boundaries and integration ownership. Link design sections rather than copying them into every packet. Write packets in normal prose. Require these review rules:
   - **Acceptance trace first.** For every `AC`, `D`, and required documentation item in the plan, give one line: implementing location, the test or check proving it, and which named entry paths are covered. An item that is unimplemented, unwired on a named path, or lacks its mapped evidence is Important. For partitioned reviews, each scope traces its own items and the integration owner traces cross-scope items.
   - **Readiness and robustness, not style.** Findings are defects that make the feature not ready or fragile in real use: wrong behavior, a missed path, broken wiring or interface compatibility, unhandled errors or failures, data loss or corruption, races, security issues, or regressions in existing behavior. Do not report style, naming, formatting, comment wording, refactor preferences, or defensive checks for states the code cannot reach; lint/format gates own style. Report Minor only for a concrete, low-impact behavior issue.
   - **Literal criteria.** Judge evidence against the approved wording. A weaker substitute criterion or proof is Important unless the plan explicitly allows it. Do not repeat deterministic provenance checks already established by valid receipts.
   - **Output.** The acceptance trace, then each finding with severity, location, evidence, impact, and smallest fix, then a one-line verdict. Omit inventories of correct code and lists of gates still pending; mention unreviewed scope only when assigned scope could not be reviewed. Start with the saved diff, expanding through files, callers, or `watchdog_diff` only as needed to prove an issue or complete the trace. Do not truncate findings or impose an arbitrary timeout.
2. **Judge and group.** Check each finding against the code yourself; record rejected findings and reasons. Consolidate duplicate findings and group confirmed fixes by task ownership and root cause. If no Critical or Important findings remain across all review scopes, proceed to acceptance.
3. **Fix and verify (rounds 2 and 3).** Save a before snapshot with `sh <run dir>/snap.sh <affected files>` and confirmed findings in `<run dir>/<scope>-findings-rN.md`. Resume each affected task's latest `writerRunId` with its findings, original ownership constraints, expected fix, unit command, and required fix-delta path. Compatible fixes may run together after all reviewers reading their inputs finish. Assign one owner to a cross-task fix and explicitly update ownership before launch; never send competing workers to the same files. If retained resume is rejected or unavailable after a host move, use a fresh worker with the task brief and findings. Update writer ids and evidence paths. A retained resume cannot take a new `gate`; run affected checks through `e2e-verify` or attach a gate to a fresh verification reviewer. After all fixes in the round settle, save the combined delta and updated input identities/receipts. Launch focused verification reviews for affected scopes only. Check earlier findings as resolved or unresolved with evidence; request new findings only if Critical, or Important and introduced by the fixes. Include changed callers and interfaces when a repair crosses scopes. If the delta is empty or missing, verify each finding directly from code. Do not repeat a full-feature review after every fix.
4. **Accept and commit.** Accept tasks only when every review scope has no confirmed Critical or Important findings and every required task gate matches the final relevant inputs. Reuse passing receipts after read-only review when command, discovered scope, source/dependency/generated inputs, and environment still match; otherwise rerun affected checks through host tools. A successful child exit or worker claim is insufficient. Commit task-owned files at a safe point with no live workers or reviewers; for files touched by multiple ordered tasks, use a coherent integration commit rather than staging an artificial partial state. Never change `HEAD` underneath a review. Hooks that rewrite relevant inputs invalidate receipts and require verification and focused review of their delta. Carry Minor findings to delivery.
5. **Cap.** If confirmed Critical or Important findings remain in a scope after round 3, stop and ask the user with `ask_user`, including findings, attempted fixes, and current test output. Do not launch a fourth round without their answer.

```js workflow
const review = await runs.run("review-feature-r1", {
  label: "Review · feature r1", phase: "review", agent: "reviewer", model: "magpie/group/gemini-4:high",
  task: "Review the completed feature. Read <run dir>/feature-review-r1.md and follow it exactly.",
  notifyOnComplete: true,
  output: "<run dir>/feature-review-r1-result.md", outputMode: "file-only",
});
return { scope: "feature", stage: "review r1", ok: review.ok, reviewRunId: review.runId, report: review.outputReference, artifacts: review.artifactPaths };
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

Inspect the final diff with `git diff <base commit>...HEAD` and confirm `git status` is clean. Before merging, self-audit the way the goal's completion auditor will: for every `AC`, `D`, required documentation item, and verification criterion, confirm current evidence meets the approved wording on every named path. Close any gap before the merge, not after it. Report the changed files and behavior, the commits on `<branch>`, each task’s acceptance and the consolidated review scopes/rounds, verification and e2e evidence, rulings made, deferred Minor findings, and unresolved risks. Never claim completion while required checks remain unverified.

As the final delivery step, once all required work and checks are complete, automatically merge the completed commits from `<branch>` into the repository's default branch unless the user explicitly asked not to merge (including a request to keep the branch or open a PR instead). This workflow authorizes that merge without another approval prompt. Identify `<default branch>` from the remote's HEAD or repository metadata; do not assume `<base>` is the default branch. If the default branch cannot be determined, ask the user to identify it. Follow the merge procedure below, then include the target branch, resulting commit, and verification results in the final report. If merging is blocked, report the blocker and keep the worktree. Push or open a PR only when the user explicitly asked for it.

## Merge and cleanup

At delivery, read [references/delivery.md](references/delivery.md) for the authorized default-branch merge, validation after integration, and workspace cleanup. Preserve the user's no-merge/PR choice, clean-checkout gate, final report before workspace archive, and push-only-on-request rule.

For infrastructure failures preserve the exact error and Git/worktree state, use the supported recovery path, and stop when recovery makes no progress. Do not replace the subagent protocol or invent schedulers/daemons. The installed deterministic verification helper is the supported command path.
