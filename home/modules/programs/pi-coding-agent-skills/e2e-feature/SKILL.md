---
name: e2e-feature
description: "Opt-in end-to-end feature workflow: Pi Opus orchestrates with Sol as the quota fallback, a separate visible Gemini Paseo tab designs, Gemini Speed implements and repairs in a subagent, and separate Sol children review and verify. The orchestrator coordinates without implementing."
disable-model-invocation: true
---

# End-to-end feature workflow

Use only when the user explicitly invokes `/skill:e2e-feature <request>` or `/skill:e2e-feature resume <handoff file>`. Authoring or discussing this skill does not start a feature run. Invocation authorizes the independent design tab, direct execution/review/verification subagents below and one execution goal after final plan approval. Enable the `subagent` tool if necessary. Read linked references when entering their phase.

## Roles and model routing

| Role | Session/profile | Exact model | Thinking | Authority |
| --- | --- | --- | --- | --- |
| Orchestrator | Main session | `magpie/group/opus` → `magpie/group/sol` on quota exhaustion | medium | Coordinate, inspect evidence, decide acceptance, track goals and deliver |
| Design | Independent visible Paseo tab | `magpie/group/gemini` | high | Explore, write the plan and obtain human approval; no implementation |
| Executor | Direct `worker` subagent | `magpie/group/gemini-speed` | medium | Implement, prepare tooling, write tests, diagnose and repair |
| Reviewer | Direct `reviewer` subagent | `magpie/group/sol` | medium | Independent read-only code review |
| Verifier | Direct `worker` subagent | `magpie/group/sol` | medium | Independent checks, capability probes and E2E; no code repairs |

Design runs as an independent top-level Paseo agent opened in a visible Desktop tab, following [references/design.md](references/design.md). Do not launch design through `subagent`, agent-scoped creation or create-then-detach. Executor, reviewer and verifier run through `subagent` as direct children of this session. Reviewer and verifier are separate fresh-context children, never the executor or each other resumed under another role. Neither the design agent nor children may subdelegate. Explicitly pass the model on every initial launch; agent defaults do not select these roles. Resume children only within the same role using the latest returned run id, preserving model and tools. Keep the listed models for design and the three child roles.

Start a fresh orchestrator with `pi-opus --thinking medium` or launch it in Paseo on `pi/magpie/group/opus` with medium thinking. The `e2e-feature-routing` Pi extension configures the model and thinking level on skill invocation. When the current orchestrator model runs out of quota, the extension switches to the next model in the table and continues the interrupted turn in the same session. The selection persists on session resume. The final model's error is surfaced if it also runs out of quota.

Before any design or child launch or goal creation, verify the main session uses a model from the orchestrator row with medium thinking. If the active model or thinking level cannot be confirmed, stop at this routing gate and tell the user what needs to be verified.

The orchestrator does not implement, write or repair product code, tests, harnesses, environment scripts, or resolve merge conflicts. Route all such work to the executor. It may write orchestration briefs and run-state records, inspect code and receipts, run read-only metadata/resource checks, create workspaces and goals, and perform clean Git commit/merge delivery. The design tab owns the plan file. The executor owns all other task source/documentation changes, including repository `AGENTS.md`, verification recipes and integration repairs. The verifier may create isolated test state and evidence and run authorized setup/teardown; it must not edit product, harness or regression-test sources. Do not use host commands, native workflows or another CLI to bypass these boundaries.

## Approval and autonomy

Obtain explicit human approval of the completed plan before implementation, including capability-tooling changes. Answering design questions, invoking the skill, silence, and model self-approval do not approve a plan. The design tab presents the completed plan and requests final approval with `ask_user` before sending `PLAN_READY`. It records the exact reviewed revision and approving response in the plan's **Approval** section; the orchestrator verifies that evidence and records its reference in `<run dir>/approval.md`, without a duplicate approval request. One correlated explicit response, including one delivered asynchronously, covers this gate. Approval/status metadata alone does not invalidate it. Material changes to scope, behavior, acceptance criteria, design or authorization require renewed approval; editorial clarifications can retain approval with a recorded reason.

