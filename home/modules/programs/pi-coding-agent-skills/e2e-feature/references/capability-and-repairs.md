# Capability checks and repair ownership

Read after the design handoff and before substantial implementation, or when assigning an E2E repair. These rules preserve the approved acceptance criteria, three-round review budget, independent host verification, and authorization boundaries.

## Prove the critical test path early

Use two stages, with results in `<run dir>/verification.md`:

1. **Cheap host check.** During design, spend at most 60 seconds checking available memory/disk, device or display access, toolchain and dependency identities, runner discovery, required generated packages, isolated ports/state and existing setup commands. This is read-only apart from authorized isolated smoke state. Mark anything not exercised as unknown. Repeat the relevant checks before a host transfer; an implementation-capable host may not support the remaining native tests.
2. **Executable capability check.** After the plan is finalized and its required authorization is settled, prove the hardest test path on each materially different target environment before substantial feature implementation and consolidated review. Reuse the implementation worker for setup, the experiment and subsequent implementation when ownership permits; do not add a separate model worker merely to inspect prerequisites. Use existing project tooling first. Build or provision only within the approved isolated scope. Set a realistic command/run timeout for provisioning and native builds; the design-stage 60-second limit does not apply here.

The executable check must reach the relevant screen through its real entry path, establish the intended target's authoritative readiness, perform one representative action, and collect the actual evidence needed to distinguish success from failure at the approved precision and cadence. For a scrolling feature, exercise cold launch → current transcript loaded → actual end observed → output grows → position measured. A generic app launch or test-runner version is insufficient. Choose additional probes only for materially different acquisition methods or environments; do not run every journey variant at this stage.

This experiment establishes testability on existing behavior or the smallest necessary vertical slice. The feature assertion may fail on the baseline: retain that failure and show that the harness detects it. Do not require the unimplemented feature to pass or treat a capability result as final feature acceptance. Record build/environment identity, exact command, observed readiness, measurement method, precision/cadence, raw evidence paths and unresolved limitations. A button disappearing or a stable later viewport does not prove an earlier authoritative landing. A changed fixture, missing observation or unsupported measurement remains an explicit gap.

Resolve capability blockers before broad implementation. Continue independent approved work where useful, but do not spend a full implementation/review cycle on an untestable approach. Adapt the harness or environment autonomously within scope. If the approved numeric/behavioral contract is infeasible or a different environment requires new authorization, identify the exact requirement or authorization decision for the user. A setup failure alone is not permission to weaken criteria. Apply the main skill's existing missing-E2E-instructions gate when the experiment needs instructions that are still missing; do not invent a second approval round.

## Reuse environment tooling

Keep stable setup, launch, readiness, acquisition, reset and teardown commands in maintained project scripts/recipes when those paths are within the approved ownership. Otherwise use run-local scripts and record a concrete promotion candidate for delivery; do not edit an unrelated repository or expand project-wide policy silently. Software installation follows the repository's package-management rules, including Nix where required.

Scripts must fail fast on invalid prerequisites/restoration, preserve useful diagnostics, declare resource/lock ownership, and return an explicit result. Record supported SDK/runtime/device versions, dependency identity, isolated state/ports, build and emulator memory needs, and cleanup ownership. Reuse healthy tooling and caches after checking identities; do not rediscover the setup in every worker brief. Use test-owned state; reset only as allowed by the recipe, and preserve failure evidence before resetting. Do not clean unrelated state to free resources.

Separate observation capability from product assertions. Save real acquisition failures and regression fixtures for the harness so its repairs are testable without another full device run. Preserve provenance and negative controls; fixtures cannot substitute for the required fresh native proof.

## Give one worker the repair-and-proof loop

Assign a coherent repair goal rather than one authorization per technique. The brief names:

- The failure and affected acceptance criteria/entry paths, evidence paths, and current source/artifact identities.
- Owned product, harness, regression-test and project-tooling paths sufficient for the repair; other active readers/writers and resources that must remain ordered.
- Protected behavior/numeric limits, side-effect boundaries, allowed setup/restoration and explicit exclusions.
- The diagnostic action, affected development tests and journey steps, evidence/report locations, completion condition and realistic timeout.

Within those boundaries, the worker owns diagnosis → repair → targeted regression tests → affected journey rerun, including related harness corrections. It may choose implementation and observation techniques without another supervisor decision when scope and authorization already cover them. It must not weaken acceptance, alter protected state or edit another owner's files. A new technique is not itself a scope decision. Escalate only for a genuine unresolved behavior/scope/authorization choice, an actual external dependency, or a runtime failure requiring supported recovery.

The worker saves checkpoints before expensive or fragile commands. If its run times out, inspect actual command/process state and use supported recovery; preserve live commands and completed artifacts rather than restarting from the beginning. Use a timeout suitable for the known workload instead of allowing a default short timeout to create repeated recoveries. A longer timeout never waives reassessment when evidence stops improving.

Keep a separate independent journey worker for final acceptance. While a repair worker mutates the source, that tester and other readers of affected inputs must be idle or isolated. Once the repair settles, the parent inspects the concise delta and evidence, runs independent affected host gates, uses remaining review rounds where required, commits at a safe point and pins stable artifacts. Then resume the independent tester for the complete required journey on the final inputs. Repair-worker diagnostic passes do not replace final coverage or independent evidence. Preserve the original review counters across all loops.

## Reassess repeated failures without a retry cap

Repairs and deterministic reruns have no fixed attempt limit. After two attempts with the same failure signature and no new discriminating evidence, or 20 minutes of active investigation without new evidence, the worker must update a short diagnosis record before its next experiment. These are reassessment triggers, not stop/approval gates, model-turn timers or reasons to interrupt a productive live command. Exclude known command execution, resource waits and external/human waits from the active-investigation interval.

Record in `<run dir>/diagnosis.md`:

1. Failure signature and exact source/environment identity.
2. Hypothesis tested, experiment and observed result, including invalid experiments.
3. What evidence changed and what explanations remain.
4. The smallest next experiment that distinguishes those explanations, or the different method replacing an unsupported approach.

Continue autonomously with the changed approach. Do not repeat a failed protocol call, blind launch/reset, rebuild, restore or baseline comparison unchanged without a new reason. When a comparison depends on restored state, assert the required bytes, types, ownership/modes and served artifact identity before launching; failed preflight invalidates the experiment and must stop its shell. Do not claim a fix from a single successful launch of an intermittent failure. Unsupported instrumentation should prompt another evidence source or a regression based on the observed symptom, with causal uncertainty stated.

The parent reads the diagnosis at the next meaningful boundary or a real decision request; this rule must not generate a new parent turn per attempt. Report a concrete infrastructure blocker when supported recovery makes no progress. No repair-attempt count requires the user to authorize continuing ordinary fixes.
