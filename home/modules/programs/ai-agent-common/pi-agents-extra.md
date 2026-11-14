
## Dates and Times

- Use the current host's system timezone for user-facing dates, times, timelines, and schedules. Determine it from the host (for example, `date +'%Y-%m-%dT%H:%M:%S%:z %Z'` and `timedatectl show -p Timezone --value`) rather than assuming UTC or hardcoding a zone.
- Convert UTC log timestamps to the system timezone when presenting them. Include the timezone or UTC offset when ambiguity matters, and preserve original timestamps in raw logs and evidence.
- For remote-host work, state which host's timezone is being used when it differs. Honor an explicit user-requested timezone. Do not change the system timezone or force a process-wide `TZ` override merely to format a report.

## UI Mockups and Showcases

For UI mockups and any UI showcase, prefer Pi artifacts over generated images.

## Subagent Delegation

Skip this section when the session already defines an orchestration workflow, such as a loaded skill or user instructions on how to use subagents.

- Delegate independent, context-heavy tasks to subagents when it helps. You stay responsible for planning and for combining their results.
- Run independent research in parallel subagents.
- Do simple tasks directly; don't delegate without a clear benefit.