Ask only for genuine unresolved requirements or authorization, destructive/irreversible or security-sensitive operations, unauthorized external side effects, or a named human gate. Ordinary implementation decisions, test failures, review findings and repairs proceed autonomously through the executor. Record nontrivial decisions as `Ruling: <decision> — <why> — <cost if wrong>` in `rulings.md`. Never ask whether to continue fixing an implementation defect or accept broken behavior.

## Preflight and isolation

1. Inspect Git status, repository instructions, the current Paseo workspace and worktree metadata. Preserve unrelated staged, unstaged and untracked work. Pick a lowercase `<feature>` slug.
2. Reuse the current Paseo-owned Git worktree when one exists. Otherwise create a new Paseo worktree workspace for this project, based on the current branch unless specified otherwise: `paseo workspace create --isolation worktree --mode branch-off --new-branch feat/<feature> --base <base> --project <project-id> --title "<feature>" --json`. Discover the project from current workspace/registry metadata; inspect CLI help if flags differ. Verify the returned workspace, path, branch, base and owning project. Launch the fresh Pi Opus orchestrator there with the original request and `/skill:e2e-feature` invocation, then yield. Do not edit the main checkout as a fallback.
3. Record `<worktree>` from `git rev-parse --show-toplevel`, `<git dir>` from `git rev-parse --absolute-git-dir`, the workspace id, current branch, base ref from `paseo/worktree.json` (`baseRef`, otherwise `baseRefName`), and base commit from `git merge-base HEAD <base>`. Read the branch again before delivery because Paseo may rename placeholders. `<repo root>` is the first worktree in `git worktree list --porcelain`. All task edits stay in `<worktree>`.
4. Use `<run dir> = <git dir>/e2e-feature/<feature>` and `<build lock> = <git dir>/e2e-feature-build.lock` so the existing deterministic runner works. Run `e2e-feature-run init --feature <feature>`. Record `workflow: e2e-feature`, the role/model table and actual session identity in run state.
5. For an initial feature, classify root `AGENTS.md` as journey instructions, explicit E2E exemption, or missing. A journey must exercise the real user path in isolated state (VM, container, disposable environment or isolated local stack). Report missing instructions during design; they block E2E until the user supplies the journey or explicitly exempts the repository. Non-feature changes skip this classification and E2E. E2E runs when a feature is first added, including its repairs/reruns; future pushes/deployments do not require it. Existing unit tests still run. Any testing policy the executor adds must preserve this scope.
6. For any E2E workload, read [shared qex resource format and approval rules](references/qex-resources.md). Inspect actual stack/worker settings and validate root declarations with `agent-job estimates --cwd <worktree>`. Before a first declaration or new variant, the orchestrator presents concrete CPU/RAM claims, setup → test → teardown scope, worker limits, locks/timeouts, uncertainty, destination budget and queueing implications with `ask_user`. Wait for explicit choice before any probe or execution. The executor records the selected declaration and decision reference beside it in root `AGENTS.md` and in the plan/run record. Reuse applicable declarations without duplicate questions; the verifier cannot select new costs.
7. Create one mission before the first child: `subagent({action: "mission.create", options: {mission: {title: "e2e-feature: <feature>", objective: "<goal>"}}})`. Pass its `missionId` to all launches.

## Child dispatch and run state

Use explicit `cwd: "<worktree>"`, file-backed briefs, `output` paths and `outputMode: "file-only"` for executor/reviewer/verifier children. The following is an executor launch template; fill the concrete absolute paths and mission id before calling it. Launch the design tab only as described in [references/design.md](references/design.md).

```js workflow
const execution = await runs.run("execute-t1", {
  label: "Implement · T1", phase: "implementation", agent: "worker",
  model: "magpie/group/gemini-speed:medium",
  task: "Act only as the executor. Read <run dir>/executor-brief.md and follow the executor contract. Implement the approved assignment, run permitted development checks and save a stable checkpoint. Do not subdelegate or perform independent acceptance.",
  notifyOnComplete: true,
  output: "<run dir>/execute-t1-result.md", outputMode: "file-only",
});
return { ok: execution.ok, runId: execution.runId, report: execution.outputReference, artifacts: execution.artifactPaths };
```

Send the block with `subagent({workflow: true, async: true, cwd: "<worktree>", options: {missionId: "<mission id>"}})` in the same reply. Use stable keys, meaningful labels and phases (`implementation`, `review`, `verification`, `e2e`). For a completed executor, resume via a new key with `{resume: "<latest executor run id>", task: "Read <new brief>...", ...}`; omit `agent` and `model` on resume. Steer live children; never start a replacement writer concurrently. Stop and report launch/runtime failures, preserving the exact error and partial state; use supported recovery rather than switching to shell-launched agents.

