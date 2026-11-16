# GPU-backed LXC GUI test sandbox

Status: implemented in the NixOS kazuki configuration. The host module, root-owned lifecycle CLI, Ubuntu template provisioner, mocked safety tests, and build checks are complete. Real Proxmox template/clone and guest GUI checks remain blocked by missing root authorization on the current session; exact evidence is recorded below.

## Architecture

~~~text
agent + Git worktree on kazuki
  |
  +-- sudo -n gui-sandbox (or run0 under NoNewPrivs) -- pct -- linked, unprivileged task LXC
  |                                      |
  |                                      +-- /workspace worktree bind mount
  |                                      +-- read-only NVIDIA libraries
  |                                      +-- NVIDIA control/render devices
  |                                      +-- SSH -- headless Sway -- XWayland/AT-SPI -- CUA Driver
  |
  +-- root-owned state, leases, locks, SSH host keys, and artifact collection
  +-- ZFS rpool/proxmox/agent-sandbox via Proxmox storage agent-sandbox
~~~

The host never shares its Wayland socket, D-Bus socket, home directory, SSH agent, or sibling worktrees. The guest receives one explicitly selected worktree, a DHCP network interface, and the GPU resources needed by its own headless desktop.

## Implementation

Files:

- hosts/modules/services/gui-test-sandbox/default.nix — NixOS module, options, sudo rule, tmpfiles, storage bootstrap, and lease timer.
- hosts/modules/services/gui-test-sandbox/gui-sandbox.sh — root-owned lifecycle CLI and ownership checks.
- hosts/modules/services/gui-test-sandbox/guest-provision.sh — Ubuntu provisioning, Sway/XWayland, CUA Driver, SSH, and health checks.
- tests/gui-test-sandbox-test.sh and tests/fake-pct.sh — mocked Proxmox safety/interface tests.
- hosts/kazuki/default.nix — kazuki enablement.

The host provides declarative compatibility links for `/usr/bin/perl` and
`/sbin/ip` because LXC executes Proxmox hooks that use those FHS paths. The
hook files themselves remain unmodified. Proxmox derivations also remain
stock: the sandbox uses a small `pct` launcher with explicit Perl include
paths, while `pve-container@` redirects generated standard LXC includes to
the host LXC config tree. This keeps compatibility logic in the host module.

The module is imported by hosts/modules/services/default.nix and enabled with:

~~~nix
my.services.guiTestSandbox.enable = true;
~~~

The passwordless command is the exact system path /run/current-system/sw/bin/gui-sandbox and, on kazuki, the pinned nixos-rebuild switch command. pct, pvesm, and zfs are runtime dependencies of the root-owned wrapper, not user-authorized sudo commands. The wrapper uses the NOPASSWD sudo rule in ordinary sessions; when the caller has `NoNewPrivs: 1`, sudo cannot elevate and the wrapper invokes systemd `run0`, which uses the host's polkit policy instead.

## Host options and defaults

All options live under my.services.guiTestSandbox:

| Option | Default | Purpose |
| --- | --- | --- |
| stateDirectory | /var/lib/gui-test-sandbox | Root-owned metadata, lock, SSH, and artifacts. |
| storageDataset | rpool/proxmox/agent-sandbox | ZFS filesystem for task root filesystems. |
| storageMountpoint | /var/lib/gui-test-sandbox/storage | Private host mountpoint inherited by Proxmox ZFS subvolumes. |
| rootfsMount | /run/gui-test-sandbox/rootfs | Writable per-VMID LXC rootfs mount target. |
| storageId | agent-sandbox | Proxmox zfspool storage ID. |
| templateCache | /var/lib/vz/template/cache | Root-owned template archive directory. |
| templateVmid | 9000 | Reserved managed template VMID. |
| firstVmid / lastVmid | 9100 / 9199 | Managed task VMID range; each active task receives one unique VMID. |
| bridge | vmbr0 | DHCP bridge. |
| cores | 8 | Template/task vCPU count. |
| memoryMiB | 16384 | Template/task memory in MiB. |
| rootfsGiB | 64 | Sparse template root filesystem; clones inherit it. |
| leaseHours | 12 | Task lease duration. |
| guestUid / guestGid | 1000 / 1000 | Guest agent identity; the module asserts these values. |
| subordinateIdStart / subordinateIdCount | 100000 / 65536 | Root subordinate UID/GID range. |
| nvidiaRenderNode | /dev/dri/renderD128 | NVIDIA render node; card nodes are rejected. |
| nvidiaGpuName | NVIDIA GeForce RTX 5070 Ti | Renderer string required by guest health. |
| nvidiaDriverVersion | host NVIDIA package version | Version required by guest health. |
| templateImage | ubuntu-24.04-standard_24.04-2_amd64.tar.zst | Ubuntu Proxmox template filename. |
| templateImageUrl | Proxmox Ubuntu image URL | Download source, SHA-512 verified before use. |
| templateImageSha512 | 45c2978e6b97fe292ada95fe06834276015e5739a594db4de2fdfd830fa0c37942e8ae118fc1e32ffd9154b3f9378b592738b668ea3957db41f2907b86f219de | Template content pin. |
| cuaDriverVersion | 0.21.0 | CUA Driver release. |
| cuaDriverArchiveUrl | CUA Driver GitHub release URL | CUA archive source. |
| cuaDriverArchiveSha256 | b269df39141bf873a583913cf59c18b867f8ac880ba43d781ca276b2632a6f55 | CUA archive content pin. |

