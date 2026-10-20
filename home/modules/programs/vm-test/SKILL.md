---
name: vm-test
description: "Test apps, services, and CLI tools inside an ephemeral NixOS microvm with caller-supplied dependencies, setup, launch commands, and invariants. Supports GUI testing through cua-driver and Electron renderer testing through CDP, with Electron-specific invariants in the same skill."
---

# VM testing

`vm-test` is the harness command. It copies a project into a fresh NixOS microvm and runs caller-selected setup and launch commands. It includes a 1280x800 X11 desktop for GUI apps and supports services, CLI tools, and batch tests through `exec` and logs. Guest-local state disappears on `stop`; files under the host-backed `/job` share survive until `clean`. Several VMs can run at once, one per slot.

## Caller contract and invariants

Read the calling task and project instructions to choose dependencies, setup, launch command, readiness checks, and acceptance criteria. Callers may supply any of these directly. Honor explicit requirements, and infer routine missing details from the project's manifests and scripts. Add required Nix dependencies before starting; there is no need to wait for a known dependency to fail first. Record the exact commands and packages so the test is reproducible.

- Common invariants: isolate each run, operate only on your own run ID, install extra tools inside the guest through Nix, assert observable results, preserve cited evidence, and stop and clean your run.
- Caller invariants: apply the task's required state, environment, behavior, and checks in addition to these common rules. A caller can add dependencies and checks without editing this skill or the base VM.
- Electron invariants: when the target uses Electron, also apply [Electron invariants](#electron-invariants). Keep these in this skill so a generic VM test retains Electron coverage.
- GUI targets: wait for a visible window, then use CDP when available and cua for native UI or real OS input.
- Services and CLI targets: use `--no-wait`, check setup completion and application readiness explicitly, then assert through `exec`, exit markers, and logs. A GUI window is not their readiness condition.

GUI apps are reachable two ways:

- **CDP** (`vm-test --run ID cdp ...`): the Chrome DevTools Protocol on the app's renderer. Selectors, DOM text, JS evaluation, deterministic input. Use it first.
- **cua** (`vm-test --run ID cua TOOL JSON`): cua-driver computer use. It reads the whole window's accessibility tree, including the native menu bar, and sends real X11 input. Use it for what CDP cannot reach.

## Run

1. Start from the project root:

   ```bash
   vm-test start [-C DIR] [--setup CMD] [--cmd CMD] [--timeout MIN] [--no-wait]
   ```

   - It copies git-tracked and untracked, non-ignored files, so uncommitted work is included and `node_modules` is not.
   - `--setup` defaults to the lockfile's install command (`pnpm install --frozen-lockfile`, `yarn install --frozen-lockfile`, `npm ci`, or `npm install`). Add build steps when the app needs them, e.g. `--setup 'npm ci && npm run build'`.
   - `--cmd` defaults to `npm start`. Use the project's real launch command. Without `package.json`, supply both `--setup` and `--cmd`; use `--setup ':'` when no setup is needed.
   - For non-GUI workloads, add `--no-wait`: it returns the run ID immediately, before setup completes. Poll `status` and inspect `logs setup`; check `/job/out/setup-exit` for setup success before sending workload commands. A finite `--cmd` writes its exit code to `/job/out/app-exit`; assert that code and its output. For a service, poll its actual health endpoint or readiness signal through `exec`, and inspect `logs app` on failure. Do not call `wait`, which requires a window.
   - `--timeout` (default 60 minutes) hard-kills the VM.
   - Setup runs in the VM's RAM by default. For projects with large dependency trees, downloads or builds, keep them on host storage as described in [Storage and memory](#storage-and-memory).
   - Unless `--no-wait` is used, it blocks until a window is visible, then prints the window list, whether CDP is available, and a first screenshot. On failure it prints the relevant log tail; fix the cause and run `start` again.
   - Its last line is `run=sN-XXXXXXXX`: this run's id.

2. Pass `--run ID` as the first argument of **every** later command, e.g. `vm-test --run s2-3fa9c01b cdp snapshot`. Other agents may be running VMs at the same time. The id guarantees you only touch your own VM: once your run stops and its slot is reused, commands with your id fail instead of acting on someone else's VM. Never use `--slot`, never omit `--run`, and never stop or drive a run you did not start.

3. Check the caller's acceptance criteria using `exec` and logs for CLI/service workloads, or CDP and cua for GUI workloads.

4. Always run `vm-test --run ID stop` when done, including after failures. Never use `stop --all`. Then clean up as described in [Cleanup](#cleanup).

## Electron invariants

Apply these whenever the target is an Electron app:

- Inspect `package.json`, the lockfile, and delegated launcher/build scripts. Use the project's package manager, build commands, and native-module rebuild steps.
- Prefer CDP for renderer actions and assertions, and use cua for native menus, dialogs, focus, and real OS input. Check the effect of each action.
- Keep native rebuilds and `ELECTRON_RUN_AS_NODE` commands outside the CDP wrapper: run them in setup, or unset `ELECTRON_OVERRIDE_DIST_PATH` for that command.
- Use port 9222 if the project selects its own remote debugging port. Launch from inside the project so the wrapper resolves its Electron binary.
- Distinguish VM limitations (software rendering, absent desktop services, or measured memory exhaustion) from app failures. Report any required Electron criterion that the environment could not exercise.

### CDP first

The VM launches Electron with `--remote-debugging-port` whenever the app resolves Electron through its npm package (`electron .`, Electron Forge, electron-vite, and similar). If `start` reports `CDP: unavailable`, skip to cua.

```bash
vm-test --run ID cdp targets                    # pages, numbered from 0
vm-test --run ID cdp snapshot                   # visible interactive elements: label, selector, bounds
vm-test --run ID cdp click '#save' [--double|--right]
vm-test --run ID cdp type 'input[name="title"]' 'Hello' [--clear]
vm-test --run ID cdp key Enter                  # also Escape Tab ctrl+a shift+Tab F5 ...
vm-test --run ID cdp text ['#status']           # innerText of the page or an element
vm-test --run ID cdp eval 'document.title'      # any JS; promises are awaited; prints JSON
vm-test --run ID cdp wait 'document.querySelector(".toast")?.innerText.includes("Saved")' [--timeout 10]
vm-test --run ID cdp screenshot LABEL           # renderer contents only
```

- Add `--target N|TEXT` before the command when the app has several windows or webviews.
- Start with `snapshot` to find selectors, then act by selector. Prefer stable selectors (`#id`, `data-testid`) over the positional ones `snapshot` falls back to.
- Check every action's effect with `text`, `eval`, or `wait` instead of assuming it worked. Use `wait` for async UI, not sleeps.
- CDP input is synthetic and goes to the renderer only. It does not open native menus, does not operate file or message dialogs, and does not exercise OS-level focus or window behavior. For those, switch to cua.

## Fall back to cua

Use cua when CDP is unavailable, when the target is native UI (menu bar, context menus, file and message dialogs, window chrome), when a feature depends on real OS input, or when a CDP action has no visible effect and you need to rule out an input-path difference.

```bash
vm-test --run ID cua list_windows                                   # pid and window_id of each window
vm-test --run ID cua get_window_state '{"pid":P,"window_id":W}'     # AT-SPI tree with [N] rows + screenshot
vm-test --run ID cua run_actions '{"pid":P,"window_id":W,"steps":[
  {"click":{"role":"button","name":"File"}},
  {"click":{"role":"menuitem","name":"Open…"},"expect":{"role":"dialog"}}
],"observe":true}'
vm-test --run ID cua get_desktop_state                              # full-screen screenshot
vm-test --run ID cua list-tools
vm-test --run ID cua describe TOOL                                  # schema and semantics of a tool
```

- The wrapper adds a named `session` to every call, so element tokens (`<snapshot_id>:<row>`) from `get_window_state` stay valid for the next calls until the next read of that window. It also defaults action tools to `delivery_mode: "foreground"`, which Electron requires.
- Prefer `run_actions` with targets by `role` and `name`, plus `expect` checks, over pixel coordinates. Use `click` with `element_token` for a single step, and `x`/`y` only for custom-drawn surfaces. Coordinates are window-local unless you pass `"coordinate_frame":"desktop"`.
- Screenshot tools print `screenshot: PATH` on stderr; read the image with the `read` tool. stdout stays JSON, so pipe it to `jq` when it is long.
- After a cua action changes the page, CDP can still check the result: act with cua, assert with `cdp text`/`eval`/`wait`.

## Caller-supplied dependencies

The guest is NixOS, and setup, start, and `exec` all run as the unprivileged `tester` user. There is no root access: no `sudo`, and no `apt`, `apt-get`, `dnf`, `yum`, `pacman`, or other system package manager. Do not try them or work around their absence.

Callers can add build tools, language runtimes, native libraries, browsers, and app runtime tools as needed. Use `nix shell` from nixpkgs (the same nixpkgs the VM was built from), prefixed to each command that needs the package in `--setup`, `--cmd`, or `exec`. Setup and launch are separate shells; a dependency in setup is not automatically available at runtime:

```bash
# A non-Electron GUI app, with no project setup:
vm-test start --setup ':' --cmd 'nix shell nixpkgs#xterm -c xterm'
# A CLI workload; inspect setup-exit and app-exit, then logs app:
vm-test start --no-wait --setup ':' --cmd 'nix shell nixpkgs#python3 -c python3 --version'
# A tool used during setup:
vm-test start --setup 'nix shell nixpkgs#python3 nixpkgs#gnumake -c npm ci'
# A tool the running app calls; prefix --cmd as well:
vm-test start --setup 'nix shell nixpkgs#ffmpeg -c npm ci' --cmd 'nix shell nixpkgs#ffmpeg -c npm start'
# A different Node.js than the default:
vm-test start --setup 'nix shell nixpkgs#nodejs_20 -c npm ci' --cmd 'nix shell nixpkgs#nodejs_20 -c npm start'
```

- Native modules that compile against system libraries also need headers and pkg-config paths, which `nix shell` does not set. Use its legacy form `nix-shell -p` for that install step only, e.g. keytar: `--setup 'nix-shell -p pkg-config libsecret --run "npm ci"'`; canvas: `nix-shell -p pkg-config cairo pango libjpeg giflib librsvg --run "npm ci"`.
- Find package names with `vm-test --run ID exec 'nix search nixpkgs ffmpeg'`, and try a dependency with `exec 'nix shell nixpkgs#ffmpeg -c ffmpeg -version'` before rerunning `start`.
- Do not use `nix profile install` or `nix-env`; dependencies must be visible in the `start` command so a rerun reproduces them.
- Packages download from cache.nixos.org into the VM's RAM-backed store; the host is never involved. Never install anything on the host for the test.
- Report the extra packages with your results so they can become part of the project's documented setup.

## Storage and memory

The guest has 8 GiB of RAM and no disk. Its root filesystem (`~/app`, `~/.cache`, `~/.npm`, `/tmp`) is a tmpfs of about 4 GiB, and packages added with `nix shell` go to another tmpfs. Dependencies, package-manager caches, downloaded binaries and build outputs therefore compete with the running app for the same memory. A large install or build fails with `ENOSPC`, or the kernel OOM-kills a process, usually a renderer, which Chromium marks as the first to kill. Those are environment failures, not app bugs: confirm them with `vm-test --run ID logs vm` (look for `Out of memory: Killed process`) and report them as such.

### How the job share works

- `start` copies the project into the slot's job directory on the host. The guest mounts that directory read-write over virtiofs at `/job`: source at `/job/src`, results at `/job/out`. Files written there are stored on the host, not in guest RAM.
- At boot the guest copies `/job/src` to `~/app`, then runs `--setup` and `--cmd` as two separate `bash -euo pipefail` scripts that each start in `~/app`. A `cd` or `export` in setup does not carry over to the launch command.
- `exec` also starts in `~/app`, with neither script's environment and a shorter `PATH`: the `git`, `pnpm`, `yarn`, `python3`, `make` and `gcc` that setup and launch get are missing.
- Only the launch command gets the CDP wrapper, through `ELECTRON_OVERRIDE_DIST_PATH`; setup runs Electron's own install scripts unwrapped. The wrapper looks up the project's Electron from its working directory, falling back to `~/app`, so launch from inside the project.

### Check what backs the share

Before relying on it, check the host filesystem that holds the job directories:

```bash
findmnt -T /var/tmp/vm-test -o TARGET,SOURCE,FSTYPE   # on the host
```

- A disk-backed filesystem (ext4, xfs, btrfs, zfs, ...) holds the files without using RAM, apart from reclaimable page cache. Check its free space with `df -h /var/tmp/vm-test`.
- `tmpfs` means the files consume host RAM instead: moving work there only shifts memory from the VM to the host, which other users and VMs share. Keep the guest default in that case unless the host has clearly spare memory, and say so in your report.

### Decide what to install and build

Read the project's manifests and delegated scripts before choosing commands (for example `pyproject.toml`, `Cargo.toml`, `go.mod`, a `Makefile`, or `package.json`). Use the project's own setup, build, launch, and test entry points. For Node.js and Electron projects, inspect:

- `scripts`: the project's own install hooks (`preinstall`, `postinstall`, `prepare`), build, dev/start and test scripts, and any launcher scripts they call. Use these commands rather than reconstructing their steps. Read custom launchers for the environment variables and flags they honor, such as a debugging port, a headless or background mode, or a build they run first.
- `packageManager`, `engines` and the lockfile: which package manager and version to use, and with which frozen-lockfile flag.
- `workspaces` or the package manager's workspace file: in a monorepo, install and build only the packages the app under test needs, if the package manager supports filtering.
- Native modules (`node-gyp`, `prebuild-install`, `@electron/rebuild`, `electron-builder install-app-deps`, or the project's own rebuild script): run the project's rebuild in setup, where the CDP wrapper is not set. A command inside `--cmd` that runs Electron as Node (`ELECTRON_RUN_AS_NODE=1`) or rebuilds against it must run with `env -u ELECTRON_OVERRIDE_DIST_PATH`, or the wrapper's extra flags make it fail with `bad option: --remote-debugging-port=9222`.
- CDP: `vm-test cdp` connects to port 9222. If the project's launcher passes its own `--remote-debugging-port` or picks a port from an environment variable, set it to 9222 through that mechanism; a port given later on Electron's command line overrides the wrapper's.

Add only the build steps and extra Nix packages required by the caller or the project's documented setup, launch, and tests. Resolve additional missing dependencies from failures as needed; see [Caller-supplied dependencies](#caller-supplied-dependencies).

### Keep writable files on the share

Select the host-backed directory in setup **before installing**, select it again in the launch command, and select it explicitly in every later `exec`. Never move an installed tree or a running app between locations. A shared environment file keeps the three in sync:

```bash
vm-test start \
  --setup '
    mkdir -p /job/work/cache /job/work/tmp
    cat > /job/work/env.sh <<"EOF"
cd /job/src
export XDG_CACHE_HOME=/job/work/cache TMPDIR=/job/work/tmp
export npm_config_cache=/job/work/cache/npm
EOF
    # exec shells lack the build tools on the setup and launch PATH.
    printf "export PATH=%q\n" "$PATH" >> /job/work/env.sh
    . /job/work/env.sh
    npm ci
    npm run build
  ' \
  --cmd '. /job/work/env.sh; npm start'

vm-test --run ID exec '. /job/work/env.sh && npm test'
```

Replace `npm ci`, `npm run build` and `npm start` with the project's own commands, and add each cache the project uses to `env.sh`:

| Writer | Default location | Redirect |
| --- | --- | --- |
| npm | `~/.npm` | `npm_config_cache` |
| pnpm store | `~/.local/share/pnpm/store`; `/job/.pnpm-store` when the project is on the share | `--store-dir /job/work/pnpm-store` on `pnpm install` |
| Yarn 1 and Yarn 2+ cache | `~/.cache/yarn`, `~/.yarn/berry/cache` | `YARN_CACHE_FOLDER` |
| Electron, electron-builder, node-gyp, Playwright and other tools following XDG | `~/.cache/...` | `XDG_CACHE_HOME` |
| Temporary files of builds and tests | `/tmp` | `TMPDIR` |
| Build outputs and `node_modules` | project directory | already on the share via `cd /job/src` |

Confirm the result instead of trusting the table: after setup, `exec '. /job/work/env.sh && df -h / /job && du -sh ~ /tmp /job/src /job/work'` should show the guest root nearly unchanged and the growth under `/job`. Package managers report their location with `npm config get cache`, `pnpm store path` or `yarn cache dir`, run in the same environment.

### What still uses guest RAM

Moving files does not make a project fit; it only removes their storage from the budget.

- Processes: Node, bundlers and compilers, the Electron main, GPU and renderer processes, and test runners and their workers.
- Packages added with `nix shell`/`nix-shell -p`, which stay in the guest's tmpfs store. `exec 'nix store gc'` frees those no running command still uses.
- The initial source copy in `~/app`, which the harness always makes. It is usually small; a source tree with large tracked assets still costs that much RAM.
- The app's own user data directory (`~/.config/<app name>`), unless the project lets you relocate it.
- Page cache for files read from or written to `/job`. It is reclaimable, so judge headroom by the `available` column of `free -m`, not `free`.

Measure instead of assuming: record `free -m`, `df -h / /job` and `du -sh` of the large directories before and after setup and each build. Do not state that a project fits in the VM, or name a memory threshold, unless you measured that workload.

### Known share behavior

- Small-file I/O is slower than in tmpfs, so installs and builds with many files take somewhat longer than in the guest root.
- File watching: changes made inside the guest raise inotify events, so dev-server reloads after edits made through `exec` work. Edits made on the host to the slot directory are visible to reads in the guest but do not reach guest watchers; make edits in the guest or restart the app.
- Executable bits and symlinks (`node_modules/.bin`, Electron's binary) work. Every file is stored as the host user and shows up as `tester:users` in the guest, whichever guest user writes it.
- Hard links, FIFOs and Unix sockets work on the share. If a tool still fails on one there, switch it to copying (for pnpm, `--package-import-method copy`) or point its `TMPDIR` back at `/tmp`.

### Build and test sequentially

- Run installs, builds and test suites one at a time, and not beside a running dev app when memory is tight. The app runs as `tester` and is not restarted by the harness, so `exec` can end its processes to free memory for a later build.
- Cap parallelism with each tool's own option: the test runner's worker count, `make -j`, the bundler's or compiler's thread settings.
- Do not use the CDP-wrapped Electron for builds, native rebuilds or test-runner launches of Electron; see the native-module note above.

### Storage cleanup

Everything under `/job`, including `node_modules`, caches, `TMPDIR` and build outputs, survives `stop` and occupies host disk until `vm-test --run ID clean` or the next `start` in the same slot. `clean` deletes the whole job directory, including read-only directories some tools create. Keep run-owned files under `/job` so `clean` removes them; nothing else in the guest is shared with the host.

## Debugging

```bash
vm-test --run ID logs app|setup|vm [-n N]   # app.log includes renderer console messages
vm-test --run ID exec 'CMD'                 # shell in the guest at ~/app as tester; no root; nix available; cd elsewhere explicitly
vm-test --run ID screenshot LABEL           # full screen, outside cua
vm-test --run ID windows
vm-test --run ID status
```

## Evidence

Screenshots are numbered in the run's `out/steps` directory (`vm-test --run ID out` prints the `out` path), next to `setup.log`, `app.log` and `vm.log`. They stay until the slot is reused by another `start`, so copy the ones you cite elsewhere before you finish. For each acceptance criterion, cite the command output and exit status, service health response, CDP output, or cua `expect` result that proves it, plus a screenshot for anything visual. Report what you saw, not what you expected.

## Cleanup

After the test, once you have copied the evidence you cite:

```bash
vm-test --run ID stop     # if not already stopped
vm-test --run ID clean    # deletes the run's source copy and results on the host
```

- Packages fetched with `nix shell` or `nix-shell -p`, and anything written outside `/job`, live in the VM's RAM and disappear with `stop`; there is no host Nix store or cache to clean for them.
- Anything written under `/job` (dependencies, caches and build outputs placed on the share) stays on the host until `clean`, which removes all of it.
- During a long run, `vm-test --run ID exec 'nix store gc'` frees guest memory taken by dependencies no running command still uses. It needs no root: the guest's Nix daemon performs it.
- If you built anything on the host with Nix for this test, delete the `result` symlinks you created. Do not run host-wide garbage collection (`nix-collect-garbage`, `nix store gc` on the host); it affects every other project and user on the machine.

## Limits

- 8 GiB of RAM with a RAM-backed root filesystem; see [Storage and memory](#storage-and-memory) before installing or building anything large.
- Slots are limited (3 by default). If `start` reports that all slots are busy, wait and retry rather than stopping other runs.
- No GPU: rendering is software-only, so WebGL and performance observations are not representative. GPU-process errors in `app.log` are expected.
- X11 with the openbox window manager; Wayland-specific behavior is not covered.
- The desktop is minimal: no secret service (`safeStorage` falls back to `basic_text`), no notification daemon (notifications are accepted but never shown), and no system tray host (tray icons are created but invisible). Do not report these as app bugs.
- Native modules that compile against system libraries need their headers added as described in [Caller-supplied dependencies](#caller-supplied-dependencies); prebuilt binaries work as is.
- The guest has internet through user-mode networking and reaches the host at `10.0.2.2`. Node.js is nixpkgs' default version; use `--setup` to adapt if the project pins another.
- VNC is open without a password on a per-slot port so a human can watch (`vm-test --run ID vnc`).