Only one source writer may be active in a worktree. Design finishes before execution; executor children run sequentially, normally by resuming one executor through milestones and repairs. Freeze source, generated inputs and HEAD while reviewers/verifiers read them. Concurrent verification groups require proven input/output isolation, distinct resources and bounded concurrency. The parent must not edit tracked run documentation or commit under active readers. No implementation fanout.

Maintain these records on meaningful state changes:

- `tasks.md`: dependencies, owner role/session and latest run id, changed paths, produced interfaces, checkpoint, criterion → test map, evidence identities and task state (`pending`, `implementing`, `implemented`, `fix rN`, `accepted`, `needs human`). Track review scopes, round counts and acceptance separately.
- `verification.md` and `verification.json`: complete check inventory, prerequisite graph, environment recipe, resource groups/locks, bounded concurrency, discovered tests, source/artifact identities, receipt/log paths and passed/failed/unrun/invalidated coverage.
- `status.md`: capability status, accepted milestones, active work, required journey windows passed/discovered, remaining checks/platforms, exact blocker, blocked-since time, next action/owner and supported wake/deadline. Use host timezone for user-facing timestamps.
- `rulings.md`, `diagnosis.md`, `approval.md`: decisions, tested hypotheses/failed experiments/next discriminating experiment, and human approval evidence. Preserve plan path/revision, goal/mission ids and live child/job identities at phase boundaries.

Keep logs on disk and return compact receipts. After async launch, do independent required work or yield; native completion wakes this session. Do not poll, sleep, call `bg_wait` for ordinary children or invent a watchdog. Read the [shared waiting/runtime contract](references/waiting.md) for source-specific external waits and recovery, using the role assignments above. An inactivity notice or blank transcript alone does not prove a stall. Preserve live commands and supported continuation. Compact at stable checkpoints; never create a duplicate goal or change role ownership because context grew.

## Design and execution goal

Launch and open the independent Gemini design tab following [references/design.md](references/design.md). Give it the request, instructions, inspected Git/workspace state, known environment constraints and the E2E classification. It explores the real code and writes `docs/features/<feature>-plan.md` containing:

- The problem, scope/exclusions, behavior and design decisions, protected state and side-effect boundaries.
- Numbered acceptance criteria (`AC`), required documentation (`D`), real entry paths, introduced state/lifecycle transitions, implementing surfaces and a criterion → test/evidence map.
- Normally one coherent task T1 containing code, wiring and tests. Additional sequential milestones require `Split: <reason> — <why a separate checkpoint is needed>`, explicit dependencies, owned paths and produced/consumed interfaces. No implementation fanout.
- Exact unit, regression, typecheck/build, consumer/interface and other required commands; complete discovery and prerequisites; environment/setup/reset/teardown recipe and resource/output ownership.
- Initial-feature E2E journey windows/variants and expected results, critical capability probe, isolation, evidence precision/cadence and resource-cost proposal/reference where required; explicit exemptions or missing decisions.

While design runs, the orchestrator may spend at most 60 seconds on read-only host capability checks: memory/disk, tools/dependencies, runner discovery, device/display access, ports and existing environment metadata. Mark unexercised capabilities unknown and send blockers to design. Execution of tests, setup or smoke commands belongs to the executor/verifier, including during design; no unapproved capability workload.

On `PLAN_READY` or a user report that the plan is ready, inspect plan completeness, dependency ordering and the design tab's recorded human approval. Return gaps to that same tab with `paseo send <design agent id> --no-wait --prompt "..."`; material changes require renewed approval there. Missing or ambiguous approval blocks handoff until the design tab resolves it. Reuse a valid correlated approval without asking again. Commit the approved plan at a safe point on the feature branch, archive the design tab with `paseo archive <design agent id>`, then call `create_goal` once with the original request and entire approved plan verbatim, plus the remaining workflow requirements: capability checks, executor-owned implementation/repairs, independent review/verification, three-round review cap, evidence and reporting, commits, E2E scope, delivery/default-branch merge and cleanup. Do not supply a token budget unless the user did. Record the goal id; missing goal tooling is a blocker. A plan path/summary alone is not the objective. Do not create the goal before approval.

