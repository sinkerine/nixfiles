# notify-lib.sh — shared notification helpers (source this file, do not execute)
# Requires: jq, niri, tmux, notify-send in PATH

# capture_tmux_info
# Reads TMUX_PANE from environment.
# Sets: _NOTIFY_TMUX_PANE, _NOTIFY_TMUX_SESSION, _NOTIFY_TMUX_WINDOW
capture_tmux_info() {
  _NOTIFY_TMUX_PANE="${TMUX_PANE:-}"
  _NOTIFY_TMUX_SESSION=""
  _NOTIFY_TMUX_WINDOW=""
  if [ -n "$_NOTIFY_TMUX_PANE" ]; then
    _NOTIFY_TMUX_SESSION=$(tmux display-message -p -t "$_NOTIFY_TMUX_PANE" '#{session_name}')
    _NOTIFY_TMUX_WINDOW=$(tmux display-message -p -t "$_NOTIFY_TMUX_PANE" '#{window_index}')
  fi
}

# find_niri_window
# Walks process tree to find ancestor Niri window.
# tmux server daemonizes (re-parents to PID 1), so start from tmux client PID.
# Sets: _NOTIFY_NIRI_ID
find_niri_window() {
  _NOTIFY_NIRI_ID=""
  local clients pid found ppid
  clients=""
  pid=""
  if clients=$(niri msg --json windows 2>/dev/null) && [ -n "$clients" ]; then
    if [ -n "${TMUX:-}" ]; then
      pid=$(tmux display-message -p "#{client_pid}" 2>/dev/null | tr -d ' ' || true)
    fi
    pid="${pid:-$$}"
    while [ "$pid" -gt 1 ]; do
      found=$(printf '%s' "$clients" | jq -r --argjson pid "$pid" \
        '.[] | select(.pid == $pid) | .id' 2>/dev/null | head -1)
      if [ -n "$found" ]; then
        _NOTIFY_NIRI_ID="$found"
        break
      fi
      ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
      pid="$ppid"
      [ -z "$pid" ] && break
    done
    # Fallback: active window at hook time.
    if [ -z "$_NOTIFY_NIRI_ID" ]; then
      _NOTIFY_NIRI_ID=$(printf '%s' "$clients" | jq -r '.[] | select(.is_focused) | .id' 2>/dev/null || true)
    fi
  fi
}

# send_notify APP_NAME TITLE MESSAGE
# Uses globals: _NOTIFY_NIRI_ID, _NOTIFY_TMUX_PANE, _NOTIFY_TMUX_SESSION, _NOTIFY_TMUX_WINDOW
# Sends desktop notification; if Focus action clicked, switches to originating window/pane.
send_notify() {
  local app_name="$1" title="$2" message="$3"
  local window_id="$_NOTIFY_NIRI_ID"
  local tmux_pane="$_NOTIFY_TMUX_PANE"
  local tmux_session="$_NOTIFY_TMUX_SESSION"
  local tmux_window="$_NOTIFY_TMUX_WINDOW"
  (
    local action
    if [ -n "$window_id" ]; then
      action=$(
        notify-send --wait \
          --app-name="$app_name" \
          --action=default=Focus \
          "$title" "$message"
      )
    else
      action=$(
        notify-send --wait \
          --app-name="$app_name" \
          "$title" "$message"
      )
    fi
    if [ "$action" = "default" ] && [ -n "$window_id" ]; then
      niri msg action focus-window --id "$window_id" 2>/dev/null
      if [ -n "$tmux_pane" ]; then
        tmux switch-client -t "$tmux_session"
        tmux select-window -t "${tmux_session}:${tmux_window}"
        tmux select-pane -t "$tmux_pane"
      fi
    fi
  ) &
  disown
}
