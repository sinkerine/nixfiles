---
name: qex
description: Submit resource-intensive builds and tests to the shared host queue using global profiles or mandatory repository-owned E2E CPU/RAM declarations. Use before unit tests, typechecks, coverage, browser/Electron E2E, native builds, or VM workloads in any project.
---

# Shared resource queue

Use the Nix-installed `agent-job` wrapper and `qex` CLI. All projects for this user on this machine share one coordinator, configuration and budget. Nixfiles owns the profile table and global instructions; projects do not install their own queue. The wrapper pins the coordinator's XDG configuration and state roots even in project development shells, while `submit` and `run` preserve the caller's XDG roots inside the command's environment. Each physical host has its own coordinator; a job ID belongs to the host that accepted it.

## Choose an estimate

For E2E, use the repository declaration described below; the global profiles are sizing guidance, not a substitute for that declaration. For other builds and tests, run `agent-job profiles` to see the authoritative installed profile table (`~/.config/qex/profiles.json`). Choose the profile from the work the command and its descendants will do, including cold setup, internal workers and teardown. Do not estimate from currently free RAM: qex performs admission against live available memory, pressure and outstanding claims.

| Profile | CPU claim | RAM claim | Use |
| --- | ---: | ---: | --- |
| `small` | 1 | 2 GiB | One focused unit-test file; modest lint or format checks with bounded workers |
| `medium` | 2 | 4 GiB | Typecheck; bounded unit selection; modest build |
| `browser-e2e` | 4 | 16 GiB | Entire headless Playwright/Electron test stack: bundler, browsers, isolated daemon, test agents; one test worker |
| `heavy` | 4 | 16 GiB | Large builds, coverage, unfamiliar expensive commands; fallback if uncertain |
| `native` | 8 | 24 GiB | Native/Gradle compilation, build plus emulator, larger VM journey |

These are initial estimates, not measured limits. Before choosing `small` or `medium`, inspect the actual package script, recipe and worker settings; an executable name alone does not establish the workload's size. If that scope is unclear for a non-E2E command, use `heavy`. A broadly parallel suite must not use `small` just because the executable is Vitest or pytest. Bound test workers, compiler jobs and Gradle workers separately: a qex CPU claim is not a CPU quota. For coverage or a larger/parallel workload, choose `heavy` or `native`; when no listed profile fits, report the needed resources and have the shared profile reviewed. Do not split a real job into pieces merely to understate its claim. Large jobs can be rejected when the host's budget is smaller than their profile; do not change the host budget or downgrade the profile to bypass rejection.

File reads, searches, Git inspection and trivial scripts can run directly. Reuse valid check receipts before submitting another test. A passing result is reusable only when its relevant source, environment and artifacts still match.

## Repository E2E quota

Every E2E execution, including capability/smoke probes, manual journeys, retries and independent acceptance, must run under shared qex admission using a named resource declaration from the repository root's `AGENTS.md`. Read `~/.config/qex/e2e-resources.md` for the exact `qex-e2e <name>` JSON fence format, qex-compatible fields, and estimation guidance. CPU and RAM claims are explicit and cover setup, all descendants and teardown. Keep separate declarations for resource-distinct variants and worker counts. Use `agent-job estimates --cwd <worktree>` to validate and list them, then `agent-job submit --e2e <name> -- <command> ...` or managed synchronous `agent-job run --e2e <name> -- <command> ...`. The CLI reads the matching declaration and passes its claims, optional timeout, pools and locks to qex.

Missing/invalid declarations, unavailable qex, or rejected claims block E2E; do not use a generic profile or run directly as a fallback. A submission is only a request: the resource-consuming command starts when qex grants admission. Keep its reservation through cleanup; a retained diagnostic environment must keep its owning qex job alive. Covered descendants of an already admitted E2E job run directly after verifying its job ID and resource scope; an inherited `AGENT_JOB_ACTIVE=1` alone does not grant quota for a different workload. No E2E execution is required merely to obtain or validate an estimate.

## Submit and retain identity

```bash
agent-job submit small --id-file /absolute/run-dir/unit.id --timeout 10m -- \
  npx vitest run path/to/changed.test.ts --bail=1 --maxWorkers=1

agent-job submit medium --timeout 10m -- npm run typecheck

agent-job submit --e2e browser --id-file /absolute/run-dir/browser.id --timeout 15m -- \
  npm run test:e2e --workspace=@getpaseo/app -- e2e/browser/<spec>.spec.ts --workers=1
```

Use actual paths and an existing evidence directory. Options go before `--`; everything after it is an executable and literal arguments. Shell operators require an explicit `bash -c '<script>'`. `--cwd /absolute/worktree` sets the execution directory. `--dry-run` shows the resolved qex argv without submitting. The wrapper tags jobs with their global profile or repository E2E declaration and always passes explicit CPU and memory claims, so qex's learned estimates cannot silently replace them.

`submit` returns a job ID immediately. Record the host, ID, profile, source identity, command, evidence paths and owning session in the run's existing state. A job's execution timeout starts when it runs; queue waiting is separate. Do not wrap an async submission in a short tool timeout and treat its return as proof that the check passed.

