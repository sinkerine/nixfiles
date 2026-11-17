# Repository E2E resource declaration

Within `/skill:e2e-feature`, only the independent verifier child executes E2E stacks and loads the detailed qex reference at `~/.config/qex/AGENT.md`; see [verifier.md](verifier.md). The main implementation session runs normal development checks directly under existing locks, and routes E2E capability probes, journeys and reruns to that verifier. Declaration inspection/validation does not acquire quota and can happen before launching the child.

Every actual E2E execution needs a resource declaration in the repository root's `AGENTS.md` and admission from the shared host qex scheduler before starting the resource-consuming stack. This includes representative capability experiments, smoke tests, manual journeys, independent acceptance, and repairs/reruns. It does not add E2E requirements to future pushes/deployments or remove a repository's explicit E2E exemption.

## Format in AGENTS.md

Use a named fenced JSON block for each distinct E2E environment/worker variant. The fence must start at column one, with `qex-e2e` followed by a unique name. Its body uses qex's native JSON job-file fields; the test command is supplied at submission time.

````markdown
## E2E testing

The agent runs E2E when a feature is first added. Future pushes and deployments
of the existing feature do not require rerunning E2E. Existing unit tests still run.

Browser E2E uses one Playwright worker and isolated daemon state/ports. The estimate
covers cold Metro setup, Chromium, test daemons and test-launched agents through
cleanup. Run the targeted spec described by the feature's verification recipe.

```qex-e2e browser
{
  "resources": {
    "cpu": 4,
    "mem": "16GiB"
  },
  "timeout": "15m"
}
```
````

The required fields are `resources.cpu` (positive integer CPU claim) and `resources.mem` (positive absolute byte size with units, such as `16GiB`). No percentages, `guess`, `half`, or host-budget-dependent estimates. Optional fields are `timeout` (seconds or a duration with `s`, `m`, `h`, `d`), `locks` (distinct safe names), and `resources.claims` (pool names mapped to positive integer counts). For example, `"claims": {"heavy-io": 1}` claims the host's existing heavy-I/O token. Additional pools must already be configured on the host. Other qex job-file fields are not accepted by this resource-declaration interface. Do not add shell commands, explanatory comments or worker-count metadata inside the JSON; document entrypoints, worker limits, covered processes and measurement evidence in the adjacent prose and executable recipe.

Separate browser, real-Electron, native/emulator, VM, cold-build, or parallel-worker variants when their resource needs differ. Do not copy the browser estimate to native builds. A repository with a symlinked `AGENTS.md` can keep the declaration in its target; a prose link to another file is insufficient for machine parsing. Use the repository root's file even when the command runs in a package subdirectory. Duplicate names/JSON keys, malformed fences, missing estimates or invalid values block submission.

## Preparing the estimate

Inspect the real test entrypoint, setup/build scripts, worker settings and all descendants. Count the whole resource-consuming stack and any emulator that this job starts; use a conservative cold-start estimate if warm-cache identity is not guaranteed. Start from `agent-job profiles` as guidance, but put explicit repository values in `AGENTS.md`. The shared browser example is 4 CPU/16 GiB and the native example is 8 CPU/24 GiB. These are illustrative estimates, not measured peaks, mandatory defaults, or permission to choose the repository's initial cost without human input. Do not lower them merely because the current host cannot fit the job. Review whole-job cgroup peak evidence, when available, before reducing an estimate; qex's largest-child RSS learner is not enough for a multiprocess test stack.

## First-time setup requires human input

Before establishing the first declaration for a repository entrypoint or introducing a distinct workload variant, the orchestrator must use `ask_user` to ask how its qex resource cost should be configured. Prepare the proposal first: inspect the actual commands, processes, cold/warm assumptions and worker limits; present recommended CPU and RAM claims, the covered setup → test → teardown scope, any timeout/locks, available measurement evidence and uncertainty. Explain whether the proposal fits the destination's shared budget and available-memory reserve, including the concurrency/queueing implications. Offer the concrete recommendation and let the user specify another configuration or defer setup. Do not ask the user to invent an estimate without context, silently apply the illustrative numbers, or treat silence/timeouts as a choice.

