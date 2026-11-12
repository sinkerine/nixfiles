---
name: paseo-restart
description: Restart the installed Paseo daemon and its running desktop GUI without updating packages. Use for requests such as "restart paseo", "relaunch paseo", or "restart the Paseo daemon" in /nixfiles.
---

# Restart Paseo

Restart the existing installation. A restart request authorizes the restart; proceed without another confirmation. Do not update flake inputs, rebuild packages, or switch Home Manager unless separately requested.

Default to the current host. Restart the daemon and relaunch the desktop GUI if it was running. Respect explicit daemon-only or GUI-only requests. On a headless host, restart only the daemon. If the user names a remote host, run inspection, restart, and verification there over SSH; do not restart the local daemon instead. A restart alone does not require deployment.

## Inspect before restarting

Run:

```bash
hostname
systemctl --user show paseo.service -p ActiveState -p MainPID -p ExecStart -p ActiveEnterTimestamp
systemctl --user list-units --all 'paseo-restart-*'
ps -eo pid,args | rg '[e]lectron --no-sandbox --class=paseo-desktop' || true
readlink -f /home/sinkerine/.nix-profile/bin/paseo
readlink -f /home/sinkerine/.nix-profile/bin/paseo-desktop
```

Record the host, daemon PID, GUI main PID and package path, whether the GUI was running, and the requested scope. Inspect any existing restart unit and its journal before issuing another restart, especially after a session interruption. Preserve an active relaunch; do not create duplicate desktop instances.

These commands target this repository's Linux user service and desktop launcher. If the installation differs, inspect its actual service and launcher before adapting the procedure. Do not guess remote GUI display/session variables or launch a desktop on a headless host.

## Launch a durable restart

Restarting the daemon can terminate this agent's tool execution. Submit the complete restart through an independent user systemd unit. Choose a unique suffix, for example UTC timestamp plus shell PID, and record the resulting unit name in a progress update before submitting it. Keep the same name for verification after recovery.

For a daemon restart with a previously running GUI, substitute the actual suffix in this command:

```bash
systemd-run --user --collect --unit=paseo-restart-<suffix> \
  --property=Type=exec \
  /run/current-system/sw/bin/bash -eu -c '
    systemctl --user restart paseo.service
    pkill -f "^/nix/store/[^ ]+/libexec/electron/electron --no-sandbox --class=paseo-desktop " || {
      result=$?
      test "$result" -eq 1 || exit "$result"
    }
    exec /home/sinkerine/.nix-profile/bin/paseo-desktop
  '
```

The anchored pattern selects the Electron main process and avoids matching the shell executing the command. Never use broad `pkill -f paseo`. The active-profile desktop launcher starts the daemon if necessary and waits for daemon readiness before launching Electron. Desktop launch requires the user's graphical environment to be available to the user systemd manager; inspect that environment if launch fails.

For a daemon-only restart, including when the GUI was absent, use:

```bash
systemd-run --user --collect --unit=paseo-restart-<suffix> \
  --property=Type=exec \
  /run/current-system/sw/bin/systemctl --user restart paseo.service
```

For GUI-only scope, omit `systemctl --user restart paseo.service` from the combined command. The desktop launcher may start a stopped daemon as a prerequisite. If the user explicitly requests launching the GUI when none was running, use the combined command on a graphical host.

A successful `systemd-run` response confirms submission only. Do not claim completion until verification succeeds. After interruption, resume verification of the recorded attempt before deciding whether another restart is needed. Session recovery can take longer than daemon readiness; do not promise that every interrupted agent or background workflow will resume automatically.

## Verify completion

Inspect the recorded unit and daemon:

```bash
systemctl --user show paseo.service -p ActiveState -p MainPID -p ExecStart -p ActiveEnterTimestamp
journalctl --user -u paseo-restart-<suffix>.service -n 60 --no-pager
journalctl --user -u paseo.service -n 60 --no-pager
/home/sinkerine/.nix-profile/bin/paseo daemon status --json
ps -eo pid,args | rg '[e]lectron --no-sandbox --class=paseo-desktop' || true
```

Require the daemon to be active and the status JSON to report `localDaemon: "running"`. Allow a bounded startup interval (up to 120 seconds), using short checks and command timeouts; keep the user informed and avoid a single blocking wait longer than 60 seconds. If `PASEO_HOST` or another CLI connection override is set, ensure the status check targets the restarted host rather than a different daemon.

For daemon restarts, compare the new PID and activation timestamp with the recorded values. For GUI relaunches, require a new Electron main PID using the installed desktop package. The GUI's Electron executable itself has an Electron store path; the Paseo package revision appears in its application argument. Confirm the expected scope succeeded. A collected unit disappearing does not prove success, and a running GUI process alone does not prove daemon readiness.

If startup fails, preserve the unit name and relevant journal error, diagnose the specific failure, and report any remaining blocker. Do not repeat restarts blindly. Report the host and verified daemon/GUI result concisely.
