# Latency and verification reference

Read this when preparing `<run dir>/verification.md`. Keep the run's concrete commands and receipts there, rather than repeatedly exploring the environment in the orchestrator, executor and verifier or rereading this reference.

## Environment recipe

Use a versioned recipe already in the project when available. Record its path and revision. Otherwise derive a run-local recipe from the repository's scripts, configuration, and AGENTS.md; do not silently change project-wide verification policy. Use maintained project environment/measurement tooling, promoting proven run-local helpers only within authorized ownership. Apply [the skill’s capability phase](../SKILL.md#capability-and-implementation): a cheap host check during design followed by the representative executable capability experiment before substantial implementation. Record unknowns rather than equating tool availability with testability.

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

A passing receipt can satisfy task acceptance or final verification after a read-only review when all relevant inputs, environment, command, and discovered scope still match. A commit without changed content need not invalidate it, but hooks, generators, dependency changes, repairs, merges, host moves, and environment changes require checking identities again. Reuse only the checks whose full identity is still proven; uncertainty means rerun. Keep final full-feature requirements and a full inventory of evidence. Implementation claims never substitute for independent execution.

## Stable checkpoints and handoffs

Keep the criterion/test map, produced interfaces and receipt identities in `tasks.md` and `verification.md`. Before compaction, checkpoint unresolved findings, review counters, failed experiments, the next hypothesis, protected boundaries, exact input identities and active child/job handles. Read those records on recovery to avoid reconstructing the run from whole transcripts.

## Final verification and E2E

Once task edits and commit hooks settle, finish generators and prerequisite builds, then pin/copy the tested feature artifact. Full verification and the isolated E2E journey can overlap when their source inputs remain stable, output/state and resources are separate, and concurrency stays within the recipe's limit. The verifier runs deterministic non-qex selections through the installed `e2e-verify` named resource or ordinary host tools with saved logs, following [verification.md](verification.md). For Gradle builds and E2E, including transitive prerequisites, the verifier queues the allowlisted leaves and records evidence under [its admission rules](verifier.md). The named resource launches no model child. Raw scripts have no `runs.host` authority, and an LLM preflight worker adds no independent evidence.

Record both branches' input identities. Delivery waits for both. If either branch discovers a defect, preserve the failure, wait for overlapping readers before repair (or use an isolated repair checkout), and invalidate affected checks and E2E evidence. Rerun affected checks on the repaired artifact. Keep the journey environment available after a failure only when instructions allow it and its owning qex job remains active with the full reservation; otherwise preserve evidence and stop the owned stack.

## External dependency handoff

A producer must provide the exact source revision, artifact identity/digest, old APIs still required by the consumer as well as the new APIs, build/toolchain variants, and a copied verification report in a durable location the consumer can read after producer-worktree cleanup. Validate the source/interface contract before an expensive AAR or native build. Verify the resulting artifact before installing it, atomically where practical.

Continue approved local tasks that do not need that dependency. Do not use timed retries against a missing artifact. Use the installed source-specific Paseo message wait described in [waiting.md](waiting.md): declare the producer, exact handoff prefix and finite deadline, then yield without polling. The patched scheduler consumes the matching native message directly. Generic token waits still require their producer adapter; an arbitrary message does not satisfy a token. Preserve user-owned pauses and report a missing runtime integration rather than repeatedly waking to say it is still waiting.

## Measure the next run

Use existing trace/receipt timestamps for task ready, launch, model/command start, lock acquisition, finish, and acceptance. A normal command duration includes lock wait unless acquisition is logged separately; never label it pure test execution. Mark missing timestamps unknown. Attribute elapsed intervals to execution (model/commands), environment repair, human decisions, external dependencies/transfers, resource-lock wait, and coordination/verification bookkeeping. Main-session and child lifetimes can include several of these; do not label all of it productive execution or all parent time waste. Track overlapping intervals and their union instead of double-counting.

Compare milestone-ready-to-work delays, implementation-finished-to-review-start delay, consolidated review/repair duration, compaction and context reconstruction, verifier handoffs, lock wait, environment repairs, and repeated checks with unchanged identities. Track reviewer launches, repeated context, and input/output/cache token usage alongside total elapsed time; delayed discovery can add downstream rework. Distinguish explicitly planned early reviews from consolidated scopes. For overlapping intervals, compute their union rather than summing durations. Final verification plus E2E has serial cost `V + E` and a theoretical overlap cost `max(V, E)` only when resources and inputs are independent; contention can erase the benefit. Do not report aggregate model minutes or no-child time as end-to-end latency savings.

## Acceptance progress and prolonged blockage

Maintain `<run dir>/status.md` from existing transitions and receipts. Keep it short enough for a user or replacement orchestrator to identify the actual distance to delivery:

```text
Capability: Android real cold route + authoritative readiness + native acquisition proven; evidence <path>
Implementation: committed <sha>; Review: feature 3/3, confirmed findings resolved
Android: 1/22 current measurement windows passed; 1 failed, 20 unrun, 0 invalidated
Other required evidence: Electron/browser journeys and final performance checks pending
Active: native layout repair; owner executor <run id>; source/artifact <identities>
Waiting: <exact dependency or none>; since <timestamp>; elapsed <known duration>
Next: <action, responsible owner, expected native event/deadline>
Time: execution / environment / human / external / lock / coordination <observed intervals or unknown>
```

The example is a schema illustration, not an assertion about the current run. For each platform count every discovered required window exactly once as passed, failed, unrun or invalidated; display criterion coverage separately where one criterion spans several windows. Invalidate previously passing coverage when its relevant inputs change. Keep historical passes as history rather than presenting them as current. A focused probe, capability result, completed implementation or reviewer verdict cannot stand in for final full-platform acceptance.

Update and surface status at meaningful boundaries, user status requests, native attention events and dependency deadlines. When a blockage exceeds its expected deadline, or lasts 30 minutes with no recorded expectation, surface its exact dependency, age and next action at the next native event or through an already-supported attention mechanism. This is an attention threshold, not an approval gate or a reason to stop productive work. Do not launch a timer loop, add a polling heartbeat or spend model turns just to collect elapsed time. Truly automatic timed attention requires runtime support; if absent, record that limitation and preserve event-driven waiting. Never describe an external wait as continuous active work or claim an unverified completion time.
