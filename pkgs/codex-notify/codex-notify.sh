# Support both delivery methods:
#   - notify setting: payload passed as $1 (old Codex format)
#   - hooks.json Stop hook: payload via stdin (new Codex hooks format)
if [ -n "${1:-}" ]; then
  payload="$1"
else
  payload="$(cat)"
fi

# Support both payload schemas:
#   old: { "type": "agent-turn-complete", "last-assistant-message": "..." }
#   new: { "hook_event_name": "Stop", "last_assistant_message": "..." }
event="$(printf '%s' "$payload" | jq -r '.hook_event_name // .type // ""')"
[ "$event" = "Stop" ] || [ "$event" = "agent-turn-complete" ] || exit 0

message="$(printf '%s' "$payload" | jq -r '.last_assistant_message // .["last-assistant-message"] // ""' | cut -c1-180)"
[ -z "$message" ] && exit 0

capture_tmux_info
find_niri_window
send_notify "codex-notify" "Codex" "$message"
