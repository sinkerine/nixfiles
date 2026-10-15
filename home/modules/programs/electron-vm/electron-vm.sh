# SLOTS and slot_config are defined by the electron-vm home module.
STATE_DIR=${XDG_STATE_HOME:-$HOME/.local/state}/electron-vm
CUA_SESSION=electron-vm
KEY=$STATE_DIR/id_ed25519
# Set by --run/ELECTRON_VM_RUN or --slot/ELECTRON_VM_SLOT; otherwise
# resolved from running VMs.
REQUESTED_RUN=${ELECTRON_VM_RUN:-}
REQUESTED_SLOT=${ELECTRON_VM_SLOT:-}

usage() {
  cat <<'EOF'
electron-vm - drive an Electron app inside an ephemeral microvm

Usage: electron-vm [--run ID | --slot N] COMMAND ...

Several VMs can run at once, one per slot. 'start' claims a free slot and
prints a run id (run=sN-XXXXXXXX). Pass '--run ID' (or ELECTRON_VM_RUN) on
every later command: it fails once that run's slot is reused, so a stale id
never reaches another run's VM. '--slot N' targets whatever runs in slot N.
Without either, commands use the only running VM.

Lifecycle:
  start [-C DIR] [--setup CMD] [--cmd CMD] [--timeout MIN] [--no-wait]
                       Copy DIR (default: cwd; git-tracked + untracked, not ignored)
                       into a fresh VM, run setup (default: from lockfile), then
                       start the app (default: npm start). Waits until a window shows.
  wait [--timeout SEC] Wait until setup finished and a window is visible.
  status               With a slot: that VM's setup/app state. Without: all slots.
  stop [--all]         Power off the VM (or every VM). Results stay in the slot's
                       out dir until that slot's next start.

Inspect and drive the app:
  cdp COMMAND...       Chrome DevTools Protocol on the app's renderer
                       (targets, snapshot, text, eval, wait, click, type, key,
                       screenshot); 'cdp help' lists them.
  cua TOOL [JSON]      cua-driver computer use (AT-SPI tree, real X11 input).
                       Adds session and foreground delivery; 'cua list-tools',
                       'cua describe TOOL' document the tools.
  screenshot [LABEL]   Full 1280x800 screen.
  windows              List visible windows with geometry.

  clean                Delete a stopped run's files on the host (source copy and
                       results). Copy any evidence you need first.

Debugging:
  exec CMD...          Run a shell command in the guest (as unprivileged tester, DISPLAY=:0).
  logs [setup|app|vm] [-n N]
  out                  Print the host results directory.
  vnc                  Print the VNC address for watching the screen.
EOF
}

die() {
  echo "electron-vm: $*" >&2
  exit 1
}

slot_run_id() {
  cat "$STATE_DIR/slot-$1/run-id" 2>/dev/null || true
}

use_slot() {
  local config
  config=$(slot_config "$1") || die "no slot $1 (slots are 1-$SLOTS)"
  SLOT=$1
  read -r JOB_DIR RUNNER SSH_PORT VNC_PORT <<<"$config"
  OUT_DIR=$JOB_DIR/out
  SLOT_STATE=$STATE_DIR/slot-$SLOT
  PID_FILE=$SLOT_STATE/pid
}

slot_running() {
  local pid_file=$STATE_DIR/slot-$1/pid
  [ -f "$pid_file" ] && kill -0 "$(cat "$pid_file")" 2>/dev/null
}

running_slots() {
  local n
  for n in $(seq "$SLOTS"); do
    if slot_running "$n"; then echo "$n"; fi
  done
}

is_running() {
  slot_running "$SLOT"
}

# Select the slot a command acts on. With require=1 the VM must be running;
# otherwise a stopped slot's results can still be read.
resolve_slot() {
  local require=$1 running
  if [ -n "$REQUESTED_RUN" ]; then
    [[ $REQUESTED_RUN =~ ^s([0-9]+)-[0-9a-f]+$ ]] || die "invalid run id: $REQUESTED_RUN"
    use_slot "${BASH_REMATCH[1]}"
    [ "$(slot_run_id "$SLOT")" = "$REQUESTED_RUN" ] ||
      die "run $REQUESTED_RUN is gone; slot $SLOT now belongs to another run"
    if [ "$require" = 1 ] && ! is_running; then
      die "run $REQUESTED_RUN has stopped; its results are in $OUT_DIR"
    fi
    return
  fi
  if [ -n "$REQUESTED_SLOT" ]; then
    use_slot "$REQUESTED_SLOT"
    if [ "$require" = 1 ] && ! is_running; then
      die "slot $SLOT is not running; use 'electron-vm start'"
    fi
    return
  fi
  mapfile -t running < <(running_slots)
  case ${#running[@]} in
    1) use_slot "${running[0]}" ;;
    0)
      if [ "$require" = 0 ] && [ -f "$STATE_DIR/last-slot" ]; then
        use_slot "$(cat "$STATE_DIR/last-slot")"
      else
        die "no VM is running; use 'electron-vm start'"
      fi
      ;;
    *) die "VMs are running in slots ${running[*]}; pass the --run ID that 'start' printed" ;;
  esac
}

