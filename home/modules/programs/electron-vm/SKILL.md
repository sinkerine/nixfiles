---
name: electron-vm-test
description: "Test an Electron app's GUI end to end inside an ephemeral microvm: drive and check the renderer through CDP first, and fall back to cua-driver computer use (AT-SPI tree, real X11 input) for native menus, dialogs, and anything CDP cannot reach."
---

# Electron VM testing

`electron-vm` copies a project into a fresh microvm, installs dependencies, and starts the app on a 1280x800 X11 desktop. Nothing in the VM survives `stop`; every `start` is a clean first run. Several VMs can run at once, one per slot. The app is reachable two ways:

- **CDP** (`electron-vm --run ID cdp ...`): the Chrome DevTools Protocol on the app's renderer. Selectors, DOM text, JS evaluation, deterministic input. Use it first.
- **cua** (`electron-vm --run ID cua TOOL JSON`): cua-driver computer use. It reads the whole window's accessibility tree, including the native menu bar, and sends real X11 input. Use it for what CDP cannot reach.

## Run

1. Start from the project root (the directory with `package.json`):

   ```bash
   electron-vm start [-C DIR] [--setup CMD] [--cmd CMD] [--timeout MIN]
   ```

   - It copies git-tracked and untracked, non-ignored files, so uncommitted work is included and `node_modules` is not.
   - `--setup` defaults to the lockfile's install command (`pnpm install --frozen-lockfile`, `yarn install --frozen-lockfile`, `npm ci`, or `npm install`). Add build steps when the app needs them, e.g. `--setup 'npm ci && npm run build'`.
   - `--cmd` defaults to `npm start`. Use the project's real launch script from `package.json`.
   - `--timeout` (default 60 minutes) hard-kills the VM.
   - Setup runs in the VM's RAM by default. For projects with large dependency trees, downloads or builds, keep them on host storage as described in [Storage and memory](#storage-and-memory).
   - It blocks until a window is visible, then prints the window list, whether CDP is available, and a first screenshot. On failure it prints the relevant log tail; fix the cause and run `start` again.
   - Its last line is `run=sN-XXXXXXXX`: this run's id.

2. Pass `--run ID` as the first argument of **every** later command, e.g. `electron-vm --run s2-3fa9c01b cdp snapshot`. Other agents may be running VMs at the same time. The id guarantees you only touch your own VM: once your run stops and its slot is reused, commands with your id fail instead of acting on someone else's VM. Never use `--slot`, never omit `--run`, and never stop or drive a run you did not start.

3. Test with CDP, falling back to cua as described below.