## Capability and implementation

Before substantial initial-feature implementation, prove the hardest representative test path on each materially different target environment. Assign setup/tooling and the smallest necessary vertical slice to the executor, then execution and observation to the verifier on frozen inputs. The probe must reach the real entry path, establish authoritative readiness, perform a representative action and collect evidence at the approved precision/cadence. A generic launch/version check is insufficient. Baseline feature assertions may fail; preserve evidence that observation works and the harness detects the failure. Resolve testability blockers through the executor before broad implementation. Preserve the resource-choice gate even for probes. Exempt/non-feature work does not acquire an E2E requirement from this phase.

Use [references/executor.md](references/executor.md) for every implementation, tooling, documentation, diagnosis, conflict-resolution or repair assignment. The executor uses `magpie/group/gemini-speed:medium` and owns all such edits. The orchestrator coordinates milestones and inspects the executor's reports; it never takes over implementation. All Gradle builds and complete E2E stacks, including probes and reruns, execute only through the independent verifier under [references/verifier.md](references/verifier.md). Executor development checks that need neither run directly under existing locks.

Reuse the existing runner and [shared verification recipe/receipt format](references/verification.md), [project recipe generators](references/projects.md) and [timing/evidence guidance](references/latency.md). Assign source/recipe generation and artifact preparation to the executor; independent acceptance checks, including ordinary non-qex commands and native helper invocation, to the verifier. The orchestrator only inspects the saved evidence. Pin artifacts before parallel readers; serialize shared generated outputs, endpoints/devices and Android build/emulator phases. Reuse matching receipts after read-only review; relevant source/environment/artifact changes invalidate affected evidence.

## Independent test gate and review

After implementation settles, have the verifier independently check the approved inventory and criterion → test map: each `AC`, `D` and documentation requirement has an existing check, each real entry path and state transition is asserted, baseline-failure evidence exists or its limitation is justified, consumer/interface checks pass, and required checks have passing receipts on current inputs. Read test assertions, not just implementation claims. Inspect its report before review. Gaps return to the executor, followed by fresh independent affected checks. The test gate consumes no code-review round.

Launch a fresh `reviewer` on `magpie/group/sol:medium` only after the integrated feature and test gate are ready and all relevant inputs/HEAD are frozen. Normally review the entire diff against the recorded base, including uncommitted/untracked additions. A large feature may use nonoverlapping scopes with an explicit integration owner, without redundant full review. An early focused review requires the approved plan and does not replace integrated review.

The review packet contains the approved plan and approval reference, exact scope, base/source identities, complete saved diff, executor checkpoint, criterion/test map, independent gate receipts and relevant caller/interface context. The reviewer is read-only and cannot run commands; save evidence before launch. Require:

- An acceptance trace for each assigned criterion: implementation, proving test/check and covered entry paths. Missing or weaker implementation/wiring/assertions are Important.
- Findings concentrated on state/lifecycle/resume/retry/concurrency, external contracts/callers/types, failure paths, security/data exposure and realistic regressions. Propose the regression test for a missed transition.
- Severity (Critical/Important/Minor), location, evidence, impact and smallest fix, then a verdict. Omit style/refactor preferences and hypothetical impossible states.

The orchestrator judges findings against code and approved behavior, records rejections with reasons, and groups accepted repairs by root cause. Send repairs to the executor after readers settle, with frozen before identity, protected boundaries and expected red-then-green regression evidence. The independent verifier checks the result. Resume/fresh-launch only the same role as appropriate; never turn the reviewer/verifier into a repair worker.

Each scope has at most three reviewer examinations across the entire run, including E2E/delivery repairs; failed launches do not count. Never reset/rename scopes to bypass the cap. Use focused follow-up for changed state/lifecycle, external contracts or security; do not repeat full review. Local fixes with failure-first regressions and independent passing receipts, or generated/formatting/setup-only deltas without behavior change, can be accepted by orchestrator inspection with a recorded ruling. After round three, no more reviewers for that scope: continue executor repairs and independent verifier checks until all confirmed Critical/Important findings are resolved. Repairs/reruns have no attempt cap. After two unchanged failure signatures or 20 minutes of active investigation without new evidence, require the executor's diagnosis record and a changed discriminating experiment; exclude command/resource/human waits.

