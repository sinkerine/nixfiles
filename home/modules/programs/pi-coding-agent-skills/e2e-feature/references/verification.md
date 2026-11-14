# Native verification and reusable recipes

Read once when preparing the approved check inventory. Use `e2e-feature-run` installed by this repository's Pi module and the `e2e-verify` named workflow registered by its extension. Raw workflow scripts still cannot call `runs.host`.

## Recipe

Prefer a versioned project recipe at `.agents/e2e-verification.json` and maintained setup/launch/readiness/acquisition scripts. Validate them against the current checkout and AGENTS.md. If absent, write `<run dir>/verification.json` and run-local helpers from the approved plan; promote reusable tooling only within the approved task's file ownership. Do not install or modify global dependencies merely to satisfy smoke testing. Record the two-stage capability check from [capability-and-repairs.md](capability-and-repairs.md); the bounded smoke phase below does not replace the representative executable experiment.

A recipe has this shape (replace example commands with the repository's real commands):

```json
{
  "version": 1,
  "max_parallel": 2,
  "resources": {"unit-browser": {"scope": "worktree", "limit": 1}, "lint": {"scope": "worktree", "limit": 1}},
  "environment_inputs": ["flake.lock", "pnpm-lock.yaml", "libraries/rustsdk/matrix-rust-sdk.aar"],
  "env_keys": ["BROWSER_IMAGE", "TZ"],
  "checks": [
    {"id": "smoke", "phase": "smoke", "command": "./tools/check-test-environment", "timeout_seconds": 60},
    {"id": "T3", "phase": "task", "command": "./tools/test-module protocol", "timeout_seconds": 600},
    {"id": "units-coverage", "phase": "full", "needs": ["smoke"], "resources": ["unit-browser"], "command": "./tools/test-all --coverage", "timeout_seconds": 1800, "proves": ["all-required-units", "coverage"], "artifacts": ["coverage/lcov.info"]},
    {"id": "lint-types-build", "phase": "full", "needs": ["smoke"], "resources": ["lint"], "command": "./tools/check-and-build", "timeout_seconds": 1800}
  ]
}
```

Do not copy irrelevant dependency names from the example. List relevant ignored/generated inputs, tool binaries or immutable environment manifests in `environment_inputs`; paths can be worktree-relative or absolute. A lockfile alone does not prove an installed mutable dependency tree matches it: check dependency integrity in smoke, and include its immutable store path or installation identity/manifest. Include browser/container image digests, device configuration, toolchain and runtime versions, test-runner config, discovery and build flags in the recipe's input closure. `env_keys` lists additional relevant environment values; receipts retain their hash, never their values. Commands inherit the actual environment. Keep secrets out of commands.

By default each check fingerprints all tracked and non-ignored untracked source, tests, configuration and lockfiles, excluding goal/subagent runtime metadata. A check may specify `inputs: ["module", "shared/interfaces", "test.config.ts", "lockfile"]` only when that closure includes every relevant dependency and discovered test. Omitted paths, ignored dependencies and unknown environment identity are not proven by the cache. When a complete identity cannot be established, use `refresh: true` for that invocation. Never set `inputs: []`. Prefer a justified dependency closure so unrelated documentation or another platform's files do not invalidate expensive checks; keep the repository-wide default when the closure is uncertain. Narrowing inputs is an evidence decision, never a way to clear a stale receipt.

Recipe commands must not acquire the helper's locks themselves. Each check acquires its declared resources and a per-check receipt lock. Checks without `resources` hold the legacy `<build lock>` exclusively, blocking other unknown commands, workers and declared independent checks. Explicitly independent checks share that legacy guard and hold their named groups. Worker development commands continue using the exclusive legacy lock directly with `flock --close` for commands that may spawn detached children; a narrower flock alone does not claim the helper's full resource contract. Before first execution, inspect each recipe command, wrapper and worker brief for recursive helper calls or outer/inner acquisition of the same lock. Exactly one layer owns each acquisition. Log lock acquisition separately where supported; after a timeout, inspect the real owner/process before retrying instead of assuming the test hung. This is a recipe review requirement, not a claim that the helper detects arbitrary shell-level nesting.

`max_parallel` defaults to 1 and is bounded to 16; start with 2 on this host. Named resources have `scope` (`worktree`, `repository`, or `host`) and `limit` (default 1). Repository groups coordinate worktrees; host groups coordinate repositories. For example, a shared `host-cpu` group with limit 2 bounds expensive work across recipes on this host. All participants must use the same resource definitions. The legacy `build` group remains exclusive. Declare separate groups only after proving independent state/output ownership. Unknown commands keep conservative serialization.

`needs` lists prerequisite check ids. Selection automatically includes their transitive closure, including prerequisites in other phases. Invalid references, duplicate ids and cycles fail before execution. A failed prerequisite blocks its dependents; independent checks still finish, and the overall invocation fails. Generators and prerequisite builds precede their readers. Declare their generated outputs in `artifacts`, and list those outputs in consumers' per-check `environment_inputs` so edits during execution invalidate results. A check that changes its own source/input identity is stale and cannot be accepted. Model artifact production separately: prepare/build → pin identities → verify stable artifacts. If an instrumentation runner rebuilds its test APK, prepare that exact runner variant before fingerprinting, or use the project's supported run-without-build command. Stabilize variant/flags and output identity once; do not normalize the failure by repeatedly accepting stale results or rerunning the same self-mutating check. Preserve the original stale receipt and its cause.

Use one passing coverage command for both unit and coverage requirements only after confirming identical required projects, discovery and assertions. `proves` records that mapping; it does not waive another check. Preserve separate visual/Storybook, integration and E2E requirements.

## Launch without an LLM wrapper

Run ordinary short checks through host tools. For a potentially long check, use the native named workflow:

```js
subagent({workflow: "e2e-verify", async: true, cwd: "<worktree>", options: {missionId: "<mission id>"}, args: {feature: "<feature>", recipe: "<run dir>/verification.json", checks: ["T3"], timeoutMs: 900000}})
```

For the full inventory, use `phase: "full"` instead of `checks`. For an approved automated journey use `phase: "e2e"`; its build prerequisites are included. To run full checks and an automated journey as one graph, omit `phase` and select the required check ids (or all checks); their resources determine safe overlap. `jobs` in native workflow args, or CLI `--jobs`, may lower but never raise the recipe's concurrency limit. For smoke use `phase: "smoke"` with an outer timeout of at most 60000 ms; ensure its prerequisite closure is also bounded to that deadline. Set the outer timeout to cover the selected command deadlines plus lock wait. A completion notice is not success: inspect the returned `ok`, exit status and receipt. Failed commands block dependent checks while independent checks finish. Inspect every result; blocked or cancelled checks remain unsatisfied. The resource binds the invocation to this session's worktree and grants only the exact quoted helper command, without launching a model child or requiring a child attestation.

Implementation/fix host gates can use:

```text
e2e-feature-run verify --feature <feature> --recipe <run dir>/verification.json --check T3
```

The first independent gate executes the command after worker edits. Worker development runs use the real test command rather than creating host receipts through this helper. Acceptance may invoke the helper again: a read-only review and content-preserving commit reuse the receipt; relevant edits or changed ignored artifacts invalidate it. Parent inspection can read the check receipt directly without another model worker.

Receipts live at `<run dir>/verification/<check id>.json`. They include command, source/environment fingerprints before and after, source HEAD for provenance, exit status, timing, artifact hashes, log path and log hash. A result is reusable only if it passed, inputs still match, its log is intact and required output artifacts still match. Failures, timeouts, stale runs and missing artifacts are never reused. `--refresh` forces a fresh run. CLI JSON and `verification/latest-run.json` include ready/start/settled timestamps, ready-to-start delay, capacity wait, and resource lock wait separately from per-command execution time. Wait categories are observed at the scheduler's 50 ms polling resolution; summed waits across parallel checks are not elapsed-time savings. Content identities round-trip through JSON for files and directories, so directory build artifacts can be reused too.

The helper runs compatible ready checks within the recipe and resource limits, with prerequisite gates and cross-process locks. Cancellation stops pending checks and terminates active command process groups. The resource's host row remains running during execution, so there is no idle model child to trigger inactivity alerts. Runtime checks attached to real implementation workers also publish host-verification activity.

## Pinned builds and project recipes

Read [projects.md](projects.md) for the concrete Element Web and Android recipe generators. Prepare generators and builds before parallel readers, then use `e2e-feature-run snapshot --feature <feature> --recipe <recipe> --artifact <build path>` to copy a build into this run's snapshot directory. It returns a manifest and copied paths. `snapshot-check --feature <feature> --snapshot <manifest>` verifies the source/environment identity and copied artifact hashes before and after a journey. Later builds may replace the original output; the copied artifact stays fixed. Source repairs invalidate it. Use a fresh snapshot after repairs; do not overwrite old evidence. Record the actual installed/served artifact identity as well as the file intended for delivery, including native ABI/build variant and JavaScript bundle where relevant. A correct source hash alone cannot establish which build the device consumed.

The Web preset can serve the pinned static build on its own ephemeral loopback port and run an approved Playwright spec. A separate journey browser endpoint is required to overlap it with browser coverage; shared endpoints remain serialized. Android's repository instructions prohibit overlapping Gradle work with emulator testing, so its preset intentionally keeps those phases ordered.

## Cross-project handoff

Before an expensive consumer build, require the producer's exact commit, retained APIs plus new APIs, toolchain/build variant, and durable report/artifact hashes. Check those interfaces against the consumer's existing imports before building. Copy a producer report into the consumer's own run directory immediately:

```text
e2e-feature-run handoff --feature <feature> --producer-repo <producer repository> --sha <exact full producer SHA> --report <producer report path>
```

Run this in the consumer worktree. It verifies the exact commit in `--producer-repo` (default: current repository), then copies the report and its SHA256 into the consumer run directory. Never assume a report in a producer worktree survives archive. Keep the original source path only as provenance; briefs use the durable copied path.
