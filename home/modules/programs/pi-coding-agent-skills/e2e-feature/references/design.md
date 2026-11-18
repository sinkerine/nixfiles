# Independent visible Gemini design tab

Design uses `pi/magpie/group/gemini` with high thinking in its own top-level Paseo agent and visible Desktop tab. Executor, reviewer and verifier remain direct Pi subagents. Do not use a Pi subagent, agent-scoped creation or a create-then-detach sequence for design.

## Launch and visible-tab gate

Capture the orchestrator's `$PASEO_AGENT_ID` for the explicit handoff before launching design. If it is empty, omit the automatic handoff command from the brief and wait for the user to report that the approved plan is ready. Keep the independent visible design-tab requirement.

Write `<run dir>/design-brief.md` with the original request, preflight findings, exact worktree/branch/workspace, plan path, v2 plan requirements, known constraints, E2E classification, resource choices or unresolved proposals, and the approval/handoff contract below. Include that the Gemini Speed executor owns implementation and repairs, with separate Sol Fast review/verification; the design agent must not implement, run tests, commit or subdelegate.

Launch into the orchestrator's existing feature workspace. Unset parentage only for this command, retaining the orchestrator's environment and daemon connection settings:

```bash
env -u PASEO_AGENT_ID paseo run --no-wait --json \
  --provider pi/magpie/group/gemini --thinking high \
  --workspace <workspace id> \
  --cwd <worktree> --title "Design: <feature>" \
  "Read <run dir>/design-brief.md and follow its design, approval and handoff instructions."
```

Capture the returned design agent id. Inspect it with `paseo inspect <design agent id> --json`; require `ParentAgentId` to be `null`, verify the intended workspace/worktree, and confirm Gemini with high thinking. Then run `paseo agent open <design agent id> --json` and require a successful open result. Creation or presence in the workspace agent list alone does not satisfy the visible-tab gate.

Record the design agent id, workspace, model/thinking, independence evidence and successful opening in run state. Tell the user the `Design: <feature>` tab is open and will request final plan approval before handoff. If placement, independence, model or opening fails, preserve the existing agent id and exact error and report the infrastructure blocker. Stop handoff until corrected; do not create duplicate sessions, substitute a subagent, install Desktop or change daemon configuration. Do not silently substitute another model on quota exhaustion.

## Design, approval and handoff brief

Require the design agent to explore the code and maintain `docs/features/<feature>-plan.md` with all sections required by the v2 skill. It may ask the user for missing requirements. Default to one coherent executor task; extra sequential milestones need justified dependency/checkpoint boundaries. Keep implementation, setup/tooling and repair ownership with the executor, and independent review/verification with separate children.

Once the plan is complete, the design agent presents its file link, design summary, acceptance criteria and material tradeoffs to the user in its own tab. It calls `ask_user` for final approval of that exact plan, offering approval or requested changes, and waits for an explicit approving answer. If changes are requested, revise and ask again. Do not send `PLAN_READY` until approval exists.

Record the reviewed plan revision, approval question/reference and explicit user answer in the plan's **Approval** section. Correlated asynchronous user answers count; pending receipts, silence, timeout/cancellation, unrelated messages and model assertions do not. Inspect existing question/result evidence before treating approval as missing, and never open a duplicate pending question. Approval/status metadata alone does not invalidate the reviewed content. Material changes to scope, behavior, acceptance criteria, design or authorization require renewed human approval.

After approval, save the final plan and send this handoff to the captured orchestrator agent id:

```bash
paseo send <orchestrator agent id> --no-wait --prompt "PLAN_READY <worktree>/docs/features/<feature>-plan.md: approved by the user. <one-line summary and approval record reference>"
```

Then tell the user the approved plan has been handed off. Never claim approval the user did not give. Later orchestrator questions return to this same tab with `paseo send --no-wait`; revised material design requires renewed approval before another `PLAN_READY`. The orchestrator verifies and reuses the approval record, commits the approved plan and archives the design tab before execution-goal creation and implementation.

## Waiting and recovery

After opening and bounded read-only host checks, the orchestrator yields. Do not poll the design tab or treat ordinary turn-finished notices as handoff. Only `PLAN_READY` or a user report that the plan is ready triggers plan/approval checks, and neither bypasses them. Before a goal exists, use the native Paseo message delivery; after a goal exists, a later design dependency may use the shared source-specific wait contract. A separate design agent does not hold Pi subagent continuation automatically.

Preserve the design agent id and approved plan across interruption or host moves. Reuse a live correctly placed tab when possible. If a supported move requires recreation, first confirm the old writer stopped, preserve decisions and approval evidence, then launch and open a new independent Gemini tab with the same gates. Do not recreate a completed design or request duplicate approval merely because execution moved hosts.