The module adds root subordinate ranges, creates state directories with root/task-user ownership, installs the CLI, and enables storage bootstrap plus a persistent 15-minute reaper timer.

## Storage and template lifecycle

After the built configuration is activated, storage bootstrap is idempotent:

~~~sh
sudo systemctl start gui-test-sandbox-storage.service
zfs list rpool/proxmox/agent-sandbox
~~~

It creates the ZFS filesystem with a private host mountpoint, verifies that it is a filesystem, and reads `/etc/pve/storage.cfg` to either verify an existing `agent-sandbox` zfspool points at the exact dataset or adds it with rootdir content, sparse volumes, and the configured Proxmox mountpoint. An existing storage entry with a stale or missing `mountpoint` option is repaired with `pvesm set`; a wrong storage type or pool fails closed. A legacy `mountpoint=none` dataset is migrated to the configured mountpoint; any other ZFS mismatch fails closed. This avoids the unsupported `pvesm config` command on Proxmox 9.1 and lets child subvolumes inherit a mountable path.

Each managed container also receives `lxc.rootfs.mount` pointing at a writable per-VMID directory below `rootfsMount`. Nix's LXC package otherwise defaults this temporary mount target to a read-only Nix store path, which prevents `/dev` setup.

Build the pinned template explicitly:

~~~sh
gui-sandbox template build
~~~

The command:

1. Creates or verifies the root-owned template cache.
2. Downloads the pinned Ubuntu archive when absent and checks SHA-512 every time.
3. Creates VMID 9000 on agent-sandbox as an unprivileged container.
4. Applies the six-line UID/GID map, pushes the pinned CUA archive and provisioner, and starts the guest.
5. Installs GUI, accessibility, SSH, diagnostic, font, FFmpeg, and CUA dependencies.
6. Configures agent UID/GID 1000, linger, headless Sway, XWayland, user D-Bus, portals, SSH restrictions, and CUA.
7. Stops and marks VMID 9000 as a managed template with a provisioning-schema tag.

Provisioning schema includes the guest provisioner, CUA version, NVIDIA version/name, template filename, and template checksum. A stale schema is refused. To intentionally rebuild a managed stale template after reviewing its configuration:

~~~sh
pct config 9000
gui-sandbox template build --replace
~~~

Replace refuses an unowned or non-template VMID. Template creation does not mount host NVIDIA resources; each task clone receives those mounts after cloning.

## UID/GID mapping

For the defaults, every task config receives:

~~~text
lxc.idmap: u 0 100000 1000
lxc.idmap: u 1000 1000 1
lxc.idmap: u 1001 101001 64535
lxc.idmap: g 0 100000 1000
lxc.idmap: g 1000 1000 1
lxc.idmap: g 1001 101001 64535
~~~

Guest UID/GID 1000 remains host UID/GID 1000, so /workspace preserves task-user ownership in both directions. Guest root and all other guest IDs are shifted through root's subordinate range.

The UID-map replacement temp file is created inside /etc/pve/lxc. This is required because Proxmox pmxcfs can be a different filesystem from /var/lib; a state-directory temp cannot be atomically moved into pmxcfs.

