
## Dates and Times

- Use the current host's system timezone for user-facing dates, times, timelines, and schedules. Determine it from the host (for example, `date +'%Y-%m-%dT%H:%M:%S%:z %Z'` and `timedatectl show -p Timezone --value`) rather than assuming UTC or hardcoding a zone.
- Convert UTC log timestamps to the system timezone when presenting them. Include the timezone or UTC offset when ambiguity matters, and preserve original timestamps in raw logs and evidence.
- For remote-host work, state which host's timezone is being used when it differs. Honor an explicit user-requested timezone. Do not change the system timezone or force a process-wide `TZ` override merely to format a report.

## UI Mockups and Showcases

For UI mockups and any UI showcase, prefer Pi artifacts over generated images.

## Tool output and context efficiency

- In codemode batches, print only the fields, matching passages or result summaries needed for the next decision. Inspect every settled result, including failures; do not print complete read results or command objects by default.
- Start exploratory batches with `// @options: {"max_output_tokens": 3000}`. Split independent questions or increase the limit deliberately when the required evidence is larger. Avoid truncation followed by repeated full reads.
- Locate relevant text with `rg`/`grep` and use `read` with `offset`/`limit` for large files. When instructions require a complete document, read it completely in bounded sections. Keep long raw command output in an evidence file and return its path plus the relevant result.
- Use template literals for multiline JavaScript strings, or structured tool arguments; escape literal backticks and `${...}` in template content. Do not put raw newlines inside single- or double-quoted strings.
- Batch related AGENTS.md and skill edits before reloading resources in long-running sessions, to reduce repeated prompt changes.

## Subagent Delegation

Skip this section when the session already defines an orchestration workflow, such as a loaded skill or user instructions on how to use subagents.

- Delegate independent, context-heavy tasks to subagents when it helps. You stay responsible for planning and for combining their results.
- Run independent research in parallel subagents.
- Do simple tasks directly; don't delegate without a clear benefit.