ssh_vm() {
  ssh -p "$SSH_PORT" -i "$KEY" \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR -o ConnectTimeout=3 -o BatchMode=yes \
    tester@127.0.0.1 "$@"
}

# Run a command in the guest's desktop session; arguments are quoted for the remote shell.
remote() {
  ssh_vm "export DISPLAY=:0 XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus; $(printf '%q ' "$@")"
}

tail_log() {
  local name=$1 lines=${2:-40}
  if [ -f "$OUT_DIR/$name.log" ]; then
    echo "--- $name.log (last $lines lines) ---" >&2
    tail -n "$lines" "$OUT_DIR/$name.log" >&2
  fi
}

default_setup() {
  local dir=$1
  if [ -f "$dir/pnpm-lock.yaml" ]; then
    echo "pnpm install --frozen-lockfile"
  elif [ -f "$dir/yarn.lock" ]; then
    echo "yarn install --frozen-lockfile"
  elif [ -f "$dir/package-lock.json" ]; then
    echo "npm ci"
  else
    echo "npm install"
  fi
}

# Next numbered evidence file name in the steps directory.
step_name() {
  local label=$1 ext=$2 n
  label=$(printf '%s' "$label" | tr -c 'A-Za-z0-9_-' '-')
  n=$(find "$OUT_DIR/steps" -name '*.png' -o -name '*.jpg' | wc -l)
  printf '%03d-%s.%s' "$((n + 1))" "$label" "$ext"
}

shot() {
  local file
  file=$(step_name "${1:-shot}" png)
  remote import -window root "/job/out/steps/$file"
  echo "$OUT_DIR/steps/$file"
}

cmd_cdp() {
  remote electron-vm-cdp "$@" | sed "s|/job/out|$OUT_DIR|g"
}

cmd_cua() {
  local tool=${1:-} json=${2:-"{}"} file="" ext=png
  case $tool in
    list-tools | describe)
      remote cua-driver "$@"
      return
      ;;
  esac
  [[ $tool =~ ^[a-z_]+$ ]] || die "usage: cua TOOL [JSON] | cua list-tools | cua describe TOOL"
  # A named session keeps element tokens valid across calls; Chromium ignores
  # background X11 input, so actions default to foreground delivery.
  json=$(jq -c --arg session "$CUA_SESSION" --arg tool "$tool" '
    if type != "object" then error("JSON argument must be an object") else . end
    | .session //= $session
    | if ($tool | IN("click", "double_click", "right_click", "type_text", "press_key",
                     "hotkey", "scroll", "drag", "run_actions"))
      then .delivery_mode //= "foreground" else . end' <<<"$json") ||
    die "invalid JSON argument"
  local args=(cua-driver call "$tool" "$json" --socket=/run/user/1000/cua-driver.sock)
  case $tool in
    get_window_state | get_desktop_state | zoom)
      [ "$tool" = zoom ] && ext=jpg
      file=$(step_name "cua-$tool" "$ext")
      args+=(--screenshot-out-file "/job/out/steps/$file")
      ;;
  esac
  remote "${args[@]}"
  if [ -n "$file" ] && [ -f "$OUT_DIR/steps/$file" ]; then
    # stderr keeps stdout as plain JSON for jq.
    echo "screenshot: $OUT_DIR/steps/$file" >&2
  fi
}