## Task creation and GPU boundary

Create each task from a canonical Git worktree:

~~~sh
gui-sandbox create --task demo --repo /home/sinkerine/dev/worktrees/my-worktree --json
~~~

The CLI accepts only slugs matching [a-z0-9][a-z0-9-]{0,47}. The repository may be any absolute path, but must resolve to a real directory owned by UID/GID 1000 and be the exact Git worktree root. Missing paths, non-worktrees, and wrong ownership are rejected. Multiple active or creating tasks are allowed up to the configured VMID range; each task has its own VMID, SSH material, rootfs mount target, metadata, and `/workspace` mount.

Creation takes the lifecycle lock for allocation and provisioning, verifies the managed template/storage/worktree/GPU, allocates a free VMID, generates task-specific SSH material, creates pending metadata, makes a linked clone, applies the map, mounts the worktree and GPU, starts the guest, rotates host keys, discovers DHCP, verifies `/workspace`, runs guest health as agent, and only then marks state active and health healthy. Reusing an existing task slug is rejected; different slugs can be created independently.

The task receives exactly these NVIDIA device nodes:

~~~text
/dev/nvidia0
/dev/nvidiactl
/dev/nvidia-modeset
/dev/nvidia-uvm
/dev/nvidia-uvm-tools
/dev/dri/renderD128
~~~

The host NVIDIA library, binary, and EGL external-platform outputs are separate read-only mounts at /opt/gui-sandbox/host-nvidia, /opt/gui-sandbox/host-nvidia-bin, and /opt/gui-sandbox/host-nvidia-egl. Physical DRM card nodes are never passed. Host preflight requires the render node to be a character device backed by the NVIDIA driver, all required NVIDIA control devices to exist, and all three outputs to be available.

Inside the guest, WLR_BACKENDS=headless, a 1920x1080 HEADLESS-1 output, GLES2, WLR_RENDERER_ALLOW_SOFTWARE=0, and NVIDIA GLVND paths are enforced. Provisioning writes guest-local NVIDIA EGL vendor and external-platform files because Nix host JSON embeds unavailable `/nix/store` paths; the NVIDIA GBM backend is exposed through the guest GBM search path. Health fails on an absent renderer, llvmpipe/softpipe/software rasterization/SwiftShader, a GPU-name mismatch, or a driver-version mismatch. It also requires CUA doctor display and AT-SPI probes, health_report overall=ok, accessibility-tree JSON, and a non-empty desktop capture before create can report health=healthy.

## Guest GUI and CUA interface

The provisioner enables:

- gui-sandbox-sway.service — headless Sway with XWayland enabled.
- gui-sandbox-atspi.service — the guest AT-SPI accessibility bus for the non-desktop session, launched as a simple user-manager service; the system service bridges into the agent user manager and waits for `org.a11y.Bus`.
- gui-sandbox-cua.service — CUA Driver 0.21.0 on /run/user/1000/cua-driver.sock in standard permission mode.
- gui-sandbox-health.service — on-demand health oneshot; disabled after provisioning and run synchronously by create.
- OpenSSH restricted to key-authenticated agent; root/password/X11 forwarding/TCP forwarding/agent forwarding/tunnels are disabled.

The CUA archive is extracted into /opt/cua-driver and its executable is installed at /usr/local/bin/cua-driver. The normal daemon and clients set CUA_DRIVER_RS_ENABLE_WAYLAND=1 so the native Wayland backend is enabled rather than left experimental. The CUA cursor overlay is disabled because its X11 window can destabilize NVIDIA headless Sway/XWayland. The tested 0.21.0 surface uses get_desktop_state for screenshots, get_accessibility_tree/get_window_state for discovery, and click/type_text/press_key for input.

The guest creates the agent dconf directory before starting the session services. The health check starts a short-lived GTK accessibility anchor so the headless session exposes an AT-SPI application window, then removes it before activation. It records cua-doctor.json, health-report.json, accessibility-tree.json, desktop-state.json, renderer.txt, and wayland-info.txt under /var/log/gui-sandbox. CUA 0.21.0's native screencopy assumes four-byte wl_shm pixels, while this NVIDIA headless Sway session can advertise three-byte Bgr888 frames, so health keeps semantic probes on the native-Wayland daemon and uses a short-lived XWayland-only CUA daemon for the desktop PNG. If CUA's X11 GetImage path rejects the XWayland root drawable, the pinned grim fallback captures a PNG through native Wayland screencopy. It captures health-screenshot.png; any failed probe or capture aborts task creation.

