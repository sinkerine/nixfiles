# pi-goal: session-bound goals for Pi (replacing pi-goal-x)

Status: approved for implementation (2026-11-14). Owner decisions: build a new package that
replaces `pi-goal-x` in `home/modules/programs/pi-coding-agent.nix`; drop the goal task tree.
Subsequent owner decision: extract the source to `~/dev/pi-goal` and `sinkerine/pi-goal`;
nixfiles retains the pinned Nix package definition.

## 1. Why

`pi-goal-x` (fork `sinkerine/pi-goal-x` of `tmonk/pi-goal-x`, ~16.5k lines TS, plus
`pkgs/pi-goal-x/workflow-efficiency.patch`) failed repeatedly in the Paseo stable-scroll
workspace (`~/.paseo/worktrees/28vpgp2p/recovery-stable-scroll-return-20261112`, tabs
1d4a1dc, d58c3b3, 8f35ec7, 4b8f81c, 807dab9). Every failure traces to its model: a
**project-wide goal pool** (`<cwd>/.pi/goals`) with a **per-session focus**, user-only
lifecycle commands, and cross-process revision checks.

| # | Observed failure | Root cause in pi-goal-x |
|---|---|---|
| F1 | New tabs answer "run `/goal-focus`" instead of working; user had to say "run it without goals". | Sessions start unfocused; `[PI GOAL UNFOCUSED]` reminder injected on every request while any open goal exists in the cwd pool. |
| F2 | "stop those goals" impossible for the agent; `/goal-focus` + `/goal-cancel` left goal `mwftd397` running (`/goal-cancel` only discards drafts). | Focus/resume/clear are user-only commands; agent pause rejected; confusing command set. |
| F3 | "continue the goal" refused until the user typed `/goal-resume`, repeatedly. | Paused state only leaves via the user command. |
| F4 | `Goal mwe0ctfb was modified by another process (revision 1028 -> 1032)`; recovery needed `/goal-refresh` then `/goal-resume`. | Two sessions mutating one pooled goal; cached revisions. |
| F5 | Tab handoff improvised a `GOAL_HANDOFF_READY` message protocol, then a second goal was created → two open goals in the pool → F1 permanent for that worktree. | No ownership transfer primitive. |
| F6 | Goal kept auto-continuing in d58c3b3 after the user tried to stop it elsewhere; it revived a worker that edited the same files as 807dab9 (ownership conflict). | No way to stop a goal owned by another session; continuation is unconditional while "running". |
| F7 | Dozens of `update_goal({continuation:{kind:"ready"}})` calls per run. | Strict execution contract requires a checkpoint declaration every turn. |
| F8 | No goal indicator in Paseo. | Paseo's adapter only maps the task tree (`details.version === 3`) to a todo item; status is a TUI widget Paseo does not render. Fixed by a new Paseo adapter (§10). |

Out of scope here: pi-subagents ties retained workers to their launching session (cross-parent
resume rejected, chips stay in the old tab). The new design must not make that worse and should
reduce session switching, but it does not fix pi-subagents.

## 2. Reference: Codex goals

Source: `openai/codex` at `7924f95` (clone at `/tmp/codex-src-dl/codex`; re-clone with
`git clone --filter=blob:none https://github.com/openai/codex` if missing). Key files:
`codex-rs/ext/goal/src/{spec,runtime,extension,tool,accounting,steering}.rs`,
`codex-rs/ext/goal/templates/goals/{continuation,budget_limit,objective_updated}.md`,
`codex-rs/state/goals_migrations/*.sql`, `codex-rs/state/src/runtime/goals.rs`,
`codex-rs/app-server/src/request_processors/thread_fork_goal.rs`.

What we copy:
- **One goal per thread** (`thread_goals.thread_id` is the primary key). No pool, no focus.
- **Resume restores automatically**: an `active` goal resumes continuing when the thread is idle.
- **Fork copies a snapshot** to the new thread **with continuation deferred** until the first user
  turn in the fork (`thread_goal_continuation_deferrals`).
- **Subagent threads** do not run the parent's goal; accounting rolls up to the root.
- **Three tools**: `get_goal`, `create_goal` (only when explicitly requested), `update_goal`
  (`complete` | `blocked` | `paused`; `paused` only on explicit user request). Continuation is a
  hidden prompt on idle; it needs no checkpoint call.