cmd_start() {
  local dir=$PWD setup="" app_cmd="npm start" timeout_min=60 wait=1
  while [ $# -gt 0 ]; do
    case $1 in
      -C) dir=$2; shift 2 ;;
      --setup) setup=$2; shift 2 ;;
      --cmd) app_cmd=$2; shift 2 ;;
      --timeout) timeout_min=$2; shift 2 ;;
      --no-wait) wait=0; shift ;;
      --slot) REQUESTED_SLOT=$2; shift 2 ;;
      *) die "unknown start option: $1" ;;
    esac
  done
  dir=$(realpath "$dir")
  [ -f "$dir/package.json" ] || die "$dir has no package.json"
  [ -n "$setup" ] || setup=$(default_setup "$dir")

  mkdir -p "$STATE_DIR"
  # Serialize slot selection so concurrent starts never claim the same slot.
  exec 9>"$STATE_DIR/lock"
  flock 9
  [ -f "$KEY" ] || ssh-keygen -q -t ed25519 -N "" -C electron-vm -f "$KEY"
  if [ -n "$REQUESTED_SLOT" ]; then
    use_slot "$REQUESTED_SLOT"
    is_running && die "slot $SLOT is already running; stop it or pick another slot"
  else
    local n
    for n in $(seq "$SLOTS"); do
      if ! slot_running "$n"; then
        use_slot "$n"
        break
      fi
    done
    [ -n "${SLOT:-}" ] || die "all $SLOTS slots are busy ($(running_slots | tr '\n' ' ')); stop one first"
  fi
  mkdir -p "$SLOT_STATE"
  RUN_ID="s$SLOT-$(od -An -tx4 -N4 /dev/urandom | tr -d ' ')"
  echo "$RUN_ID" > "$SLOT_STATE/run-id"

  rm -rf "$JOB_DIR"
  mkdir -p "$JOB_DIR/src" "$OUT_DIR/steps"
  cp "$KEY.pub" "$JOB_DIR/authorized_keys"
  if git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "$dir" ls-files -coz --exclude-standard |
      rsync -a --from0 --ignore-missing-args --files-from=- "$dir/" "$JOB_DIR/src/"
  else
    rsync -a --exclude node_modules --exclude .git "$dir/" "$JOB_DIR/src/"
  fi
  printf 'set -euo pipefail\n%s\n' "$setup" > "$JOB_DIR/setup.sh"
  printf 'set -euo pipefail\n%s\n' "$app_cmd" > "$JOB_DIR/start.sh"
  printf 'run=%s\nsource=%s\nsetup=%s\ncmd=%s\n' "$RUN_ID" "$dir" "$setup" "$app_cmd" > "$OUT_DIR/job.txt"

  # microvm-run keeps its control socket in the working directory. The VM
  # must not inherit the lock descriptor.
  (cd "$SLOT_STATE" && exec setsid timeout --kill-after=30s "${timeout_min}m" \
    "$RUNNER" </dev/null >"$OUT_DIR/vm.log" 2>&1 9>&-) &
  echo $! > "$PID_FILE"
  echo "$SLOT" > "$STATE_DIR/last-slot"
  flock -u 9
  exec 9>&-
  sleep 1
  if ! is_running; then
    tail_log vm
    die "VM failed to start (ports $SSH_PORT/$VNC_PORT in use?)"
  fi
  echo "Run $RUN_ID: VM started in slot $SLOT (pid $(cat "$PID_FILE"), hard timeout ${timeout_min}m)" >&2
  echo "  use:    electron-vm --run $RUN_ID ..." >&2
  echo "  source: $dir" >&2
  echo "  setup:  $setup" >&2
  echo "  start:  $app_cmd" >&2
  if [ "$wait" = 1 ]; then
    cmd_wait
  else
    echo "run=$RUN_ID"
  fi
}

cmd_wait() {
  local timeout_s=900
  while [ $# -gt 0 ]; do
    case $1 in
      --timeout) timeout_s=$2; shift 2 ;;
      *) die "unknown wait option: $1" ;;
    esac
  done
  local deadline=$((SECONDS + timeout_s)) phase=""
  while [ "$SECONDS" -lt "$deadline" ]; do
    if ! is_running; then
      tail_log vm
      die "VM exited"
    fi
    if [ -f "$OUT_DIR/setup-exit" ] && [ "$(cat "$OUT_DIR/setup-exit")" != 0 ]; then
      tail_log setup
      die "setup failed with exit code $(cat "$OUT_DIR/setup-exit")"
    fi
    if [ -f "$OUT_DIR/app-exit" ]; then
      tail_log app
      die "app exited with code $(cat "$OUT_DIR/app-exit") before showing a window"
    fi
    local next
    if [ ! -f "$OUT_DIR/setup-exit" ]; then
      next="booting / running setup"
    else
      next="waiting for a window"
      if [ -n "$(remote xdotool search --onlyvisible --name . 2>/dev/null)" ] &&
        remote test -S /run/user/1000/cua-driver.sock 2>/dev/null; then
        echo "Run $(slot_run_id "$SLOT") ready in slot $SLOT. App window is visible." >&2
        cmd_windows
        if remote electron-vm-cdp targets >/dev/null 2>&1; then
          echo "CDP: available (electron-vm cdp ...)" >&2
        else
          echo "CDP: unavailable; the app was not launched through the npm electron package. Use electron-vm cua ..." >&2
        fi
        shot ready
        echo "run=$(slot_run_id "$SLOT")"
        return 0
      fi
    fi
    if [ "$next" != "$phase" ]; then
      phase=$next
      echo "... $phase" >&2
    fi
    sleep 2
  done
  tail_log setup 20
  tail_log app 20
  die "timed out after ${timeout_s}s ($phase)"
}

