---
name: e2e-feature
description: "Opt-in autonomous feature development: explore, plan, implement, verify, review, repair, and deliver, using Pi subagents when useful."
disable-model-invocation: true
---

# End-to-end feature workflow

Use this workflow only when the user explicitly invokes `/skill:e2e-feature <request>`. Complete one feature through exploration, planning, implementation, verification, review, repair, and delivery. Do not activate it for ordinary requests.

Stop and ask the user only for a destructive or irreversible operation, a security-sensitive action, a side effect outside the worktree, or a request so ambiguous that every path forward is a guess. Decide everything else yourself, record it as `Ruling: <decision> — <why> — <cost if wrong>`, and keep going.

## Explore

Inspect the relevant code paths, architecture, existing patterns, tests, and user-facing behavior. Use `scout` for bounded local reconnaissance and `researcher` only when external documentation is needed. Parallelize independent read-only investigation when it reduces time.
## Plan and tasks

State the target behavior and measurable acceptance criteria. Break the work into actionable tasks with dependencies and verification checks. For a task that will be delegated, write down the exact interfaces it consumes and produces; a worker sees only its own task. Keep a small plan in the parent context; for substantial or multi-session work, persist a lightweight Markdown plan such as `docs/plans/<feature>.md` and reconcile it with the code when resuming. Ask `oracle` about important architecture tradeoffs or unclear safety decisions.

## Implement

Before the first edit, record the base commit and any files that are already modified, so the feature diff can be isolated later. Work through dependent tasks in order and continue through implementation instead of stopping at a plan. Implement directly when delegation adds no value. Use `worker` for well-scoped implementation tasks. Give each worker one task with its acceptance checks and interfaces, not the session history, and require it to end with `DONE`, `DONE_WITH_CONCERNS`, `NEEDS_CONTEXT`, or `BLOCKED`. Read any concerns before moving on. On `NEEDS_CONTEXT` or `BLOCKED`, change something before re-dispatching: more context, a smaller task, or a more capable model. Avoid concurrent writes to one worktree; use isolated worktrees only when parallel implementation is worthwhile and integrate their results explicitly. Preserve project conventions and keep changes small and testable.

## Verify

Run the relevant targeted tests, type checks, lint, builds, and functional checks available in the project. Evidence must come from a run made after the last edit. Inspect actual output and check it against each acceptance criterion one by one; passing tests alone do not show the criteria are met, and a subagent's success message is not evidence by itself. Record passed, failed, and unavailable checks.

## Review and repair

For substantive changes, obtain an independent fresh `reviewer` pass covering correctness, regressions, security, edge cases, test coverage, and simplicity. Give the reviewer the feature diff from the recorded base and the acceptance criteria, not the session history; the reviewer is read-only and does not spawn subagents. Check each finding against the code before acting on it and reject wrong ones with reasoning. Fix Critical and Important findings and rerun affected verification after each meaningful fix; carry Minor findings to the delivery report. Reproduce a failure and state its root cause before attempting a fix. Allow at most three evidence-driven repair attempts for a recurring failure; change the hypothesis or approach before retrying. For subagent infrastructure failures, preserve the exact error and Git/worktree state and use pi-subagents' supported recovery path. Escalate difficult root-cause analysis to `oracle`; report persistent blockers clearly.

## Deliver

Inspect the final diff. Report changed files and behavior, completed tasks, verification evidence, rulings made, deferred Minor findings, and unresolved risks. Prepare a commit or PR only when explicitly authorized or required by repository policy. Never claim completion while required checks remain unverified.

Use pi-subagents' bundled roles and natural-language delegation. Prefer per-run model and effort overrides when needed. The configured Magpie routes are `gpt-6-luna` for scout/research/delegate, `gpt-6.1-sol` for worker/reviewer/evidence-auditor, and `gpt-6-astra` for oracle. Add a supported thinking suffix such as `magpie/gpt-6.1-sol:high` only after confirming the exact model through `subagent({ action: "models" })`; if unavailable, use the closest advertised Magpie model and record the substitution.

Do not build custom workflow scripts, milestone schedulers, daemons, crash-restart services, or automatic production changes. This workflow handles one feature at a time, is opt-in, and stops when recovery makes no progress. It does not provide unattended crash-proof resume or cross-milestone scheduling.