- **Continuation prompt**: evidence-first, no-progress classification, blocked only after the same
  blocker for three consecutive goal turns, strict completion audit. Port `continuation.md` and
  `budget_limit.md` (Apache-2.0: keep attribution and a NOTICE line in the package).

## 3. Package layout

- Canonical source: `sinkerine/pi-goal`, checked out at `~/dev/pi-goal`: `package.json`
  (Pi package manifest), `extensions/*.ts`, `prompts/*.md`, `tests/`, README and licenses.
  `pkgs/pi-goal/default.nix` fetches a pinned GitHub commit and owns the Nix packaging.
  Register in `pkgs/default.nix`; install path `lib/node_modules/pi-goal`.
- Unit tests run in the Nix `checkPhase` the same way `pkgs/pi-goal-x/default.nix` does (link
  `typebox` and `@earendil-works/{pi-coding-agent,pi-ai,pi-tui}` from `pi-coding-agent`).
- Reuse (copy, with MIT attribution) only small, proven pieces of pi-goal-x:
  `storage/goal-lock.ts`, `storage/atomic-rename.ts`, `quota-retry.ts` (magpie quota wait via
  `PI_GOAL_QUOTA_URL`), `network-error-backoff.ts`, `goal-background-work.ts` (pi-subagents
  `subagents:rpc:v1` active-run probe), `isDelegatedGoalSession` from `goal-session-safety.ts`,
  and the Paseo `agent-message` source/prefix matcher from `workflow-efficiency.patch`.
- Target size: ≤ ~2k lines of non-test TS. No drafting questionnaire, auditor, sisyphus mode,
  task tree, ledger, pool snapshot/caches, layered settings, dashboard widget, or shortcuts.

## 4. Data model and storage

Authoritative record, one JSON file per goal, outside the worktree so worktree diffs and host
moves never carry it:

```
${XDG_STATE_HOME:-~/.local/state}/pi-goal/goals/<goalId>.json
{
  "version": 1,
  "id": "<goalId>",              // short sortable id
  "objective": "<full text, verbatim>",
  "status": "active" | "paused" | "blocked" | "complete" | "budget_limited",
  "statusReason": "<optional>",
  "ownerSessionId": "<pi session id>",
  "repoRoot": "<git toplevel or cwd>", "cwd": "<cwd at creation>",
  "tokenBudget": null | n, "tokensUsed": n, "timeUsedSeconds": n,
  "deferContinuation": false,     // set on fork/adopt until first user turn
  "wait": null | { "reason", "deadline", "message"?: {"source_agent_id","prefix"} },
  "retry": null | { "at", "reason" },   // quota / network backoff
  "noProgressTurns": 0,
  "revision": n, "createdAt", "updatedAt",
  "history": [ {"at","event","sessionId","detail"} ]   // bounded, last ~50
}
```

- Writes: per-goal lock + atomic rename + `revision++`. A mutation re-reads under the lock and
  applies to the fresh record (never "refresh and retry" errors surfaced to the user).
- Session binding: the session appends one custom entry `pi-goal:bind {goalId, sessionId}` when it
  creates or adopts a goal, and `pi-goal:unbind` when the goal is cleared/completed. On
  `session_start` the extension takes the last binding on the current branch.
- Ownership rule: a session may auto-continue a goal only if `record.ownerSessionId === own
  session id` and `status === "active"`. This is re-read from disk (cheap stat+read) immediately
  before every continuation dispatch, so a status or ownership change made by any other process
  stops this session on its next idle point.

## 5. Lifecycle

- **Create**: `create_goal({objective, token_budget?})` or `/goal <objective>` → status `active`,
  owner = this session, bind entry, start working immediately. Fails if this session already has
  an unfinished bound goal (tell the agent to complete/clear it or ask the user).
- **Resume (same session id)**: Paseo/pi reopen the same session file → binding found → owner
  matches → restore; `active` goals continue on idle. No user action required.
