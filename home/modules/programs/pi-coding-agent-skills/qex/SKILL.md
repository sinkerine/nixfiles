---
name: qex
description: Explicit reference for the e2e-feature independent verifier only. Read when assigned its verification-only brief; do not auto-apply to orchestrators, implementation workers or other workflows.
disable-model-invocation: true
---

# Shared resource queue

This reference is installed at `~/.config/qex/AGENT.md`, outside the global Pi skill catalog. Only the independent verifier in `/skill:e2e-feature` loads these instructions. The Gemini Speed executor implements and runs normal development checks directly under existing locks, while the orchestrator coordinates and inspects evidence; all independent acceptance checks belong to the separate Sol verifier. The verifier reports evidence and never owns product or harness fixes.

Use the Nix-installed `agent-job` wrapper and `qex` CLI. All projects for this user on this machine share one coordinator, configuration and budget. Nixfiles owns the profile table and verifier reference; projects do not install their own queue. The wrapper pins the coordinator's XDG configuration and state roots even in project development shells, while `submit` and `run` preserve the caller's XDG roots inside the command's environment. Each physical host has its own coordinator; a job ID belongs to the host that accepted it.

## Admission allowlist and declarative configuration

Within the independent verifier, only Gradle builds and E2E tests require qex admission. Gradle builds include `gradle`/`./gradlew` build, assemble, bundle and compile tasks, including scripts that invoke them. E2E includes its complete setup, execution and teardown stack. Run every other operation directly: Nix builds/checks, non-Gradle builds, unit tests, lint/format, typechecks, coverage, dependency installation and standalone VM work, unless it belongs to an admitted E2E stack. Classify wrapped commands by the work they execute. This is an agent policy; the CLI does not intercept arbitrary shell commands.

Home Manager generates `~/.config/qex.toml` and the profile table as Nix store symlinks. Configure the shared budget with `my.programs.qex.cpuBudget` and `memoryBudget`. Set live RAM admission thresholds with `reserveMemory` and `maxMemoryPressure`. Use `my.programs.qex.settings` for other TOML settings or explicit overrides. Edit the Nixfiles module and activate the appropriate Home Manager profile to apply changes. Do not use `qex config set` or edit installed configuration files.

## Choose an estimate

For E2E, use the repository declaration described below; the global profiles are sizing guidance, not a substitute for that declaration. For Gradle builds, run `agent-job profiles` to see the authoritative installed profile table (`~/.config/qex/profiles.json`). Choose the profile from the work the command and its descendants will do, including cold setup, internal workers and teardown. Do not estimate from currently free RAM: qex performs admission against live available memory, pressure and outstanding claims.

| Profile | CPU claim | RAM claim | Use |
| --- | ---: | ---: | --- |
| `small` | 1 | 2 GiB | Small Gradle build with bounded workers |
| `medium` | 2 | 4 GiB | Modest Gradle build with bounded workers |
| `heavy` | 4 | 8 GiB | Larger Gradle build within this estimate |

These are the only global profiles. They are estimates, not measured limits. Choose a profile that covers the complete Gradle build, including compiler daemons and workers. Inspect the actual package script, recipe and worker settings before choosing a profile; an executable name alone does not establish the workload's size. Bound compiler jobs and Gradle workers separately: a qex CPU claim is not a CPU quota. For a larger/parallel Gradle build, choose `heavy` only when its 4-CPU/8-GiB estimate covers the work; when scope is unclear or no listed profile fits, report the needed resources and have the shared profile reviewed. Do not split a real job into pieces merely to understate its claim. Large jobs can be rejected when the host's budget is smaller than their profile; do not change the host budget or downgrade the profile to bypass rejection.

Operations outside the admission allowlist run directly regardless of their cost. Reuse valid check receipts before submitting another test. A passing result is reusable only when its relevant source, environment and artifacts still match.

## Repository E2E quota

Every E2E execution, including capability/smoke probes, manual journeys, retries and independent acceptance, must run under shared qex admission using a named resource declaration from the repository root's `AGENTS.md`. Read `~/.config/qex/e2e-resources.md` for the exact `qex-e2e <name>` JSON fence format, qex-compatible fields, and estimation guidance. CPU and RAM claims are explicit and cover setup, all descendants and teardown. Keep separate declarations for resource-distinct variants and worker counts. Use `agent-job estimates --cwd <worktree>` to validate and list them, then `agent-job submit --e2e <name> -- <command> ...` or managed synchronous `agent-job run --e2e <name> -- <command> ...`. The CLI reads the matching declaration and passes its claims, optional timeout, pools and locks to qex.

