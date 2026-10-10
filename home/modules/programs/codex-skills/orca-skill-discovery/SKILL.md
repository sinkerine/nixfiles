---
name: orca-skill-discovery
description: Inspect the version-matched Orca CLI skill guides before using Orca commands. Use when Codex needs to check, refresh, or learn an Orca-related skill, or when an Orca CLI command is unknown.
---

# Orca Skill Discovery

Resolve the Orca executable once for the session:

1. Use `ORCA_CLI_COMMAND` when set.
2. Otherwise use `orca-dev` when `ORCA_DEV_REPO_ROOT` is set.
3. Otherwise use `orca-ide-cli` when discoverable on `PATH` (`command -v orca-ide-cli`
   on POSIX shells). Nix packages expose this executable wrapper for `cli/index.js`.
4. Otherwise, on Linux outside an Orca-managed terminal, use `orca-ide`.
5. Otherwise use `orca`.

On Nix, `orca-ide` launches the GUI; use `orca-ide-cli` for CLI commands. Do not
derive the CLI entrypoint from Electron's executable path or invoke the JS file directly.

Never run bare `orca` on Linux outside Orca-managed terminals; it may start the GNOME
Orca screen reader. Do not switch executables after an error.

Before using an Orca-related skill, ask the selected executable for its current guide:

```text
<selected-orca-executable> skills get <skill-name>
```

Read the complete output and treat it as authoritative for that executable and version.
Use one of these skill names when applicable:

- `computer-use`
- `orca-cli`
- `orca-emulator`
- `orca-emulator-android`
- `orca-linear`
- `orca-per-workspace-env`
- `orchestration`

Do not guess subcommands or flags from a cached skill file. If `skills get` is explicitly
reported as unknown, run only the skill's documented read-only bootstrap commands. For any
other failure, report the exact error and stop.