- **Fork (session id differs from binding owner)**: Pi `/fork`, Paseo session fork
  (`resolvePiInheritedForkEntries` in Paseo's pi provider copies entries into a new session id).
  Create a **new goal id** copied from the snapshot (objective, usage), owner = new session,
  `deferContinuation = true`; the original goal is untouched. Deferral clears at the first user
  turn in the fork. This mirrors Codex `inherit_thread_goal_snapshot`.
- **Adopt (handoff to another tab)**: `adopt_goal({goal_id})` tool or `/goal-adopt <id>`. Under the
  lock: set `ownerSessionId` = this session, append history, set `deferContinuation = false` when
  the adopting turn is itself user-triggered (a Paseo `create_agent` initial prompt counts) — the
  adopting agent continues in that turn. Bind entry. The previous owner stops at its next idle
  check (it will see the owner changed) and shows a one-line notice "goal <id> adopted by <sid>".
  Adopt preserves `paused`/`blocked` status: adopting a user-paused goal does not resume it.
- **Pause / resume / clear / complete / block**: see §6; all are record mutations, any session.
- **Interrupt**: a user abort (Esc / Paseo cancel) of a goal-continuation turn sets `paused` with
  reason "interrupted by user" (Codex behavior). Aborting a user-triggered turn leaves status alone.
- **Budget**: when `tokensUsed >= tokenBudget`, status → `budget_limited`, send the budget-limit
  steering prompt once, no further continuation.

## 6. Tools and commands

Agent tools (registered only in non-delegated sessions, see §8):

| Tool | Behavior |
|---|---|
| `get_goal({goal_id?})` | Bound goal (or a goal by id): objective, status, reason, owner, usage, budget, wait. |
| `list_goals()` | Read-only list of goals for this `repoRoot` with status and owner session; marks the bound one. Never injected into prompts automatically. |
| `create_goal({objective, token_budget?})` | Only when the user or system/developer instructions explicitly request a goal. Compact receipt: id + status (no objective echo). |
| `update_goal({status?, reason?, goal_id?, continuation?})` | `status: "complete"` (after the completion audit), `"blocked"` (requires `reason`; same blocker ≥3 consecutive goal turns), `"paused"` (**accepted only in a turn whose trigger is a user message**, i.e. not a continuation turn; this makes "stop/pause those goals" work while still preventing self-pausing). `goal_id` lets the user-triggered turn pause/complete/clear another session's goal ("stop the goal in the other tab"). `continuation: {kind:"wait", reason, deadline, message?}` saves a wait (§7); `{kind:"ready"}` is accepted as a no-op for compatibility. |
| `adopt_goal({goal_id})` | Only on explicit user/handoff request. §5. |
| `clear_goal({goal_id?})` | User-triggered turns only. Archives (status stays, `archivedAt` set, unbind). |

Resume is intentionally **also** available to the agent: `update_goal({status:"active"})` is
accepted only in a user-triggered turn (e.g. user says "continue the goal"). Agents never resume
from a continuation turn.

User commands (thin wrappers over the same functions): `/goal <objective>` (create; no
drafting), `/goal` (status), `/goal-list`, `/goal-pause [id]`, `/goal-resume [id]`,
`/goal-clear [id]` (confirm when UI is available, otherwise act), `/goal-adopt <id>`. No
`/goal-focus`, `/goal-cancel`, `/goal-refresh`, `/goal-tweak`, settings dialog, or shortcuts.
Commands must work in Paseo (no required select/input dialogs; ids as arguments).

Tool `details` must not use `{version: 3, goal: {taskList}}` so Paseo's existing upstream
`pi-goal-x` adapter (`packages/server/src/server/agent/providers/pi/extensions/pi-goal-x/`)
stays inert. Instead every goal tool result and goal custom message carries
`details: {piGoal: 1, goal: <public snapshot: id, status, statusReason, objectivePreview
(first ~200 chars), ownerSessionId, tokensUsed, tokenBudget, wait?>}` for the new Paseo
adapter (§10).

## 7. Continuation scheduler

On `agent_settled` (session idle, no pending user input), dispatch one hidden continuation
message with `pi.sendMessage(..., {triggerTurn: true})` only if all hold, re-reading the record:

1. bound goal exists, `status === "active"`, `ownerSessionId` is this session;
2. `deferContinuation` is false;
3. no saved `wait` whose deadline is in the future (an expired wait: notify once, set
   `blocked` with reason "wait deadline expired: …", no auto-extension);
4. no `retry` in the future (quota/network backoff; schedule a timer for `retry.at`);
5. pi-subagents reports zero active runs for this session (RPC probe; fail open if the probe
   is unavailable). Their completion/attention notices already wake the session;
6. budget not exhausted.

Wait consumption: a native Paseo `agent-message` from `wait.message.source_agent_id` whose first
body token equals `wait.message.prefix` clears the wait (that delivery already starts a turn, so no
extra continuation). A direct user message also clears the wait. Unrelated messages leave it.

No-progress guard: if a continuation turn ends with no tool calls, `noProgressTurns++`; at 3,
set `blocked` with reason "no progress in 3 continuation turns". Any tool call resets it.

Context: inject a compact goal block before each request when a goal is bound (status,
objective truncated to ~2k chars with "use get_goal for full text", usage/budget, active wait).
Inject nothing when no goal is bound — no unfocused reminders, ever.

Continuation prompt = ported Codex `continuation.md` plus two lines for our environment:
"Never launch, revive, or restart workers solely because this continuation arrived; first confirm
from authoritative state (run status, process, files) that no live writer owns the work." and
"While pi-subagents runs are active you are not woken by continuations; end the turn when nothing
is runnable."

Accounting: add assistant usage of every turn in the owning session to `tokensUsed`;
`timeUsedSeconds` from turn wall time. Child (pi-subagents) usage roll-up is optional: include it
only if pi-subagents completion events already carry usage; otherwise skip.

## 8. Subagents and delegated sessions

- When `isDelegatedGoalSession()` (`PI_SUBAGENT_CHILD=1` or `PI_SUBAGENT_DEPTH>0`): register no
  tools, inject no context, never continue. Children cannot see or mutate goals.
- Parent continuation is held while its runs are active (§7.5). Do not message children.

## 9. Integration changes in this repo

1. `pkgs/pi-goal/default.nix` fetches `sinkerine/pi-goal`; `pkgs/default.nix` adds `pi-goal`. Keep `pkgs/pi-goal-x/` in place for now
   (unreferenced) unless removal is trivial; note it in `forked-projects.md` as superseded.
2. `home/modules/programs/pi-coding-agent.nix`: replace the `piGoalX` package path with
   `pi-goal`; keep `PI_GOAL_QUOTA_URL` wrapper (comment now refers to pi-goal).
3. `home/modules/programs/pi-coding-agent-skills/e2e-feature/`:
   - `SKILL.md`: `create_goal` without `mode`; remove task/progress-tool instructions (tasks live in
     `<run dir>/tasks.md`); drop "make `update_goal({continuation:{kind:"ready"}})` the last call"
     (continuation is automatic); keep message waits; resume after compaction via `get_goal`;
     handoff to a new tab uses `adopt_goal`.
   - `references/waiting.md`: rewrite to §7 semantics (no `strictExecutionContract`, no
     `.pi/pi-goal-x-settings.json`, no `/goal-resume` advice for handoffs).
   - `scripts/verify.py` (`init` writes `.pi/pi-goal-x-settings.json` and ignores `.pi/goals/`):
     stop writing goal settings; keep ignoring legacy paths so old worktrees stay clean; update
     `tests/test_verify.py`.
   - grep the other references (`delivery.md`, `verification.md`, `host-move.md`,
     `capability-and-repairs.md`) and fix goal wording that assumes pi-goal-x.
4. `pkgs/e2e-dispatch/e2e-dispatch.py` (`h_move_goals_aside`, `h_goal_states` read
   `<worktree>/.pi/goals`) and `dispatch-workspaces/SKILL.md`: switch paused-goal detection to the
   new store (goals whose `repoRoot`/`cwd` is the worktree), update tests in
   `test_workspace_dispatch.py`.
5. `forked-projects.md`: record the standalone pi-goal repository and mark pi-goal-x superseded.

Legacy goals: the new extension ignores `<cwd>/.pi/goals`. Provide `/goal-import <path>` only if
cheap (objective + usage → new goal, status `paused`, owner = importing session); otherwise skip.

## 10. Paseo adapter (fork `sinkerine/paseo`)

Paseo's Pi provider supports per-extension adapters
(`packages/server/src/server/agent/providers/pi/extensions/contract.ts`, registered in
`extensions/registry.ts`). The upstream `pi-goal-x` adapter only maps the task tree to a `todo`
item, which is why no goal indicator showed (F8). Add a **new** adapter `pi-goal` next to it
(keep `pi-goal-x` untouched: it is upstream code and stays inert for the new package):

- `mapToolCall`: for completed `create_goal` / `get_goal` / `update_goal` / `adopt_goal` /
  `clear_goal` results with `details.piGoal === 1`, emit a single-entry `todo` timeline item
  (`text: "Goal: <objectivePreview>"`, status `in_progress` for active, `completed` for complete,
  `pending` otherwise; include status/reason in the text when not active) so the goal shows in
  Paseo's existing todo UI without app changes.
- `mapCustomMessage`: map pi-goal's custom messages (continuation dispatch, status changes,
  "adopted by another session", budget limit, expired wait) to the same `todo` update and/or a
  `notification` item; continuation prompts must not render as user messages.
