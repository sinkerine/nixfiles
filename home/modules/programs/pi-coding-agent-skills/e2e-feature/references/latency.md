# Latency and verification reference

Read this when preparing `<run dir>/verification.md`. Keep the run's concrete commands and receipts there, rather than repeatedly exploring the environment in workers or rereading this reference.

## Environment recipe

Use a versioned recipe already in the project when available. Record its path and revision. Otherwise derive a run-local recipe from the repository's scripts, configuration, and AGENTS.md; do not silently change project-wide verification policy.

Record:

- Exact unit, integration, visual/Storybook, lint, type, build, coverage, and E2E requirements, with a mapping from each requirement to its command and evidence. Discover the current runner's configured projects and tests. A missing runner command is a recipe defect to resolve, not permission to drop its check.
- Toolchain and dependency identity (Nix closure/dev shell, lockfiles, runtime versions), current worktree, required generated packages, and how to generate them.
- Browser/container image and version, baseline directory and platform selection, device/emulator availability, isolated state, free ports, and teardown procedure. Smoke one existing test in the actual intended environment. Confirm coverage emits nonempty records for expected source files.
- Resource groups, each command's lock, output directories, browser endpoints/devices, and a modest host concurrency limit. Commands can run together only when they neither mutate nor consume another running command's unstable outputs. Keep generators before their readers. Keep the default lock when independence is unknown; build tools with shared caches may already have their own locks.
- Commands that rewrite source/generated files or the index. Run generators before pinning evidence; after commit hooks run, compare relevant inputs again. A check that rewrites inputs must finish before readers start.

Preserve the required inventory on failure. Fix environment problems, distinguish assertion failures from connection failures, and use supported sharding with complete discovery and correctly merged coverage where appropriate. Do not exclude projects, regenerate visual baselines just to clear failures, or reduce thresholds. Changed scope requires a real authorized change to the verification contract.

A coverage invocation may satisfy units as well when it executes the same required projects, tests, and assertions. Record that equivalence once. A separate visual suite still runs when it is outside that discovery. Reuse a healthy isolated environment across repairs when the repository instructions allow it, resetting test state between attempts.

## Independent gate receipt

Persist a receipt for each host check with command, cwd, exit status, start/end time, source/input identity before and after, discovered test scope, environment identity, and full log/report paths. The receipt can be a small file or an existing runtime verification artifact plus an input manifest. Do not claim the runtime's cache key proves inputs it did not hash.

Include all relevant tracked and untracked source, tests, configuration, dependency lockfiles, toolchain/environment choices, and generated or ignored inputs. Examples include a local SDK AAR's digest and provenance, generated FFI bindings, browser image, build flags, and runtime environment. Git HEAD alone does not identify an uncommitted tree or ignored artifact. Hash only relevant environment values; do not copy secrets into a receipt.

For source snapshots, `<run dir>/snap.sh <paths>` captures tracked and non-ignored untracked inputs without touching the real index. Record generated/ignored input digests separately. Use a repository-wide source scope when a smaller dependency closure cannot be justified. If relevant inputs changed while a command was running, its result cannot prove the resulting checkout; rerun on stable inputs.

A passing receipt can satisfy task acceptance or final verification after a read-only review when all relevant inputs, environment, command, and discovered scope still match. A commit without changed content need not invalidate it, but hooks, generators, dependency changes, repairs, merges, host moves, and environment changes require checking identities again. Reuse only the checks whose full identity is still proven; uncertainty means rerun. Keep final full-feature requirements and a full inventory of evidence. Worker prose never substitutes for independent execution.

## Implementation dependencies and consolidated review

Within one launch, use plain functions returning promise chains. Nested `async` functions are rejected by the installed Node/Bun-portable workflow sandbox. Launch compatible ready implementations together; each completes its independent host gate and notifies the parent without launching a reviewer. Fill `items` with the task ids and exact commands from the approved plan. The helper claims each task's complete resource set; do not wrap it in another flock.