Accept only when all required evidence matches final relevant inputs and no confirmed Critical/Important findings remain. Commit only task-owned files after readers finish; combine milestones sharing files coherently. Hooks changing inputs invalidate affected evidence. A successful child exit, executor assertion or queued job handle is not proof. Carry Minor findings into delivery.

## Final verification and E2E

The independent Sol verifier owns final required checks and, when initial-feature E2E applies, the complete root-`AGENTS.md` journey on pinned final inputs. Require per-step expected/actual results and passed/failed/unrun/invalidated windows; a focused diagnostic probe is not a full journey pass. Missing journey instructions require the user's concrete instructions or explicit exemption; ordinary environment/setup failures return to the executor, without weakening acceptance. Reuse existing resource choices and valid receipts. After any repair, revalidate artifacts, affected gates and the complete required final journey; preserve review counters.

Only the verifier loads `~/.config/qex/AGENT.md`. Qex covers Gradle builds and complete E2E stacks; other checks run directly under their locks. The verifier owns admission, test-stack lifecycle and teardown, with retained host/job identities. No parent reservation around queued leaves, no nested admission, no unqueued fallback after rejection. Failure evidence returns to the orchestrator for an executor repair assignment.

## Delivery and cleanup

After all work/checks pass, commit remaining workflow-owned files on the feature branch with no active source readers/writers. Inspect status/diffs and stage explicit owned paths; exclude unrelated changes, generated files and secrets. Commit messages are chosen by the orchestrator. Do not mark the goal complete before delivery.

Default delivery merges into the repository's local default branch unless the user explicitly chooses a retained branch or PR. Discover the actual default branch, fetch its upstream when configured, and merge that ref into the feature branch first. All conflicts are resolved by the executor within the approved behavior, followed by independent checks for changed inputs and required initial-feature E2E. The orchestrator never implements a conflict resolution. If Git conflicts on the target checkout, abort that merge and return to feature-branch integration.

Locate the default-branch checkout via `git worktree list --porcelain`. Require it to be clean before merging; if dirty, preserve it and ask for the concrete delivery decision, never stash/reset/discard. If the branch is not checked out, use the clean feature worktree to check it out, merge, then return to the feature branch. Squash only when instructed. Confirm ancestry (or patch equivalence for squash), clean target status and resulting commit. Push only when requested. Record feature/target commits and evidence. Mark the goal complete only after these gates, or the user's explicit alternative delivery, pass.

Tear down only owned test environments, settle every child/command, confirm the design tab is archived and preserve durable evidence. Archive only a clean merged workspace, or on explicit discard authorization. Deliver the final report first; tell the user to archive from Paseo, or archive as the last command if explicitly requested. Leave retained-branch workspaces in place and delete branches only when asked. Report outcome, relevant commits, verification/evidence and material gaps briefly.

## Resume and host placement

For `/skill:e2e-feature resume <handoff file>`, reconstruct the existing worktree/run from the handoff, approved plan, approval record, tasks/status/diagnosis, Git state and saved reports. Preserve approvals, review counters, partial diffs, resource choices and user pauses. Confirm old writers have stopped before resuming the executor; host-local child ids cannot be resumed on a different host. Recreate executor/reviewer/verifier direct children with the exact models above, current source identities and latest checkpoints. If design is still underway, restore it as an independent visible Gemini Paseo tab under the design reference, preserving decisions and approval evidence; never replace it with a subagent. Revalidate host-dependent receipts and artifact identities. Adopt a goal only on an explicit same-host handoff; after a host move create a host-local continuation goal from the full approved plan, immediately preserving any user pause and asking before continuing it.

Before transferring work, check the actual destination's disk/RAM, tools/ABI/device/display, isolation and remaining critical test path. Prefer an already supported isolated remote verifier job when authorized and useful. Preserve exact source/artifact and owning host/job identities; a host move does not transfer qex admission. Before registering for automatic dispatch, confirm the destination has this executor-based skill installed as `/skill:e2e-feature` and the handoff preserves the run state and role assignments above. Report the specific compatibility blocker if dispatch cannot preserve them. A moved run may verify on a capable destination, but default-branch merge/push/archive stays on its recorded home host unless explicitly authorized otherwise.