- `outOfBandCommands`: `goal-pause`, `goal-resume`, `goal-clear`, `goal-list`, `goal-adopt`, so
  the user can pause/stop a goal while a turn is running without cancelling it (mirrors Paseo's
  Codex `/goal pause` out-of-band handling in `providers/codex-app-server-agent.ts`). Check how
  `pi-btw` declares and handles them (`extensions/pi-btw/index.ts`) and copy that pattern.
- `replay`: rebuild the goal todo from history so reopened tabs show the current goal.
- Tests next to the adapter (see `pi-goal-x/index.test.ts`, `pi-btw` tests) plus the registry
  ordering. Run the server package's tests/typecheck/lint per the repo's `AGENTS.md`/docs.

Delivery: Paseo is consumed by the `/nixfiles` flake input `paseo` (see `forked-projects.md`).
Commit the adapter on branch `feat/pi-goal-adapter` in its worktree. Do **not** push, merge to the
fork's `main`, or bump the flake input without the user's go-ahead; report the commit SHA and the
exact follow-up steps instead.

## 11. Tests (unit, run in checkPhase)

- create → bind → idle dispatches exactly one continuation; stops on complete/blocked/paused.
- resume of same session restores and continues; restart while `paused` stays paused.
- fork (different session id, same binding entry) creates a copy with deferred continuation;
  first user turn clears deferral; original goal untouched.
