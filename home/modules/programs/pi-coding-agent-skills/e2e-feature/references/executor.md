# Gemini Speed executor contract

Launch a direct `worker` subagent on `magpie/group/gemini-speed:medium`. This is the sole implementation role for `/skill:e2e-feature`. Normally resume its latest completed run for sequential milestones, tooling, integration and repairs. Do not subdelegate. The orchestrator coordinates; separate Sol children review and verify.

The parent writes an assignment brief containing: absolute worktree and branch/source identity; approved plan and approval reference; task/dependencies and acceptance criteria; owned product, harness, regression-test, tooling and documentation paths; protected behavior/state and external side-effect limits; produced/consumed interfaces; environment/setup/teardown authority; exact development commands and locks; pending readers/jobs; report/checkpoint paths; and completion conditions. Repair briefs additionally include the failure, before identity, confirmed findings, evidence, current hypothesis and required regression. Missing scope/authorization decisions go to the parent through `contact_supervisor`; routine implementation decisions do not require user permission.

## Work and evidence

- Work only in the approved paths inside the task worktree. Preserve unrelated changes and protected behavior. Wait until affected reviewer/verifier readers finish before changing source or generated inputs. Do not commit, merge, push, activate production configuration, archive workspaces or change goals; delivery and orchestration belong to the parent.
- Own implementation, wiring, tests, capability tooling, maintained project recipes, documentation and all related repairs, including approved merge-conflict resolutions. Reuse existing tooling first. Install through Nix when repository policy requires it. Put large rebuildable outputs and disposable test environments under `${XDG_CACHE_HOME:-$HOME/.cache}/dev-scratch/<project>/<workspace-or-run>/`; keep useful reports and recovery state durable. Preserve isolation, locks and cleanup ownership.
- For each behavior criterion, write the acceptance test first, run it on the unchanged baseline and record the expected failure or concrete reason it cannot run there. Then implement and show it passing. Apply the same red-then-green rule to repair regressions. Do not weaken, skip or mock away required behavior. Exercise all named real entry paths and state transitions, and preserve checks for consumers of changed interfaces.
- Run ordinary development checks directly under existing locks, normally `flock --close <build lock> <command>`. Never wrap a helper that already owns that lock or let detached processes inherit it. Do not load qex policy, submit queued jobs, run Gradle builds or execute E2E stacks. For those checks, save a stable checkpoint and exact selection/prerequisites and return to the parent for an independent verifier assignment. A failing-baseline queued test uses the same verifier path before implementation continues.
- Prepare setup/launch/readiness/observation/reset/teardown scripts within approved ownership, but leave execution of the complete E2E/capability stack to the verifier. Keep resource scope and worker limits aligned with the user's selected declaration. Do not pick new first-time CPU/RAM claims or change shared budgets. Record a missing declaration/choice for the parent to resolve. Root `AGENTS.md` resource declarations and recipe changes are task-owned documentation, not permission to bypass the first-time human gate.
- Separate observation failures from feature assertions. Retain acquisition diagnostics and regression fixtures; a fixture is not fresh native journey evidence. Record actual artifact/build identity, including the bundle/ABI consumed by a device. Pin builds before verification readers; later repairs invalidate affected artifacts and receipts.
- Diagnose and repair autonomously within the approved contract. After two attempts with the same failure signature and no new discriminating evidence, or 20 minutes of active investigation without new evidence, write `diagnosis.md`: source/environment identity, hypothesis/experiment/result, changed evidence, remaining explanations and smallest next discriminating experiment. Exclude command/resource/human waits. Change approach rather than repeating a failed reset/build/protocol unchanged. These are reassessment triggers, not retry or approval limits.
- Checkpoint before fragile/expensive work and at completion: changed paths and interfaces, exact source/artifact identities, criterion → test map, baseline/passing logs, commands and exit statuses, unresolved checks/dependencies, live process/environment ownership and next action. A development pass is provisional; independent acceptance belongs to the verifier and parent.

Stop at a stable checkpoint and return the file-backed report when the assignment is done or it needs independent verification. Do not wait/poll for other model children or act as the reviewer/verifier. If interrupted, preserve partial changes and active command identity so the parent can safely continue without creating another writer.

```js workflow
const execution = await runs.run("execute-t1", {
  label: "Implement · T1", phase: "implementation", agent: "worker",
  model: "magpie/group/gemini-speed:medium",
  task: "Act only as the executor. Read <run dir>/executor-brief.md and this workflow's executor contract. Implement the approved assignment, run permitted development checks and save a stable checkpoint. Do not subdelegate or perform independent acceptance.",
  notifyOnComplete: true,
  output: "<run dir>/execute-t1-result.md", outputMode: "file-only",
});
return { ok: execution.ok, executorRunId: execution.runId, report: execution.outputReference, artifacts: execution.artifactPaths };
```

On the next pass, use a new stable key and `resume: "<latest executor run id>"`, omitting `agent` and `model`; pass the new repair or milestone brief and save a new report. Keep the latest returned run id in `tasks.md`.