cmd_status() {
  if [ -z "$REQUESTED_SLOT" ] && [ -z "$REQUESTED_RUN" ]; then
    local n source
    for n in $(seq "$SLOTS"); do
      use_slot "$n"
      source=$(sed -n 's/^source=//p' "$OUT_DIR/job.txt" 2>/dev/null || true)
      if is_running; then
        echo "slot $n: running  $(slot_run_id "$n")  ${source:-}"
      else
        echo "slot $n: free     ${source:+(last: $source)}"
      fi
    done
    return
  fi
  resolve_slot 0
  echo "slot=$SLOT"
  if is_running; then
    echo "vm: running (pid $(cat "$PID_FILE"))"
  else
    echo "vm: stopped"
  fi
  [ -f "$OUT_DIR/job.txt" ] && cat "$OUT_DIR/job.txt"
  [ -f "$OUT_DIR/setup-exit" ] && echo "setup-exit=$(cat "$OUT_DIR/setup-exit")"
  [ -f "$OUT_DIR/app-exit" ] && echo "app-exit=$(cat "$OUT_DIR/app-exit")"
  echo "out=$OUT_DIR"
  echo "vnc=127.0.0.1:$VNC_PORT"
}

cmd_stop() {
  if [ "${1:-}" = --all ]; then
    local n
    for n in $(running_slots); do
      use_slot "$n"
      stop_slot
    done
    return
  fi
  resolve_slot 0
  stop_slot
}

stop_slot() {
  if ! is_running; then
    echo "Slot $SLOT is not running. Results: $OUT_DIR" >&2
    return 0
  fi
  local pid
  pid=$(cat "$PID_FILE")
  # ACPI power button over qemu's control socket in the slot state dir; the
  # guest needs no privileges for a clean shutdown.
  (cd "$SLOT_STATE" && timeout 30 "${RUNNER%/microvm-run}/microvm-shutdown") >/dev/null 2>&1 || true
  for _ in $(seq 5); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 1
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -- "-$pid" 2>/dev/null || kill "$pid"
  fi
  rm -f "$PID_FILE"
  echo "Slot $SLOT stopped. Results: $OUT_DIR" >&2
}

cmd_clean() {
  resolve_slot 0
  is_running && die "slot $SLOT is still running; stop it first"
  rm -rf "$JOB_DIR"
  rm -f "$SLOT_STATE/run-id"
  echo "Removed $JOB_DIR" >&2
}

cmd_windows() {
  # shellcheck disable=SC2016 # expanded by the guest shell
  ssh_vm 'export DISPLAY=:0
    for w in $(xdotool search --onlyvisible --name . 2>/dev/null); do
      eval "$(xdotool getwindowgeometry --shell "$w")"
      printf "%s\t%sx%s+%s+%s\t%s\n" "$w" "$WIDTH" "$HEIGHT" "$X" "$Y" "$(xdotool getwindowname "$w")"
    done'
}

main() {
  while [ $# -gt 0 ]; do
    case $1 in
      --slot)
        [ $# -ge 2 ] || die "--slot needs a number"
        REQUESTED_SLOT=$2
        shift 2
        ;;
      --run)
        [ $# -ge 2 ] || die "--run needs an id"
        REQUESTED_RUN=$2
        shift 2
        ;;
      *) break ;;
    esac
  done
  local cmd=${1:-help}
  [ $# -gt 0 ] && shift
  case $cmd in
    start) cmd_start "$@" ;;
    wait)
      resolve_slot 1
      cmd_wait "$@"
      ;;
    status) cmd_status ;;
    stop) cmd_stop "$@" ;;
    clean) cmd_clean ;;
    screenshot)
      resolve_slot 1
      shot "${1:-shot}"
      ;;
    cdp)
      resolve_slot 1
      cmd_cdp "$@"
      ;;
    cua)
      resolve_slot 1
      cmd_cua "$@"
      ;;
    windows)
      resolve_slot 1
      cmd_windows
      ;;
    exec)
      resolve_slot 1
      ssh_vm "export DISPLAY=:0 XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus; cd ~/app 2>/dev/null; $*"
      ;;
    logs)
      resolve_slot 0
      local name=app lines=100
      while [ $# -gt 0 ]; do
        case $1 in
          -n) lines=$2; shift 2 ;;
          *) name=$1; shift ;;
        esac
      done
      [ -f "$OUT_DIR/$name.log" ] || die "no $name.log in $OUT_DIR"
      tail -n "$lines" "$OUT_DIR/$name.log"
      ;;
    out)
      resolve_slot 0
      echo "$OUT_DIR"
      ;;
    vnc)
      resolve_slot 1
      echo "127.0.0.1:$VNC_PORT (no password; e.g. vncviewer 127.0.0.1::$VNC_PORT)"
      ;;
    help | -h | --help) usage ;;
    *)
      usage >&2
      exit 1
      ;;
  esac
}

main "$@"
