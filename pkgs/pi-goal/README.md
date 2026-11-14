# pi-goal

One goal per Pi session, stored in `$XDG_STATE_HOME/pi-goal/goals` (default `~/.local/state/pi-goal/goals`). No project goal pool or task tree.

Use `/goal <objective>`, `/goal` for status, `/goal-list`, `/goal-pause [id]`, `/goal-resume [id]`, `/goal-clear [id]`, `/goal-adopt <id>`. Agent tools mirror these commands; creation/adoption require explicit authorization. Pause, resume and clear require user-triggered turns. Delegated sessions expose no goal capabilities.

Active goals restore on session startup and continue when idle. Forks copy a branch snapshot with continuation deferred until the first user turn. Adoption transfers ownership; the previous owner stops at its next idle check. User-paused goals remain paused. Escape during a continuation pauses it. Legacy `.pi/goals` is ignored and left intact.

Waits require a reason and finite future deadline; a matching native Paseo source/prefix or a direct user message consumes them. Expired waits block. Subagent runs hold continuation; provider failures use backoff and `PI_GOAL_QUOTA_URL` quota reset times. Completion requires the full completion audit in the Codex-derived continuation prompt.

Run tests: `node --experimental-strip-types --test tests/*.test.ts` (with host peer dependencies linked as in default.nix). Attribution and licenses: see NOTICE.
