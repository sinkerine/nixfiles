# AGENTS.md

When the user asks for a VCS commit, generate the commit message yourself and proceed with the commit using that message.
When detecting version control in a workspace, use Git conventions by default.

## Development scratch data

Place large rebuildable outputs, downloaded dependencies, test SDKs, disposable emulator disks, and temporary test environments under `${XDG_CACHE_HOME:-$HOME/.cache}/dev-scratch/<project>/<workspace-or-run>/` when the tools support an external location. On kazuki, `~/.cache` is a separate ZFS dataset excluded from snapshots and replication; do not assume the same backup policy on other hosts. Use a stable project/workspace key for reusable caches and a unique run key for isolated test state. Prefer tool-specific output/cache settings; do not globally redirect unrelated tools to one shared build directory.

Keep source code, uncommitted work, credentials, agent recovery state, and useful reports or deliverables in their normal durable locations. A Git-ignored file is not necessarily disposable. Do not move an entire repository or Paseo worktree into scratch, or relocate existing configuration, active environments, or files needed to reproduce a failure merely to save snapshot space. Copy useful results out of scratch before cleanup. Use `/tmp` for short-lived files; neither `/tmp` nor scratch is a backup.

When adding a build/test recipe, record any required scratch paths in the repository instructions and make setup and teardown use the same location. Preserve existing isolation, locks, and resource admission. Before removing scratch, verify ownership and that no active process or container uses it; remove only data belonging to the completed run or an explicitly authorized cleanup.

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
