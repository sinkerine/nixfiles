# Waiting for work

Goals belong to the current session. `e2e-feature-run init --feature <feature>` initializes runtime metadata and ignores legacy paths; it does not write goal settings. Active goals automatically continue when idle. No ready checkpoint is required. While this session has active pi-subagents runs, continuation holds; completion and attention notices wake the parent. Finish bookkeeping and end the turn when nothing is runnable.

Finish required bookkeeping and yield when nothing is runnable. Verify the continuation hold and completion wake from existing events rather than assuming skill prose guarantees runtime behavior. Complete the goal only after all delivery requirements pass.

For a separate producer that will send a native Paseo message, record its agent ID and agreed first-token prefix in `tasks.md`. Tell it to send the exact SHA and durable verification report through its existing `paseo send --no-wait` handoff, then save a source-specific wait:

```js
update_goal({continuation: {
  kind: "wait",
  reason: "Waiting for the SDK producer's committed interface and verification report",
  deadline: "<finite ISO timestamp appropriate to this dependency>",
  message: {source_agent_id: "<producer agent id>", prefix: "SDK_READY"}
}})
```

Keep independent approved work running first. End the turn after declaring the wait. The wait persists across restarts. Only a native Paseo `agent-message` from that source whose first body token equals the prefix consumes it. That delivery starts a turn itself; no extra continuation is dispatched. Unrelated agent messages and custom notifications leave the wait saved. A direct user message supersedes the wait. A producer delivery never resumes a user-paused goal.

An expired deadline blocks the goal once with `wait deadline expired: <reason>`. Report the missing dependency and preserve the blocked state until user steering; never extend the deadline automatically. A finite deadline without a message condition also blocks when expired; it is not a polling timer or a generic wake-token protocol.

For an explicit handoff to another tab on this host, use `adopt_goal({goal_id: "<id>"})`. Adoption transfers ownership and the previous tab stops at its next idle check. Adoption in a user-triggered handoff starts work in that turn and preserves paused/blocked status. The agent can resume using `update_goal({status: "active"})` when the user requests continuing. Host moves create a new host-local goal from the handoff and preserve user pauses; they do not transfer the goal store.

## Runtime health and recovery contract

Treat repeated automatic checkpoints during active work or a saved wait, missed/duplicate completion delivery, lost restart ownership, and missing resumed-worker transcript binding as infrastructure defects. Inspect the named workflow and relevant event/receipt/transcript metadata once, distinguishing actual activity from a stale UI row; a blank tab alone does not prove the worker stopped. Preserve the live process, source changes and artifacts. Use supported session/run recovery; do not start a competing writer, restart the production daemon, invent a generic wait token or repeatedly renew unknown wait ids to suppress symptoms.

Record the runtime/package revision, parent/child identities, expected and observed events/times, and exact failure in run state. Report a degraded runtime once with its effect on progress. Continue independent authorized work when possible; when supported recovery makes no progress, report the concrete infrastructure blocker instead of generating repeated waiting turns. Where the runtime supports the documented source-specific wait, use it for its actual registered producer; do not claim a fallback exists without checking the installed interface.

Runtime fixes belong in the owning package, with regressions covering the applicable cases below. Merely changing this skill does not implement them; do not silently expand a feature repair into a harness deployment or live daemon restart.

| Case | Required observable behavior |
| --- | --- |
| Parent yields with async workflow or deterministic verification active | Ordinary goal checkpoints remain suppressed; the child continues without polling turns. |
| Child completes, fails or asks a supervisor decision | The parent receives the appropriate actionable event promptly and handles it once; designated task-boundary wakes still work while siblings run. |
| Native source-specific dependency message arrives | The saved wait is consumed by that exact source/prefix without a duplicate checkpoint; unrelated events and user pauses remain preserved. |
| Daemon/session restarts while parent is idle and child work exists | Ownership and run evidence recover through the supported path; the parent resumes once and eventual completion wakes it. |
| A retained worker resumes under a new workflow row | The correct row has its live transcript binding even when the transcript file was registered previously; saved final-report routing does not replace live visibility. |
| Delayed or repeated notifications arrive | No duplicate worker, acceptance transition, retry or delivery action is created. |

Use existing runtime telemetry to measure event-to-parent delay. Add timed blocked-state attention through the existing runtime only when it supports it; otherwise expose dependency/age/deadline on the next native event as [latency.md](latency.md) describes. Do not introduce polling to compensate for missing observability.