```js workflow
const items = [
  { id: "T2", key: "t2", gate: "e2e-feature-run verify --feature <feature> --recipe <run dir>/verification.json --check T2" },
  { id: "T3", key: "t3", gate: "e2e-feature-run verify --feature <feature> --recipe <run dir>/verification.json --check T3" },
];
function runTask(item) {
  return runs.run(item.key + "-implement", {
    label: item.id + " · implement", phase: item.id,
    agent: "worker", model: "magpie/gpt-6.1-sol:medium",
    task: "Implement " + item.id + ". Read <run dir>/" + item.key + "-brief.md.",
    gate: item.gate, notifyOnComplete: true,
    output: "<run dir>/" + item.key + "-implement-result.md", outputMode: "file-only",
  }).then(function (impl) {
    return { task: item.id, ok: impl.ok, stage: "implement", writerRunId: impl.runId, report: impl.outputReference, artifacts: impl.artifactPaths };
  }).catch(function (error) {
    // Preserve siblings while the parent handles the native failed-child notification.
    return { task: item.id, ok: false, stage: "failed", error: String(error) };
  });
}
return Promise.all(items.map(runTask));
```

`notifyOnComplete` is provided by this repository's pi-subagents patch. Apply the matching Nix package before using this skill revision. Each gated implementation wakes the parent while siblings continue. `emit()` alone persists progress without a wake. The parent reads the worker report, validates the independent gate and produced interface, and marks the task implemented before releasing compatible dependencies. Do not relaunch the running script or duplicate a workflow key to refresh a result.

Release newly ready tasks only when ownership and source/build-input conflicts allow them. Do not mutate files still read by another task or its test. Implemented tasks may remain uncommitted until consolidated review acceptance; update `tasks.md` with interfaces and receipts so dependents can consume them. A later relevant edit invalidates earlier evidence. Preserve explicitly approved early review gates and barriers.

After all implementation and gates finish, use the skill's consolidated Review phase against stable feature inputs. Delaying the same per-task reviewer fanout saves little context and loses overlap; consolidate shared context and review integration explicitly. Default to one reviewer, splitting only large features into a few nonoverlapping scopes with assigned integration coverage. Group confirmed fixes by ownership, resume the original workers, and review affected deltas after repairs settle. Do not rerun a full review for each repair. Acceptance still requires no confirmed Critical/Important findings and matching independent gates; commit only at a safe idle point and recheck any hook changes.

## Final verification and E2E

Once task edits and commit hooks settle, finish generators and prerequisite builds, then pin/copy the tested feature artifact. Full verification and the isolated E2E journey can overlap when their source inputs remain stable, output/state and resources are separate, and concurrency stays within the recipe's limit. Run deterministic checks through the installed `e2e-verify` named resource or ordinary host tools with saved logs, following [verification.md](verification.md). The named resource launches no model child. Raw scripts have no `runs.host` authority, and an LLM preflight worker adds no independent evidence.

Record both branches' input identities. Delivery waits for both. If either branch discovers a defect, preserve the failure, wait for overlapping readers before repair (or use an isolated repair checkout), and invalidate affected checks and E2E evidence. Rerun affected checks on the repaired artifact. Keep the journey environment available after a failure when instructions allow it.

## External dependency handoff

A producer must provide the exact source revision, artifact identity/digest, old APIs still required by the consumer as well as the new APIs, build/toolchain variants, and a copied verification report in a durable location the consumer can read after producer-worktree cleanup. Validate the source/interface contract before an expensive AAR or native build. Verify the resulting artifact before installing it, atomically where practical.

Continue approved local tasks that do not need that dependency. Do not use timed retries against a missing artifact. Use the installed source-specific Paseo message wait described in [waiting.md](waiting.md): declare the producer, exact handoff prefix and finite deadline, then yield without polling. The patched scheduler consumes the matching native message directly. Generic token waits still require their producer adapter; an arbitrary message does not satisfy a token. Preserve user-owned pauses and report a missing runtime integration rather than repeatedly waking to say it is still waiting.

## Measure the next run

Use existing trace/receipt timestamps for task ready, launch, model/command start, lock acquisition, finish, and acceptance. A normal command duration includes lock wait unless acquisition is logged separately; never label it pure test execution. Mark missing timestamps unknown. Track human approval and external dependencies separately from active execution.

Compare task-ready-to-launch and gate-to-dependent-launch delays, all-implementation-finished-to-review-start delay, consolidated review/repair duration, lock wait, environment repairs, and repeated checks with unchanged identities. Track reviewer launches, repeated context, and input/output/cache token usage alongside total elapsed time; delayed discovery can add downstream rework. Distinguish explicitly planned early reviews from consolidated scopes. For overlapping intervals, compute their union rather than summing durations. Final verification plus E2E has serial cost `V + E` and a theoretical overlap cost `max(V, E)` only when resources and inputs are independent; contention can erase the benefit. Do not report aggregate model minutes or no-child time as end-to-end latency savings.
