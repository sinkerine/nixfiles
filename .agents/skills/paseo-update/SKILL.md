---
name: paseo-update
description: Update Paseo in /nixfiles to the latest commit of sinkerine/paseo, activate the local Home Manager configuration, restart the daemon and GUI, and verify running package revisions. Use for requests such as "update paseo", "update paeso", or "update again" in a Paseo update conversation.
---

# Update Paseo from the fork

Run from `/nixfiles`. The `paseo` flake input tracks `github:sinkerine/paseo`; keep that source unless the user asks to change it. Updating this input does not sync original upstream into the fork.

Paseo is installed through a standalone Home Manager configuration. A NixOS switch alone does not update it. Read `../nix-switch/SKILL.md` for local activation conventions. Use `../nix-deploy-rs/SKILL.md` when the user explicitly targets a remote host.

## Inspect and update

1. Check `hostname` and `git status --short`. Preserve all existing changes, including unrelated edits already in `flake.lock`.
2. Inspect the current service and GUI before restarting. On a resumed session, check existing update/relaunch units and logs before repeating any action.
3. Refresh only Paseo:

```bash
nix flake update paseo
jq -r '.nodes.paseo.locked.rev' flake.lock
nix eval --json .#packages.x86_64-linux --apply 'p: { daemon = p.paseo.version; desktop = p.paseo-desktop.version; }'
```

`overlays/default.nix` appends the input's short commit to both package versions, for example `0.13.2-5251395`. Internal CLI, daemon, and GUI version strings can remain `0.13.2`; use store paths to verify the installed revision. Nix already hashes source inputs for cache identity.

If the fork has not advanced and the running packages already match, report that it is current. Do not rebuild or restart needlessly.

On `kazuki`, run `nixos-rebuild build --flake .#kazuki` after Nix changes, as required by repository instructions. This check does not build the standalone Home Manager packages. Do not run that verification on another machine.

## Activate Home Manager durably

An update request in this workflow includes local activation and restarting Paseo, unless the user limits the scope. Restarting the daemon can interrupt its agents, including the current session. Launch activation and relaunch commands through independent user systemd units so they survive that interruption.

Use a unique unit/log suffix for each attempt, such as the short revision plus an attempt number. Example on `kazuki`:

```bash
systemd-run --user --collect --unit=paseo-home-update-<suffix> \
  --property=Type=exec --working-directory=/nixfiles \
  /run/current-system/sw/bin/bash -c \
  'exec /home/sinkerine/local/bin/switch-nix-home.sh > /tmp/paseo-home-update-<suffix>.log 2>&1'
```

Replace `<suffix>` before execution. The wrapper uses `path:/nixfiles#sinkerine@kazuki` and handles daemon-independent activation. For another local host, inspect its wrapper and configuration first.

Check the unit and read the durable log in short intervals. Keep progress updates flowing; avoid individual blocking waits over 60 seconds. A collected unit becoming inactive or disappearing does not prove success: inspect the log and active profile. If the tool times out, check whether the unit is still running before retrying. Do not start concurrent activations.

Require completed activation and the expected new profile path:

```bash
readlink -f /home/sinkerine/.nix-profile/bin/paseo
systemctl --user show paseo.service -p ExecStart
```

Home Manager can say `Keeping old units: paseo.service` while installing a new service definition. Restart explicitly after successful activation. Do not report success from a build alone.

## Restart daemon and GUI

Launch the whole relaunch in one independent unit, since restarting the daemon can end the current agent's command execution:

```bash
systemd-run --user --collect --unit=paseo-relaunch-<suffix> \
  /run/current-system/sw/bin/bash -c '
    systemctl --user restart paseo.service &&
    { pkill -f "^/nix/store/[^ ]+/libexec/electron/electron --no-sandbox --class=paseo-desktop " || true; } &&
    exec /home/sinkerine/.nix-profile/bin/paseo-desktop
  '
```

The anchored process pattern matches the Paseo Electron main process without matching the shell that contains the command. Avoid broad `pkill -f paseo` or patterns that match the executing shell. The active-profile desktop launcher waits for daemon readiness.

After interruption, resume with verification; do not repeat an already successful activation or restart.

## Verify completion

```bash
systemctl --user show paseo.service -p ActiveState -p ExecStart
systemctl --user show paseo-relaunch-<suffix>.service -p ActiveState -p MainPID
ps -eo pid,args | rg '[e]lectron --no-sandbox --class=paseo-desktop'
paseo daemon status --json
```

Confirm the daemon and GUI process paths both contain the expected `<version>-<commit>`, the daemon is running and reachable, and expected providers are available. Compare with the lock revision. Report the commit, package version, and activation/restart result. Do not routinely mention successful Nix build verification.

## Outdated npm dependency hash

If a package fails with `npmDepsHash is out of date`, inspect the fork's `nix/npm-deps.hash` against its `package-lock.json`. Fix the hash in the Paseo project, usually `/home/sinkerine/dev/paseo`, rather than adding a lasting workaround to nixfiles.

1. Inspect that checkout's status, HEAD, remotes, and applicable `AGENTS.md`. Ensure its lockfile matches the failing input before changing the hash.
2. Calculate the expected hash from the exact failing input:

```bash
nix build --impure --no-link --expr '
  let f = builtins.getFlake "/nixfiles";
  in (f.inputs.paseo.packages.x86_64-linux.paseo.override {
    npmDepsHash = f.inputs.nixpkgs.lib.fakeHash;
  }).npmDeps
'
```

3. Use the resulting `got: sha256-...` value in the matching checkout's `nix/npm-deps.hash`. Validate with `nix build --no-link .#paseo.npmDeps` from that checkout and follow its required checks.
4. Commit and push only when authorized. If requested, generate a commit message, stage only the intended files, and push to the verified fork branch. The fix must be available remotely before refreshing nixfiles' GitHub input to include it.
5. Refresh the input and retry activation. Preserve error evidence and report any remaining blocker. Do not mask a stale dependency hash with unrelated version changes or repeated restarts.