- adopt from session B: A's next idle check dispatches nothing and notifies once; B continues;
  adopting a paused goal stays paused.
- pause from a user-triggered turn accepted; pause from a continuation turn rejected; pausing
  another session's goal by id stops that session at its next idle point.
- concurrent mutation from two processes under the lock never loses an update and never surfaces
  a "refresh and retry" error.
- active pi-subagents runs hold continuation; zero runs release it; probe unavailable fails open.
- message wait consumed only by matching source+prefix; user message clears it; expired deadline
  → blocked once.
- quota retry schedules at reset time; network backoff ladder.
- no-progress guard blocks after 3 empty continuation turns.
- delegated session: no tools registered, no context injected.
- no context injection at all when no goal is bound (regression for F1).

## 12. Acceptance criteria

- [ ] `pkgs/pi-goal` builds with tests passing in `checkPhase`; `nixos-rebuild build --flake
      .#kazuki` passes (when on host `kazuki`).
- [ ] Pi config loads `pi-goal`, not `pi-goal-x`; a manual smoke run (`pi` in a temp git repo,
      `/goal <objective>`, let it continue, `/goal-pause`, restart session, `/goal-resume`) works.
- [ ] Every F1–F7 scenario in §1 has a test or a smoke step demonstrating the fixed behavior.
- [ ] e2e-feature skill, `verify.py`, e2e-dispatch, dispatch-workspaces updated and their tests pass.
- [ ] Non-test source ≤ ~2k lines; Codex/pi-goal-x attribution present.
- [ ] Paseo `pi-goal` adapter (§10) committed on `feat/pi-goal-adapter` with passing tests,
      typecheck and lint; goal todo appears for create/update/adopt and after replay;
      `/goal-pause` works out of band during a running turn.
- [ ] Work committed on branch `feat/pi-goal`; not merged to `main` without the user's go-ahead.
