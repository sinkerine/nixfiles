# Waiting for work

Goals belong to the current session. `e2e-feature-run init --feature <feature>` initializes runtime metadata and ignores legacy paths; it does not write goal settings. Active goals automatically continue when idle. No ready checkpoint is required. While this session has active pi-subagents runs, continuation holds; completion and attention notices wake the parent. Finish bookkeeping and end the turn when nothing is runnable.

For a separate producer that will send a native Paseo message, save a source-specific wait:

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
