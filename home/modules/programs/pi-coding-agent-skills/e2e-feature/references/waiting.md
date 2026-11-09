# External dependency waits

The e2e-feature invocation opts only its isolated worktree into explicit goal scheduling. Once the worktree is verified, run `e2e-feature-run init --feature <feature>` before goal creation. It preserves other project settings and enables `strictExecutionContract` and idle backoff in `.pi/pi-goal-x-settings.json`; it does not modify global defaults or resume a paused goal. It creates a runtime-only `.pi/.gitignore` when absent. Preserve any existing ignore policy and check that runtime metadata is excluded from the feature diff.

After launching async work, finish required bookkeeping, then call `update_goal({continuation: {kind: "ready"}})` as the last tool call and end the turn. pi-goal-x holds ordinary checkpoints while this session has active background work, including the native verification workflow. The completion or supervisor request wakes you. Save `ready` again at the end of that execution if required work is runnable or running. Complete the goal only after all delivery requirements pass.

When nothing is runnable because another Paseo agent must produce an artifact, use a source-specific message wait. Record the producer's agent ID and agreed uppercase handoff token (for example `SDK_READY`) in `tasks.md`. Tell the producer to send its exact SHA and durable verification report to this orchestrator with its existing `paseo send --no-wait` handoff. Then declare:

```js
update_goal({continuation: {
  kind: "wait",
  reason: "Await compatible SDK delivery from <producer agent id>",
  deadline: "<future ISO timestamp with timezone>",
  message: {source_agent_id: "<producer agent id>", prefix: "SDK_READY"}
}})
```

Choose a finite deadline appropriate to the expected dependency, record it, and omit `polling`. Keep independent approved tasks running first. End immediately after the declaration; do not send status polls, timed retries, or extra waiting messages. Do not mark an expected dependency wait `blocked` just to stop goal continuation, and do not tell the user to run `/goal-resume` for an ordinary handoff.

The patched scheduler recognizes a native Paseo `agent-message` envelope from that exact producer and a first body token matching the prefix. That native delivery already starts a turn: the wait is consumed without emitting a second checkpoint. Read and validate the delivered revision, compatibility and evidence before starting the consumer. This matching selects a scheduling event; it does not attest that the delivered artifact is correct.

Unrelated agent messages and custom notifications leave the wait saved and do not create contract-repair checkpoints. A direct user message can steer the work and supersede the wait. User pauses, interrupted ownership, exhausted allowances and deadlines remain enforced; a producer message never resumes a user-paused goal. The wait survives a session restart. If the deadline expires, report the missing dependency and let the user decide how to continue; do not keep extending the same wait automatically.

For an external producer that cannot deliver a native Paseo message, use the existing goal wake-token protocol with a registered producer adapter. Do not invent tokens or assume arbitrary messages satisfy a generic token wait. If the required runtime or adapter is absent, preserve the exact limitation and report it rather than busy-looping. Host moves must recreate host-local scheduler state from the handoff and must preserve an explicit user pause.
