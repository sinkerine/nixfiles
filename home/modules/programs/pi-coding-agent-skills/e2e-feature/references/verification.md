# Native verification and reusable recipes

Read once when preparing the approved check inventory. Use `e2e-feature-run` installed by this repository's Pi module and the `e2e-verify` named workflow registered by its extension. Raw workflow scripts still cannot call `runs.host`.

## Recipe

Prefer a versioned project recipe at `.agents/e2e-verification.json`. Validate it against the current checkout and AGENTS.md. If one does not exist, write `<run dir>/verification.json` from the approved plan; commit a reusable project recipe only within the approved task's file ownership. Do not install or modify global dependencies merely to satisfy smoke testing.

A recipe has this shape (replace example commands with the repository's real commands):

```json
{
  "version": 1,
  "environment_inputs": ["flake.lock", "pnpm-lock.yaml", "libraries/rustsdk/matrix-rust-sdk.aar"],
  "env_keys": ["BROWSER_IMAGE", "TZ"],
  "checks": [
    {"id": "smoke", "phase": "smoke", "command": "./tools/check-test-environment", "timeout_seconds": 60},
    {"id": "T3", "phase": "task", "command": "./tools/test-module protocol", "timeout_seconds": 600},
    {"id": "units-coverage", "phase": "full", "command": "./tools/test-all --coverage", "timeout_seconds": 1800, "proves": ["all-required-units", "coverage"], "artifacts": ["coverage/lcov.info"]},
    {"id": "lint-types-build", "phase": "full", "command": "./tools/check-and-build", "timeout_seconds": 1800}
  ]
}
```

Do not copy irrelevant dependency names from the example. List relevant ignored/generated inputs, tool binaries or immutable environment manifests in `environment_inputs`; paths can be worktree-relative or absolute. A lockfile alone does not prove an installed mutable dependency tree matches it: check dependency integrity in smoke, and include its immutable store path or installation identity/manifest. Include browser/container image digests, device configuration, toolchain and runtime versions, test-runner config, discovery and build flags in the recipe's input closure. `env_keys` lists additional relevant environment values; receipts retain their hash, never their values. Commands inherit the actual environment. Keep secrets out of commands.

By default each check fingerprints all tracked and non-ignored untracked source, tests, configuration and lockfiles, excluding goal/subagent runtime metadata. A check may specify `inputs: ["module", "shared/interfaces", "test.config.ts", "lockfile"]` only when that closure includes every relevant dependency and discovered test. Omitted paths, ignored dependencies and unknown environment identity are not proven by the cache. When a complete identity cannot be established, use `refresh: true` for that invocation. Never set `inputs: []`.

Commands must not acquire `<build lock>` themselves: the helper acquires it once for the selected checks. Worker development tests still use the assigned lock directly. Keep the current conservative default lock for helper checks; use separate invocations only when recipes and the latency reference prove resources are independent. A check that changes its own source/input identity is reported stale and cannot be accepted. Run prerequisite generators first, then verify stable inputs.

Use one passing coverage command for both unit and coverage requirements only after confirming identical required projects, discovery and assertions. `proves` records that mapping; it does not waive another check. Preserve separate visual/Storybook, integration and E2E requirements.

## Launch without an LLM wrapper

Run ordinary short checks through host tools. For a potentially long check, use the native named workflow:

```js
subagent({workflow: "e2e-verify", async: true, cwd: "<worktree>", options: {missionId: "<mission id>"}, args: {feature: "<feature>", recipe: "<run dir>/verification.json", checks: ["T3"], timeoutMs: 900000}})
```

For the full inventory, use `phase: "full"` instead of `checks`. For smoke use `phase: "smoke"` with an outer timeout of at most 60000 ms. Set the outer timeout to cover the selected command deadlines plus lock wait. A completion notice is not success: inspect the returned `ok`, exit status and receipt. Failed commands stop that selection; remaining required checks stay pending. The resource binds the invocation to this session's worktree and grants only the exact quoted helper command, without launching a model child or requiring a child attestation.

Implementation/fix host gates can use:

```text
e2e-feature-run verify --feature <feature> --recipe <run dir>/verification.json --check T3
```

The first independent gate executes the command after worker edits. Worker development runs use the real test command rather than creating host receipts through this helper. Acceptance may invoke the helper again: a read-only review and content-preserving commit reuse the receipt; relevant edits or changed ignored artifacts invalidate it. Parent inspection can read the check receipt directly without another model worker.

Receipts live at `<run dir>/verification/<check id>.json`. They include command, source/environment fingerprints before and after, source HEAD for provenance, exit status, timing, artifact hashes, log path and log hash. A result is reusable only if it passed, inputs still match, its log is intact and required output artifacts still match. Failures, timeouts, stale runs and missing artifacts are never reused. `--refresh` forces a fresh run. CLI JSON includes lock wait separately from per-command execution time; use those values for latency comparisons.

The helper serializes its own checks. The resource's host row remains running during execution, so there is no idle model child to trigger inactivity alerts. Runtime checks attached to real implementation workers also publish host-verification activity.

## Cross-project handoff

Before an expensive consumer build, require the producer's exact commit, retained APIs plus new APIs, toolchain/build variant, and durable report/artifact hashes. Check those interfaces against the consumer's existing imports before building. Copy a producer report into the consumer's own run directory immediately:

```text
e2e-feature-run handoff --feature <feature> --producer-repo <producer repository> --sha <exact full producer SHA> --report <producer report path>
```

Run this in the consumer worktree. It verifies the exact commit in `--producer-repo` (default: current repository), then copies the report and its SHA256 into the consumer run directory. Never assume a report in a producer worktree survives archive. Keep the original source path only as provenance; briefs use the durable copied path.