4. Always run `electron-vm --run ID stop` when done, including after failures. Never use `stop --all`. Then clean up as described in [Cleanup](#cleanup).

## CDP first

The VM launches Electron with `--remote-debugging-port` whenever the app resolves Electron through its npm package (`electron .`, Electron Forge, electron-vite, and similar). If `start` reports `CDP: unavailable`, skip to cua.

```bash
electron-vm --run ID cdp targets                    # pages, numbered from 0
electron-vm --run ID cdp snapshot                   # visible interactive elements: label, selector, bounds
electron-vm --run ID cdp click '#save' [--double|--right]
electron-vm --run ID cdp type 'input[name="title"]' 'Hello' [--clear]
electron-vm --run ID cdp key Enter                  # also Escape Tab ctrl+a shift+Tab F5 ...
electron-vm --run ID cdp text ['#status']           # innerText of the page or an element
electron-vm --run ID cdp eval 'document.title'      # any JS; promises are awaited; prints JSON
electron-vm --run ID cdp wait 'document.querySelector(".toast")?.innerText.includes("Saved")' [--timeout 10]
electron-vm --run ID cdp screenshot LABEL           # renderer contents only
```

- Add `--target N|TEXT` before the command when the app has several windows or webviews.
- Start with `snapshot` to find selectors, then act by selector. Prefer stable selectors (`#id`, `data-testid`) over the positional ones `snapshot` falls back to.
- Check every action's effect with `text`, `eval`, or `wait` instead of assuming it worked. Use `wait` for async UI, not sleeps.
- CDP input is synthetic and goes to the renderer only. It does not open native menus, does not operate file or message dialogs, and does not exercise OS-level focus or window behavior. For those, switch to cua.

## Fall back to cua

Use cua when CDP is unavailable, when the target is native UI (menu bar, context menus, file and message dialogs, window chrome), when a feature depends on real OS input, or when a CDP action has no visible effect and you need to rule out an input-path difference.

```bash
electron-vm --run ID cua list_windows                                   # pid and window_id of each window
electron-vm --run ID cua get_window_state '{"pid":P,"window_id":W}'     # AT-SPI tree with [N] rows + screenshot
electron-vm --run ID cua run_actions '{"pid":P,"window_id":W,"steps":[
  {"click":{"role":"button","name":"File"}},
  {"click":{"role":"menuitem","name":"Open…"},"expect":{"role":"dialog"}}
],"observe":true}'
electron-vm --run ID cua get_desktop_state                              # full-screen screenshot
electron-vm --run ID cua list-tools
electron-vm --run ID cua describe TOOL                                  # schema and semantics of a tool
```

- The wrapper adds a named `session` to every call, so element tokens (`<snapshot_id>:<row>`) from `get_window_state` stay valid for the next calls until the next read of that window. It also defaults action tools to `delivery_mode: "foreground"`, which Electron requires.
- Prefer `run_actions` with targets by `role` and `name`, plus `expect` checks, over pixel coordinates. Use `click` with `element_token` for a single step, and `x`/`y` only for custom-drawn surfaces. Coordinates are window-local unless you pass `"coordinate_frame":"desktop"`.
- Screenshot tools print `screenshot: PATH` on stderr; read the image with the `read` tool. stdout stays JSON, so pipe it to `jq` when it is long.
- After a cua action changes the page, CDP can still check the result: act with cua, assert with `cdp text`/`eval`/`wait`.

## Extra dependencies

The guest is NixOS, and setup, start, and `exec` all run as the unprivileged `tester` user. There is no root access: no `sudo`, and no `apt`, `apt-get`, `dnf`, `yum`, `pacman`, or other system package manager. Do not try them or work around their absence.

Add every dependency with `nix shell` from nixpkgs (the same nixpkgs the VM was built from), prefixed to the command that needs it in `--setup` or `--cmd`:

```bash
# A tool used during setup:
electron-vm start --setup 'nix shell nixpkgs#python3 nixpkgs#gnumake -c npm ci'
# A tool the running app calls; prefix --cmd as well:
electron-vm start --setup 'nix shell nixpkgs#ffmpeg -c npm ci' --cmd 'nix shell nixpkgs#ffmpeg -c npm start'
# A different Node.js than the default:
electron-vm start --setup 'nix shell nixpkgs#nodejs_20 -c npm ci' --cmd 'nix shell nixpkgs#nodejs_20 -c npm start'
```

- Native modules that compile against system libraries also need headers and pkg-config paths, which `nix shell` does not set. Use its legacy form `nix-shell -p` for that install step only, e.g. keytar: `--setup 'nix-shell -p pkg-config libsecret --run "npm ci"'`; canvas: `nix-shell -p pkg-config cairo pango libjpeg giflib librsvg --run "npm ci"`.
- Find package names with `electron-vm --run ID exec 'nix search nixpkgs ffmpeg'`, and try a dependency with `exec 'nix shell nixpkgs#ffmpeg -c ffmpeg -version'` before rerunning `start`.
- Do not use `nix profile install` or `nix-env`; dependencies must be visible in the `start` command so a rerun reproduces them.
- Packages download from cache.nixos.org into the VM's RAM-backed store; the host is never involved. Never install anything on the host for the test.
- Report the extra packages with your results so they can become part of the project's documented setup.

## Storage and memory

The guest has 8 GiB of RAM and no disk. Its root filesystem (`~/app`, `~/.cache`, `~/.npm`, `/tmp`) is a tmpfs of about 4 GiB, and packages added with `nix shell` go to another tmpfs. Dependencies, package-manager caches, downloaded binaries and build outputs therefore compete with the running app for the same memory. A large install or build fails with `ENOSPC`, or the kernel OOM-kills a process, usually a renderer, which Chromium marks as the first to kill. Those are environment failures, not app bugs: confirm them with `electron-vm --run ID logs vm` (look for `Out of memory: Killed process`) and report them as such.

### How the job share works

- `start` copies the project into the slot's job directory on the host. The guest mounts that directory read-write over 9p at `/job`: source at `/job/src`, results at `/job/out`. Files written there are stored on the host, not in guest RAM.
- At boot the guest copies `/job/src` to `~/app`, then runs `--setup` and `--cmd` as two separate `bash -euo pipefail` scripts that each start in `~/app`. A `cd` or `export` in setup does not carry over to the launch command.
- `exec` also starts in `~/app`, with neither script's environment and a shorter `PATH`: the `git`, `pnpm`, `yarn`, `python3`, `make` and `gcc` that setup and launch get are missing.
- Only the launch command gets the CDP wrapper, through `ELECTRON_OVERRIDE_DIST_PATH`; setup runs Electron's own install scripts unwrapped. The wrapper looks up the project's Electron from its working directory, falling back to `~/app`, so launch from inside the project.

### Check what backs the share

Before relying on it, check the host filesystem that holds the job directories:

```bash
findmnt -T /var/tmp/electron-vm -o TARGET,SOURCE,FSTYPE   # on the host
```

- A disk-backed filesystem (ext4, xfs, btrfs, zfs, ...) holds the files without using RAM, apart from reclaimable page cache. Check its free space with `df -h /var/tmp/electron-vm`.
- `tmpfs` means the files consume host RAM instead: moving work there only shifts memory from the VM to the host, which other users and VMs share. Keep the guest default in that case unless the host has clearly spare memory, and say so in your report.

### Decide what to install and build

Read `package.json` before choosing commands, along with the files it delegates to:

- `scripts`: the project's own install hooks (`preinstall`, `postinstall`, `prepare`), build, dev/start and test scripts, and any launcher scripts they call. Use these commands rather than reconstructing their steps. Read custom launchers for the environment variables and flags they honor, such as a debugging port, a headless or background mode, or a build they run first.
- `packageManager`, `engines` and the lockfile: which package manager and version to use, and with which frozen-lockfile flag.
- `workspaces` or the package manager's workspace file: in a monorepo, install and build only the packages the app under test needs, if the package manager supports filtering.
- Native modules (`node-gyp`, `prebuild-install`, `@electron/rebuild`, `electron-builder install-app-deps`, or the project's own rebuild script): run the project's rebuild in setup, where the CDP wrapper is not set. A command inside `--cmd` that runs Electron as Node (`ELECTRON_RUN_AS_NODE=1`) or rebuilds against it must run with `env -u ELECTRON_OVERRIDE_DIST_PATH`, or the wrapper's extra flags make it fail with `bad option: --remote-debugging-port=9222`.
- CDP: `electron-vm cdp` connects to port 9222. If the project's launcher passes its own `--remote-debugging-port` or picks a port from an environment variable, set it to 9222 through that mechanism; a port given later on Electron's command line overrides the wrapper's.

Add only the build steps the launch or test actually needs, and only the extra `nix shell` packages a failing step proves are missing ([Extra dependencies](#extra-dependencies)).

### Keep writable files on the share

Select the host-backed directory in setup **before installing**, select it again in the launch command, and select it explicitly in every later `exec`. Never move an installed tree or a running app between locations. A shared environment file keeps the three in sync:

```bash
electron-vm start \
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

electron-vm --run ID exec '. /job/work/env.sh && npm test'
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

### Known 9p behavior

- Small-file I/O is slower than in tmpfs: installs and builds with many files take noticeably longer.
- File watching: changes made inside the guest raise inotify events, so dev-server reloads after edits made through `exec` work. Edits made on the host to the slot directory do not reach guest watchers; make edits in the guest or restart the app.
- Executable bits and symlinks (`node_modules/.bin`, Electron's binary) work. Files belong to the host user, so tools that change ownership can fail.
- Hard links, FIFOs and Unix sockets work on the share. If a tool still fails on one there, switch it to copying (for pnpm, `--package-import-method copy`) or point its `TMPDIR` back at `/tmp`.

### Build and test sequentially

- Run installs, builds and test suites one at a time, and not beside a running dev app when memory is tight. The app runs as `tester` and is not restarted by the harness, so `exec` can end its processes to free memory for a later build.
- Cap parallelism with each tool's own option: the test runner's worker count, `make -j`, the bundler's or compiler's thread settings.
- Do not use the CDP-wrapped Electron for builds, native rebuilds or test-runner launches of Electron; see the native-module note above.

### Storage cleanup

Everything under `/job`, including `node_modules`, caches, `TMPDIR` and build outputs, survives `stop` and occupies host disk until `electron-vm --run ID clean` or the next `start` in the same slot. `clean` deletes the whole job directory, including read-only directories some tools create. Keep run-owned files under `/job` so `clean` removes them; nothing else in the guest is shared with the host.

## Debugging

```bash
electron-vm --run ID logs app|setup|vm [-n N]   # app.log includes renderer console messages
electron-vm --run ID exec 'CMD'                 # shell in the guest at ~/app as tester; no root; nix available; cd elsewhere explicitly
electron-vm --run ID screenshot LABEL           # full screen, outside cua
electron-vm --run ID windows
electron-vm --run ID status
```

## Evidence

Screenshots are numbered in the run's `out/steps` directory (`electron-vm --run ID out` prints the `out` path), next to `setup.log`, `app.log` and `vm.log`. They stay until the slot is reused by another `start`, so copy the ones you cite elsewhere before you finish. For each acceptance criterion, cite the CDP output or the cua `expect` result that proves it, plus a screenshot for anything visual, and report what you saw, not what you expected.

## Cleanup

After the test, once you have copied the evidence you cite:

```bash
electron-vm --run ID stop     # if not already stopped
electron-vm --run ID clean    # deletes the run's source copy and results on the host
```

- Packages fetched with `nix shell` or `nix-shell -p`, and anything written outside `/job`, live in the VM's RAM and disappear with `stop`; there is no host Nix store or cache to clean for them.
- Anything written under `/job` (dependencies, caches and build outputs placed on the share) stays on the host until `clean`, which removes all of it.
- During a long run, `electron-vm --run ID exec 'nix store gc'` frees guest memory taken by dependencies no running command still uses. It needs no root: the guest's Nix daemon performs it.
- If you built anything on the host with Nix for this test, delete the `result` symlinks you created. Do not run host-wide garbage collection (`nix-collect-garbage`, `nix store gc` on the host); it affects every other project and user on the machine.

## Limits

- 8 GiB of RAM with a RAM-backed root filesystem; see [Storage and memory](#storage-and-memory) before installing or building anything large.
- Slots are limited (3 by default). If `start` reports that all slots are busy, wait and retry rather than stopping other runs.
- No GPU: rendering is software-only, so WebGL and performance observations are not representative. GPU-process errors in `app.log` are expected.
- X11 with the openbox window manager; Wayland-specific behavior is not covered.
- The desktop is minimal: no secret service (`safeStorage` falls back to `basic_text`), no notification daemon (notifications are accepted but never shown), and no system tray host (tray icons are created but invisible). Do not report these as app bugs.
- Native modules that compile against system libraries need their headers added as described in [Extra dependencies](#extra-dependencies); prebuilt binaries work as is.
- The guest has internet through user-mode networking and reaches the host at `10.0.2.2`. Node.js is nixpkgs' default version; use `--setup` to adapt if the project pins another.
- VNC is open without a password on a per-slot port so a human can watch (`electron-vm --run ID vnc`).