Use the retained ID:

```bash
qex status <job-id> --json
qex logs <job-id>
qex status <job-id> --wait --timeout 30s
qex cancel <queued-job-id>
qex kill <running-job-id>
```

Cancellation applies only to jobs owned by this task. Never clear the shared queue. If a wait ends or a session resumes, inspect the same ID before deciding whether to repeat work. Success requires the terminal job result and the check's actual evidence.

For a deterministic verification runner that needs streamed output and the command's exit status, use `agent-job run <profile> -- <command> ...` inside the individual recipe check. Its caller must allow queue wait in its outer deadline; do not assume that a quiet queue wait is a hung test. Use the harness's supported background host-command completion mechanism for long waits, then inspect the receipt. `qex` alone does not automatically wake a Pi/Paseo session; no notification hook is installed by this module. Without a background mechanism, use a bounded wait and report the pending job ID rather than writing a polling loop or resubmitting.

## One reservation per executing workload

Queue either the complete stack or its independently runnable leaf commands, never both a parent runner and the commands it waits for. A child of `agent-job` inherits `AGENT_JOB_ACTIVE=1`; the wrapper rejects recursive submissions to prevent nested reservations. Run those child commands directly, under the parent's reservation. Do not unset this guard to bypass it.

For `e2e-feature`, keep dependency scheduling, artifact fingerprints and receipt validation in the existing verification helper. Put `agent-job run` around an expensive leaf command in the recipe, with `--e2e <name>` for E2E or a central profile for other checks, rather than around the helper itself. Existing build/output/device locks still apply; exactly one layer acquires each lock. Acquire existing external locks before qex admission, as in `flock --close <build-lock> agent-job run <profile> -- <command>`. Never reserve qex capacity and then wait for an external lock that another check can hold while awaiting qex. Work guarded by an external lock must use synchronous `agent-job run` under that lock, or use a qex `--lock` that stays held with the job. Never wrap asynchronous `agent-job submit` in `flock`: submission returns before execution and releases the external lock. Qex's own `--lock` resources are claimed together with its admission and do not need outer acquisition. A queued command must stay alive through cleanup. Do not launch a detached service and exit while it is still using resources.

Keep desktop tests headless or on their own display/VM. Resource admission does not provide display, port, filesystem or application-state isolation.

`--heavy-io` claims the host's one `heavy-io` token for disk-intensive builds or coverage. Additional qex locks can be passed with repeated `--lock <name>`; use stable shared names for genuinely shared resources. Do not acquire a lock in both an outer wrapper and an inner command.

## Host policy and calibration

Use `qex config show`, `qex info` and `qex list` to inspect effective policy and blockers. Kazuki starts with an 8-CPU/16-GiB claim budget, an 8-GiB live available-memory reserve, and a 5% Linux PSI memory-pressure admission threshold. Other hosts start conservatively with 25% CPU/RAM budgets and a 4-GiB reserve; these are provisional defaults requiring host-specific calibration, not measurements of sachi or another host. Oversized claims are rejected. The initial 24-GiB `native` profile is unavailable under kazuki's 16-GiB budget; other hosts also require sufficient measured capacity and configured budget before using it. A rejection is an explicit capacity blocker, not a request that waits for other jobs. Preserve the estimate and report requested CPU/RAM versus effective budget. Use an already authorized suitable host after checking its tooling and capacity, or obtain explicit user authorization for a calibrated host-policy change if no suitable destination is available. Do not silently lower the estimate or raise the budget; no native workload is promised to fit the initial defaults. Jobs yield CPU and I/O priority to interactive work where the platform supports it.

The configuration is admission control: it neither limits a job to its declared RAM nor reacts by stopping existing jobs when other applications grow. Already running and unqueued workloads still consume capacity. Keep qex learning disabled: on Linux its `RUSAGE_CHILDREN.ru_maxrss` measurement is the largest child's peak, not the combined simultaneous memory of a multiprocess test stack. Review whole-job cgroup `memory.peak` measurements before proposing changes to the central table; distinguish cold/warm builds, worker counts and runtime variants. Measurements from a different command or worktree are not automatically a reusable test receipt.

Nixfiles sources:

- `home/modules/programs/qex/default.nix`: host budgets, shared CLI and Home Manager installation.
- `home/modules/programs/qex/profiles.json`: estimates used by `agent-job`.
- `home/modules/programs/qex/agent-job.py`: deterministic profile-to-qex argument mapping.
- `home/modules/programs/ai-agent-common/qex-instructions.md`: global instructions shared by Pi, Codex and Claude.
- `home/modules/programs/pi-coding-agent-skills/qex/SKILL.md`: this detailed workflow.
- `home/modules/programs/pi-coding-agent-skills/e2e-feature/references/qex-resources.md`: the repository E2E declaration format, also installed as `~/.config/qex/e2e-resources.md`.

After Home Manager activation, new sessions receive the instructions. Reload Pi resources or start a new session to update an existing session; remote hosts require their normal deployment before using these commands.