Examples:

~~~sh
gui-sandbox cua demo get_accessibility_tree '{}'
gui-sandbox cua demo get_desktop_state '{}'
gui-sandbox cua demo get_window_state '{"pid":1234}'
gui-sandbox mcp demo
~~~

For get_desktop_state and zoom, the CLI uses CUA's --screenshot-out-file option, copies the guest image into a task-user-owned artifact directory, and adds host_artifact to the JSON result. CUA Driver 0.21.0 has no screenshot tool; use get_desktop_state.

Native Wayland applications use the Sway/Wayland environment. GTK/X11 applications use XWayland through GDK_BACKEND=wayland,x11 and QT_QPA_PLATFORM=wayland;xcb. Semantic inspection remains preferred; explicit foreground delivery is available through CUA input tools when an application rejects background input.

### Live launch findings

The first live Electron application launch on 2026-08-26 exposed CUA 0.21.0 limitations that
are separate from application failures:

- A native Wayland Electron window was visible in Sway while the initial
  `get_accessibility_tree` response reported `windows: []`. `list_windows`
  later found the window, and `get_window_state` required both its `pid` and
  `window_id`. For Wayland Electron discovery, resolve window identity first
  and request `get_window_state` with `include_screenshot: false` when only the
  accessibility tree is needed.
- Runtime `get_desktop_state` against the long-lived native-Wayland CUA daemon
  reproduced `range end index 6220804 out of range for slice of length 6220800`.
  This is CUA's four-byte pixel assumption against the NVIDIA headless
  session's three-byte Bgr888 frame, not an application renderer or window-close
  failure. The provisioning health check's XWayland/grim capture fallback does
  not currently wrap ad-hoc runtime `gui-sandbox cua` screenshot calls.
- CUA background `hotkey` delivery returned `background_unavailable` for the
  Wayland Electron surface; foreground synthetic delivery was unverifiable.
  The compositor close request removed the window and all application processes, and
  the close log contained no destroyed-`webContents` exception.
- `gui-sandbox exec` deliberately supplies the guest's system-only PATH. The
  dev launcher therefore needed an explicit runtime Node path; this does not
  indicate a missing sandbox dependency.

Treat the screenshot panic and an empty initial X11 window list as CUA
grounding limitations. Check window/process state and the application log
before classifying them as an application crash or failed close.

## CLI contract

~~~text
gui-sandbox template build [--replace]
gui-sandbox create --task SLUG --repo WORKTREE [--json]
gui-sandbox status [SLUG] [--json]
gui-sandbox exec SLUG -- ARGV...
gui-sandbox launch SLUG -- ARGV...
gui-sandbox cua SLUG TOOL JSON
gui-sandbox mcp SLUG
gui-sandbox collect SLUG [--dest DIRECTORY]
gui-sandbox destroy SLUG [--dest DIRECTORY]
gui-sandbox reap
~~~

create --json returns task, state, health, vmid, ip, workspace, lease_expires, SSH paths, provisioning_schema, and gpu, plus workspace_path, ssh_command, and cua_command. status --json adds expired. exec runs an argument-vector-safe command from /workspace. launch backgrounds a command and logs it under /run/user/1000/gui-sandbox-<task>.log. cua validates JSON before forwarding. mcp exposes CUA's stdio MCP transport over SSH.

## Artifacts, destruction, and leases

collect creates an output directory below /var/lib/gui-test-sandbox/artifacts by default, or below any existing task-user-owned directory with --dest. It writes:

~~~text
task.json
pct-config.txt
guest-health.txt
guest-journal.txt
workspace.txt
~~~

CUA screenshots are stored beside these files when collected through the CUA interface. Output files/directories are task-user-owned; root metadata, locks, and task SSH material remain protected.

destroy first collects artifacts, verifies VMID range, managed/task tags, exact /workspace mount, and metadata, then stops and purges the container. It removes only that task's metadata and SSH directory. It never removes the worktree, artifacts, sibling task, template, or unowned VMID. Failed ownership/mount proof fails closed.