Missing/invalid declarations, unavailable qex, or rejected claims block E2E; do not use a generic profile or run directly as a fallback. A submission is only a request: the resource-consuming command starts when qex grants admission. Keep its reservation through cleanup; a retained diagnostic environment must keep its owning qex job alive. Covered descendants of an already admitted E2E job run directly after verifying its job ID and resource scope; an inherited `AGENT_JOB_ACTIVE=1` alone does not grant quota for a different workload. No E2E execution is required merely to obtain or validate an estimate.

## Submit and retain identity

```bash
agent-job submit heavy --id-file /absolute/run-dir/gradle.id --timeout 30m -- \
  ./gradlew assembleDebug --max-workers=4

agent-job submit --e2e browser --id-file /absolute/run-dir/browser.id --timeout 15m -- \
  npm run test:e2e --workspace=@getpaseo/app -- e2e/browser/<spec>.spec.ts --workers=1
```

Use actual paths and an existing evidence directory. Options go before `--`; everything after it is an executable and literal arguments. Shell operators require an explicit `bash -c '<script>'`. `--cwd /absolute/worktree` sets the execution directory. `--dry-run` shows the resolved qex argv without submitting. The wrapper tags jobs with their global profile or repository E2E declaration and always passes explicit CPU and memory claims, so qex's learned estimates cannot silently replace them.

`submit` returns a job ID immediately. Record the host, ID, profile, source identity, command, evidence paths and owning session in the run's existing state. A job's execution timeout starts when it runs; queue waiting is separate. Do not wrap an async submission in a short tool timeout and treat its return as proof that the check passed.

Use the retained ID:

```bash
qex status <job-id> --json
qex logs <job-id>
qex cancel <queued-job-id>
qex kill <running-job-id>
```

Cancellation applies only to jobs owned by this task. Never clear the shared queue. If a wait ends or a session resumes, inspect the same ID before deciding whether to repeat work. Success requires the terminal job result and the check's actual evidence.

The independent verifier is already an async background child. Prefer synchronous `agent-job run`, or one long bounded `qex status <job-id> --wait --timeout <duration> --json --no-logs` on the submitting host with an explicit bash timeout sized for queue wait plus execution and a reporting margin. Its parent remains responsive and native child completion wakes the parent. This needs only existing command-tool authority; do not add nested subagent privileges or launch model children to wait.

When the current Pi runtime actually exposes the `subagent` tool, registered resource and authority for this exact native host wait, the Nix-managed resource is an optional alternative:

```typescript
subagent({ workflow: "qex-wait", args: { id: "1234abcd", timeoutMs: 3_600_000 } })
```

Use the actual retained ID. This launches one host wait and wakes the session on completion, without a model worker or polling. Return control after launch; ordinary async completion already wakes the session, so do not call `bg_wait` or repeatedly inspect workflow status. `timeoutMs` includes queue wait plus execution (default 1 hour, range 1 minute to 23 hours 59 minutes); the host-command deadline adds 60 seconds for qex to report its result. A failed/cancelled job or expired wait surfaces as a failed host step with evidence. The wait never submits, cancels or kills a job. If the wait expires, the job continues: inspect the same ID once before reattaching. A default worker must not assume nested subagent workflows are available. Native `qex-wait` grants only its exact host wait, never model subdelegation. The verifier must not run short-poll loops.

For a deterministic verification runner that needs streamed output and the command's exit status, use `agent-job run <profile> -- <command> ...` inside the individual recipe check. Its caller must allow queue wait in its outer deadline; do not assume that a quiet queue wait is a hung test. Other harnesses should use their supported background host-command completion mechanism. For a background host command, a bounded wait such as `qex status <job-id> --wait --timeout 20m --json --no-logs` needs an outer deadline of at least 1,260 seconds; size it for queue wait plus execution. In a top-level interactive session, do not run that long wait in a foreground tool that blocks progress updates. An async background verifier child may use one bounded synchronous wait with an explicit tool timeout; its parent remains responsive. Without a background mechanism, inspect once and report the pending ID. Never use repeated 30–60-second status/sleep loops or resubmit just because a job is queued. Pi sessions need Home Manager activation and a resource reload before the new workflow resource is available.

