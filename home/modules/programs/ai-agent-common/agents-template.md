# AGENTS.md

When the user asks for a VCS commit, generate the commit message yourself and proceed with the commit using that message.
When detecting version control in a workspace, use Git conventions by default.

When work is complete in a separate Git worktree and the task's changes are still unmerged, proactively ask the user whether to merge them into the repository's local default branch. Wait for their answer before merging. If the user has already authorized the merge or chosen another delivery path, follow that instruction.

## Development scratch data

Place large rebuildable outputs, downloaded dependencies, test SDKs, disposable emulator disks, and temporary test environments under `${XDG_CACHE_HOME:-$HOME/.cache}/dev-scratch/<project>/<workspace-or-run>/` when the tools support an external location. On kazuki, `~/.cache` is a separate ZFS dataset excluded from snapshots and replication; do not assume the same backup policy on other hosts. Use a stable project/workspace key for reusable caches and a unique run key for isolated test state. Prefer tool-specific output/cache settings; do not globally redirect unrelated tools to one shared build directory. Do not put large files such as model binaries into the Nix store; download them directly into the appropriate cache or data directory instead.

Keep source code, uncommitted work, credentials, agent recovery state, and useful reports or deliverables in their normal durable locations. A Git-ignored file is not necessarily disposable. Do not move an entire repository or Paseo worktree into scratch, or relocate existing configuration, active environments, or files needed to reproduce a failure merely to save snapshot space. Copy useful results out of scratch before cleanup. Use `/tmp` for short-lived files; neither `/tmp` nor scratch is a backup.

When adding a build/test recipe, record any required scratch paths in the repository instructions and make setup and teardown use the same location. Preserve existing isolation, locks, and resource admission. Before removing scratch, verify ownership and that no active process or container uses it; remove only data belonging to the completed run or an explicitly authorized cleanup.

## Delivery focus in testing and verification

The goal is a working feature, not a maximal proof of correctness. Size testing and verification to the change and its real risk.

- Test the behavior the user asked for: the main paths, the edge cases that realistically occur, and the contracts other code depends on. Skip tests for impossible states, hypothetical misuse, or framework and library behavior.
- Do not add defensive code — redundant validation, broad try/catch, fallbacks, retries, feature flags, or compatibility shims — unless a concrete failure mode or the user requires it. Trust internal callers and typed interfaces; validate at real system boundaries.
- Run the checks that cover what changed (targeted tests, typecheck, lint, build of affected targets). Run the full suite or expensive E2E only when the change is broad, the repository requires it, or targeted checks cannot cover the risk.
- When checks pass and the feature works, stop verifying and deliver. Do not rerun green checks, add speculative tests, or repeat reviews without new evidence.
- Fix failures in the code that caused them. Do not weaken, skip, or delete tests to get green, and do not chase pre-existing unrelated failures; note them and move on.
- Report what was verified and any known gaps briefly and plainly.
- Explicit user instructions, repository `AGENTS.md`/`CLAUDE.md` rules, and loaded skill workflows that require specific checks take precedence over this section.

## Autonomy in feature development

When developing new features, keep working on your best rationale instead of pausing for confirmation. Ask for human attention only when:

- you cannot make the decision yourself, because requirements, scope, or expected behavior are genuinely ambiguous and no reasonable default exists;
- the next action is really risky: destructive or irreversible, security-sensitive, or it has side effects outside the workspace that were not authorized; or
- the current step or workflow explicitly requires human intervention or approval.

Otherwise, pick the most reasonable option, note the choice and why in your progress or final report, and continue. Do not stop to ask permission to proceed, to keep fixing failures, or to approve routine implementation, testing, or verification choices.

## Skills

### obsidian-cli

Use the `obsidian` CLI to interact with a running Obsidian instance. Requires Obsidian to be open.

Run `obsidian help` to see all available commands. Full docs: https://help.obsidian.md/cli

Common operations:

```bash
obsidian read file="My Note"
obsidian create name="New Note" content="# Hello" silent
obsidian append file="My Note" content="New line"
obsidian search query="search term" limit=10
obsidian daily:read
obsidian daily:append content="- [ ] New task"
obsidian property:set name="status" value="done" file="My Note"
```

- `file=<name>` — wikilink-style resolution; `path=<path>` — exact path from vault root
- `vault=<name>` as first param to target a specific vault
- `--copy` copies output to clipboard; `silent` prevents files from opening