For a task left in `creating` by an interrupted create, `destroy` runs the same ownership-checked partial cleanup and returns without artifact collection; it removes metadata only when the managed container/configuration proof succeeds or no container was created.

The reaper runs every 15 minutes after boot. It evaluates every active or creating task independently: expired active tasks are collected and destroyed, while expired creating tasks are removed only when a managed task tag and exact worktree mount prove ownership. Unmanaged or retagged tasks are logged and skipped. The lifecycle lock serializes template, create, collect, destroy, and reap; guest exec/launch/CUA operations remain task-specific and do not serialize unrelated instances.

## Normal workflow

~~~sh
gui-sandbox status --json
gui-sandbox create --task demo --repo /home/sinkerine/dev/worktrees/my-worktree --json
gui-sandbox exec demo -- bash -lc 'make test'
gui-sandbox launch demo -- ./run-native-wayland-test
gui-sandbox cua demo get_accessibility_tree '{}'
gui-sandbox cua demo get_desktop_state '{}'
gui-sandbox launch demo -- ./run-xwayland-test
gui-sandbox cua demo get_window_state '{"pid":1234}'
gui-sandbox collect demo
gui-sandbox destroy demo
~~~

Use destroy for intentional cleanup so final health and journal artifacts are retained. The timer is a recovery path for expired leases, not a substitute for normal cleanup.

## Trust boundaries and limitations

- The lifecycle CLI is root-owned; the guest is an unprivileged LXC, not a VM. Guest root is shifted and cannot become host root through the configured map.
- The worktree is intentionally read-write. Code running in the guest can modify that selected worktree. Avoid mounting the same worktree into multiple active tasks when their guests may write concurrently.
- NVIDIA device nodes are shared with the host and are exposed mode 0666 inside the dedicated task container. This is required for the mapped UID/GID and is a GPU-driver trust boundary; the physical display card is never exposed.
- vmbr0 provides ordinary DHCP network access. The design does not add a separate network namespace/firewall policy beyond Proxmox/LXC and the guest SSH restrictions; treat guest code as network-capable.
- SSH access is task-specific and strict-host-key checked. No host SSH agent, host D-Bus, host Wayland, or host home is mounted.
- CUA Driver standard permission mode is used. The release may send content-free product telemetry by default; network policy can be tightened separately if that is not acceptable.
- Concurrent task count is bounded by the configured inclusive VMID range. A pool expansion must preserve unique VMID allocation, per-VMID rootfs mounts, VMID/tag ownership, and reaper proofs.

## Upgrade procedure

1. Change the template, CUA, GPU, or host-driver pin in default.nix.
2. Run the affected host build and review generated CLI paths, storage unit, sudo rule, and schema.
3. Activate the NixOS configuration with root authorization.
4. Review pct config 9000; run gui-sandbox template build --replace only when the expected managed/template tags are present.
5. Create a disposable task and verify health healthy, renderer output, CUA doctor, a native Wayland app, and an XWayland app before normal use.

Never replace a VMID outside the managed template tag boundary. Failed provisioning that cannot prove task ownership deliberately leaves metadata/configuration for manual review.

## Verification evidence

Baseline checks below ran in this worktree on kazuki on 2026-08-23. The multi-instance change was reverified on 2026-08-26.

