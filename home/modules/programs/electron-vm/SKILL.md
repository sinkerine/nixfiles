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

## Debugging

```bash
electron-vm --run ID logs app|setup|vm [-n N]   # app.log includes renderer console messages
electron-vm --run ID exec 'CMD'                 # shell in the guest at ~/app as tester; no root; nix available
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

- Everything fetched inside the guest (`nix shell`, `nix-shell -p`, `npm` caches) lives in the VM's RAM and disappears with `stop`; there is no host Nix store or cache to clean for it.
- During a long run, `electron-vm --run ID exec 'nix store gc'` frees guest memory taken by dependencies no running command still uses. It needs no root: the guest's Nix daemon performs it.
- If you built anything on the host with Nix for this test, delete the `result` symlinks you created. Do not run host-wide garbage collection (`nix-collect-garbage`, `nix store gc` on the host); it affects every other project and user on the machine.

## Limits

- Slots are limited (3 by default). If `start` reports that all slots are busy, wait and retry rather than stopping other runs.
- No GPU: rendering is software-only, so WebGL and performance observations are not representative. GPU-process errors in `app.log` are expected.
- X11 with the openbox window manager; Wayland-specific behavior is not covered.
- The desktop is minimal: no secret service (`safeStorage` falls back to `basic_text`), no notification daemon (notifications are accepted but never shown), and no system tray host (tray icons are created but invisible). Do not report these as app bugs.
- Native modules that compile against system libraries need their headers added as described in [Extra dependencies](#extra-dependencies); prebuilt binaries work as is.
- The guest has internet through user-mode networking and reaches the host at `10.0.2.2`. Node.js is nixpkgs' default version; use `--setup` to adapt if the project pins another.
- VNC is open without a password on a per-slot port so a human can watch (`electron-vm --run ID vnc`).