## One reservation per executing workload

Queue either the complete stack or its independently runnable leaf commands, never both a parent runner and the commands it waits for. A child of `agent-job` inherits `AGENT_JOB_ACTIVE=1`; the wrapper rejects recursive submissions to prevent nested reservations. Run those child commands directly, under the parent's reservation. Do not unset this guard to bypass it.

For `e2e-feature`, keep dependency scheduling, artifact fingerprints and receipt validation in the existing verification helper. Put `agent-job run` around Gradle build and E2E leaf commands in the recipe, using a central profile for Gradle or `--e2e <name>` for E2E. Run other checks directly. Keep the helper itself outside qex. Existing build/output/device locks still apply; exactly one layer acquires each lock. Acquire existing external locks before qex admission, as in `flock --close <build-lock> agent-job run <profile> -- <command>`. Never reserve qex capacity and then wait for an external lock that another check can hold while awaiting qex. Work guarded by an external lock must use synchronous `agent-job run` under that lock, or use a qex `--lock` that stays held with the job. Never wrap asynchronous `agent-job submit` in `flock`: submission returns before execution and releases the external lock. Qex's own `--lock` resources are claimed together with its admission and do not need outer acquisition. A queued command must stay alive through cleanup. Do not launch a detached service and exit while it is still using resources.

Keep desktop tests headless or on their own display/VM. Resource admission does not provide display, port, filesystem or application-state isolation.

The shared budget accounts for CPU and RAM only. Use repeated `--lock <name>` options with stable names for exclusive access to shared devices, ports, or outputs.

## Host policy and calibration

Use `qex config show`, `qex info` and `qex list` to inspect effective policy and blockers. Kazuki uses an 8-CPU/24-GiB claim budget, an 8-GiB live available-memory reserve, and a 5% Linux PSI memory-pressure admission threshold. Other hosts start conservatively with 25% CPU/RAM budgets and a 4-GiB reserve; these are provisional defaults requiring host-specific calibration, not measurements of sachi or another host. Oversized claims are rejected. A rejection is an explicit capacity blocker, not a request that waits for other jobs. Preserve the estimate and report requested CPU/RAM versus effective budget. Use an already authorized suitable host after checking its tooling and capacity, or obtain explicit user authorization for a calibrated host-policy change if no suitable destination is available. Do not silently lower the estimate or raise the budget; workloads requiring more than the largest global profile need explicit sizing. Jobs yield CPU and I/O priority to interactive work where the platform supports it.

The configuration is admission control: it neither limits a job to its declared RAM nor reacts by stopping existing jobs when other applications grow. Already running and unqueued workloads still consume capacity. Keep qex learning disabled: on Linux its `RUSAGE_CHILDREN.ru_maxrss` measurement is the largest child's peak, not the combined simultaneous memory of a multiprocess test stack. Review whole-job cgroup `memory.peak` measurements before proposing changes to the central table; distinguish cold/warm builds, worker counts and runtime variants. Measurements from a different command or worktree are not automatically a reusable test receipt.

Nixfiles sources:

- `home/modules/programs/qex/default.nix`: host budgets, shared CLI and Home Manager installation.
- `home/modules/programs/qex/profiles.json`: estimates used by `agent-job`.
- `home/modules/programs/qex/agent-job.py`: deterministic profile-to-qex argument mapping.
- `home/modules/programs/ai-agent-common/qex-instructions.md`: scoped queue reference, no longer appended to common agent instructions.
- `home/modules/programs/pi-coding-agent-skills/qex/SKILL.md`: this detailed workflow.
- `home/modules/programs/pi-coding-agent-skills/e2e-feature/references/qex-resources.md`: the repository E2E declaration format, also installed as `~/.config/qex/e2e-resources.md`.

After Home Manager activation, the explicit verifier reference and native wait resource are available. Reload Pi resources or start a new session to remove an existing session's old global skill/instructions; remote hosts require their normal deployment before using these commands.