Wait for an explicit user choice before finalizing the declaration or executing this workload. The gate also applies to the first smoke, capability or measurement run: propose its bounded resource cost and obtain input before running it. Independent design or ordinary development work may continue while the choice is pending. One explicit response can cover multiple clearly listed variants, or the final design approval can cover this gate when the resource proposal is explicitly presented as part of that approval. Reuse a correlated asynchronous response; never open a duplicate question or ask again merely because the verifier starts later.

Write the selected declaration in the task worktree's root `AGENTS.md`, with adjacent prose recording its scope, worker limits and the user's choice/reference; keep the decision in the plan/run record as well. Keep approval metadata outside the machine-parsed JSON. Include the documentation in task ownership/delivery and validate it with `agent-job estimates` before handing the workload to the verifier. The verifier receives the declaration and decision reference, not authority to pick new first-time costs.

Existing applicable declarations remain reusable; this rule does not require retroactive approval or a new question on each feature, retry, resume, or host move. Preserve recorded choices across those transitions. Formatting repairs that preserve values/scope need no new input. If worker counts, setup, platform or stack composition no longer fit the established scope, prepare the revised/new variant and obtain human input for that setup before execution; update the declaration and recipe together. Keep a standalone Gradle build/check separate from the full E2E-stack declaration when their workloads differ, following the verifier's Gradle-profile rules. Missing journey/behavior decisions still use the main skill's existing human-input gate.

## Validate and execute

```bash
agent-job estimates --cwd /absolute/worktree

agent-job submit --e2e browser --cwd /absolute/worktree \
  --id-file /absolute/run-dir/e2e.id -- \
  npm run test:e2e --workspace=@getpaseo/app -- e2e/browser/<spec>.spec.ts --workers=1

# For an expensive leaf command in a deterministic verification recipe:
agent-job run --e2e browser -- <real-test-command> <args>
```

`agent-job estimates` reads and validates the root `AGENTS.md` without requesting quota. `submit` returns a handle, not a grant to run another command outside qex. The submitted command starts only after qex admits its explicit claims. `run` waits for admission and completion. Keep the job alive through test-stack teardown; if a failed environment is retained for diagnosis, its owning qex job must retain the reservation, or stop the environment and obtain fresh admission before recreating it. Do not leave an unaccounted test daemon behind after the queued command exits.

Do not queue both a parent and its children. Existing external build/device locks are acquired before qex admission, and the command must not reacquire them. Hold an external lock around synchronous `agent-job run`, never asynchronous `submit`; alternatively use qex `--lock` so it stays held with the running job. The verifier already inside an admitted E2E job runs covered descendants directly; verify the owning job and declared scope instead of treating an inherited environment marker as permission for a different E2E workload.

Keep prerequisites, artifact fingerprints, receipt checks and independent verification in the existing runner. Use the declaration at the expensive E2E leaf. Include `AGENTS.md`, the selected estimate, exact command/worker settings, installed launcher/qex identities, and any supported external environment manifest in the recipe's input identity. A resource declaration change invalidates receipts that depend on it. Preserve the accepting host, qex job ID, claims, test exit status, and evidence paths in the run's verification record. Existing external emulators/VMs require explicit ownership/accounting; do not count an idle resource as newly reserved merely because its process exists.

If the host lacks `agent-job`/qex, the estimate is invalid, or admission is rejected, record that blocker and resolve deployment, declaration, or destination capacity before E2E. A file lock alone is not task quota. Compare the selected estimate with the destination's effective budget and live headroom; if it cannot fit, report the capacity blocker and use an already authorized capable destination, or seek explicit user authorization for a measured host-policy change when no suitable destination exists. Do not change the budget or substitute a smaller global profile merely to bypass rejection.