| Check | Result |
| --- | --- |
| bash -n on implementation scripts/tests | Passed. |
| ShellCheck via nix shell nixpkgs#shellcheck --command shellcheck | Passed with no diagnostics. |
| bash tests/gui-test-sandbox-test.sh | Passed path containment, symlink escape, exact UID/GID map, tags, lock, stale template, storage command shape, SSH quoting including an `env` task slug, screenshot artifact ownership, safe reaping, unmanaged skip, creating-task cleanup, two active task creation with unique VMIDs plus duplicate-slug rejection, and the `NoNewPrivs` `run0` fallback. |
| Multi-instance change checks (2026-08-26) | Passed `bash -n`, ShellCheck, `git diff --check`, and mocked create flow: task `first` stayed active on VMID 9100 while task `second` became healthy on VMID 9101. |
| nixos-rebuild build --flake .#kazuki | Passed. Final output: /nix/store/bb5f42il320nswl2r0f93cswsmp2rnpc-nixos-system-kazuki-26.11.20260819.ffb3c9b. |
| CUA archive SHA-256 | b269df39141bf873a583913cf59c18b867f8ac880ba43d781ca276b2632a6f55. |
| Ubuntu template SHA-512 | Verified with nix store prefetch-file; store path /nix/store/chgin4k0yc1vn2ar7v3an2ld3g30bdah-ubuntu-24.04-standard_24.04-2_amd64.tar.zst. |
| CUA archive execution | manifest, describe, doctor --json, native-Wayland opt-in, and get_desktop_state --screenshot-out-file syntax verified for 0.21.0. |
| Live Electron GUI close (2026-08-26) | Task `multi-window-close` reached `health: healthy` on VMID 9100 with the NVIDIA GeForce RTX 5070 Ti; the inspected Electron window was closed through Sway, its window/process disappeared, and no close-time exception was logged. CUA 0.21.0's runtime desktop capture reproduced the documented three-byte Bgr888 panic; health capture remained separate. |
| Native CUA protocol probe | With CUA_DRIVER_RS_ENABLE_WAYLAND=1, health_report reported wayland_backend pass; get_accessibility_tree returned an object and get_desktop_state wrote a 1,236,303-byte PNG. Host AT-SPI remained unavailable, so overall was degraded. |
| Host GPU | nvidia-smi reported NVIDIA GeForce RTX 5070 Ti, 595.91.07; GLX/EGL reported NVIDIA RTX 5070 Ti, not software rendering; renderD128 resolves to the NVIDIA driver. |
| Host identity | Hostname kazuki; sinkerine UID/GID 1000:1000; subordinate range 100000:65536 present for sinkerine. |
| Generated system inspection | Final wrapper PATH contains Proxmox and ZFS tools; generated sudoers contains only the exact gui-sandbox NOPASSWD rule; generated tmpfiles and storage/reaper units are present. |

The mock suite executes the real shell functions and CLI against fake pct, ZFS, Proxmox storage, and SSH commands without mutating host state.

## Current external blocker

The CLI handles agent sessions that carry `NoNewPrivs: 1`: sudo rejects those
sessions before evaluating NOPASSWD rules, so the wrapper delegates to
systemd `run0` instead. `run0` does not inherit the flag, but it still requires
the host polkit policy to authorize the root CLI. If no polkit agent or rule is
available in the agent session, run the command from the user's normal host
terminal and authorize it there. Do not add direct passwordless sudo entries
for `pct`, `pvesm`, `zfs`, or `systemctl`; the root wrapper already constrains
those operations.

No real Proxmox mutation or guest e2e was performed. Root authorization is unavailable:

~~~text
sudo -n true
sudo: a password is required
~~~

The same failure occurred for safe read-only sudo attempts with sudo -n pct list, sudo -n pvesm status, and sudo -n zfs list. Direct non-root checks showed:

- zfs list is readable and shows rpool/proxmox, but rpool/proxmox/agent-sandbox does not yet exist.
- Direct pvesm status cannot access Proxmox IPC/ACL without authorization.
- Direct pct list fails in the current live system because its wrapper cannot locate PVE::CLI::pct.
- The final configuration is built but not switched into the live host; switching and Proxmox lifecycle operations require root authorization.
- A non-root CUA daemon probe returned health_report overall=degraded because the current host D-Bus has no activatable org.a11y.Bus; this is host evidence only, not guest health evidence.

Once authorization is available, the remaining commands are:

~~~sh
sudo nixos-rebuild switch --flake .#kazuki
sudo systemctl start gui-test-sandbox-storage.service
gui-sandbox template build
gui-sandbox create --task e2e --repo /home/sinkerine/dev/worktrees/disposable-worktree --json
gui-sandbox cua e2e health_report '{}'
gui-sandbox cua e2e get_desktop_state '{}'
gui-sandbox collect e2e
gui-sandbox destroy e2e
~~~

Those commands must confirm guest renderer/version, health healthy, CUA doctor, AT-SPI/window discovery, native Wayland and XWayland apps, bidirectional UID/GID-1000 worktree edits, host GUI usability, and TTL cleanup. Until root authorization and live Proxmox services are available, the implementation intentionally refuses to claim those checks passed.
