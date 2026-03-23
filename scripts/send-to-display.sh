#!/usr/bin/env bash
set -euo pipefail

# CodaTV — Hook handler for the CodaTV Claude Code plugin.
# Sends real-time tool invocation events over USB serial to an ESP32 display.
#
# Usage: echo '<hook_json>' | send-to-display.sh <event_type>

EVENT="${1:-}"
STATE_FILE="/tmp/codatv-state.json"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Graceful failure: never block Claude Code
# ---------------------------------------------------------------------------
bail() { exit 0; }
trap bail ERR

if ! command -v jq &>/dev/null; then exit 0; fi

# ---------------------------------------------------------------------------
# User configuration via ~/.claude/codatv.local.md (YAML frontmatter)
# ---------------------------------------------------------------------------
CONFIG_FILE="$HOME/.claude/codatv.local.md"

cfg_get() {
  local key="$1" default="$2"
  if [[ -f "$CONFIG_FILE" ]]; then
    local val=$(sed -n '/^---$/,/^---$/p' "$CONFIG_FILE" | grep "^${key}:" | head -1 | sed 's/^[^:]*: *//' | tr -d '"' | tr -d "'" | xargs)
    echo "${val:-$default}"
  else
    echo "$default"
  fi
}

MAX_SLOTS=$(cfg_get max_agents 4)
MAX_INSTANCES=$(cfg_get max_instances 3)
INSTANCE_LINES=$(cfg_get instance_lines 2)
SHOW_CLOCK=$(cfg_get show_clock true)
SHOW_DIFF=$(cfg_get show_diff true)
SHOW_CONTEXT_PCT=$(cfg_get show_context_pct true)
SERIAL_PORT_OVERRIDE=$(cfg_get serial_port "")

# ---------------------------------------------------------------------------
# Detect serial port
# ---------------------------------------------------------------------------
PORT=""
if [[ -n "$SERIAL_PORT_OVERRIDE" && -e "$SERIAL_PORT_OVERRIDE" ]]; then
  PORT="$SERIAL_PORT_OVERRIDE"
elif [[ -x "$SCRIPT_DIR/detect-port.sh" ]]; then
  PORT=$("$SCRIPT_DIR/detect-port.sh" 2>/dev/null || true)
fi
if [[ -z "$PORT" || ! -e "$PORT" ]]; then exit 0; fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
send_cmd() {
  echo "$1" > "$PORT" 2>/dev/null || true
}

init_state() {
  local slots="[]"
  for ((i = 0; i < MAX_SLOTS; i++)); do
    slots=$(echo "$slots" | jq --arg i "$i" \
      '. + [{"index": ($i | tonumber), "name": "", "status": "I", "detail": "", "instance": 0}]' 2>/dev/null)
  done
  echo "{\"next_slot\": 0, \"next_instance\": 0, \"sessions\": {}, \"slots\": $slots}" > "$STATE_FILE"
}

read_state() {
  if [[ ! -f "$STATE_FILE" ]]; then init_state; fi
  cat "$STATE_FILE"
}

write_state() {
  echo "$1" > "$STATE_FILE"
}

get_diff_stats() {
  if [[ "$SHOW_DIFF" != "true" ]]; then echo "0,0"; return; fi
  local cwd="${HOOK_CWD:-$(pwd)}"
  if command -v git &>/dev/null && git -C "$cwd" rev-parse --git-dir &>/dev/null 2>&1; then
    local stat=$(git -C "$cwd" diff HEAD --shortstat 2>/dev/null || echo "")
    local add=$(echo "$stat" | grep -oE '[0-9]+ insertion' | grep -oE '[0-9]+' || echo 0)
    local del=$(echo "$stat" | grep -oE '[0-9]+ deletion' | grep -oE '[0-9]+' || echo 0)
    echo "${add:-0},${del:-0}"
  else
    echo "-1,-1"
  fi
}

resolve_instance() {
  local state="$1"
  local instance=$(echo "$state" | jq -r --arg sid "$session_id" '.sessions[$sid] // empty' 2>/dev/null || echo "")
  if [[ -z "$instance" ]]; then
    instance=$(echo "$state" | jq '.next_instance % 8' 2>/dev/null || echo 0)
    state=$(echo "$state" | jq \
      --arg sid "$session_id" \
      --argjson inst "$instance" \
      '.sessions[$sid] = $inst | .next_instance = (.next_instance + 1)' 2>/dev/null)
    write_state "$state"
  fi
  echo "$instance"
}

send_instance_update() {
  local inst="${1:-0}"
  local status="${2:-W}"
  local state=$(read_state)

  local tc=$(echo "$state" | jq --argjson i "$inst" \
    '[.slots[] | select(.instance == $i and .name != "")] | length' 2>/dev/null || echo 0)

  local diff=$(get_diff_stats)
  local add=$(echo "$diff" | cut -d, -f1)
  local del=$(echo "$diff" | cut -d, -f2)

  local label=$(basename "${HOOK_CWD:-$(pwd)}" 2>/dev/null | cut -c1-18)

  # Read session info from statusline cache
  local ctx=0 model="" branch=""
  local ctx_file="/tmp/codatv-ctx/${session_id}"
  local cache=""
  if [[ -f "$ctx_file" ]]; then
    cache=$(cat "$ctx_file" 2>/dev/null || echo "")
  else
    local latest=$(ls -t /tmp/codatv-ctx/ 2>/dev/null | head -1)
    if [[ -n "$latest" ]]; then
      cache=$(cat "/tmp/codatv-ctx/$latest" 2>/dev/null || echo "")
    fi
  fi
  if [[ -n "$cache" ]] && echo "$cache" | jq empty 2>/dev/null; then
    ctx=$(echo "$cache" | jq -r '.pct // 0' 2>/dev/null || echo 0)
    model=$(echo "$cache" | jq -r '.model // ""' 2>/dev/null || echo "")
    branch=$(echo "$cache" | jq -r '.branch // ""' 2>/dev/null || echo "")
  fi
  model="${model//,/}"
  branch="${branch//,/}"

  if [[ "$SHOW_CONTEXT_PCT" != "true" ]]; then ctx=0; fi

  send_cmd "I,${inst},${status},${tc},${ctx},${add},${del},${label},${branch},${model}"
}

# ---------------------------------------------------------------------------
# Read hook JSON from stdin
# ---------------------------------------------------------------------------
HOOK_JSON=""
if [[ "$EVENT" == "session_start" || "$EVENT" == "pre_tool" || "$EVENT" == "post_tool" || "$EVENT" == "stop" || "$EVENT" == "pre_compact" || "$EVENT" == "post_compact" || "$EVENT" == "session_end" ]]; then
  HOOK_JSON=$(cat 2>/dev/null || true)
fi

session_id=$(echo "$HOOK_JSON" | jq -r '.session_id // "default"' 2>/dev/null || echo "default")
HOOK_CWD=$(echo "$HOOK_JSON" | jq -r '.cwd // ""' 2>/dev/null || echo "")

# ---------------------------------------------------------------------------
# Event handling
# ---------------------------------------------------------------------------
case "$EVENT" in

  session_start)
    if [[ "$SHOW_CLOCK" == "true" ]]; then
      send_cmd "T,$(date +%H:%M:%S)"
    fi
    send_cmd "CFG,${MAX_SLOTS},${MAX_INSTANCES},${INSTANCE_LINES},$([ "$SHOW_CLOCK" == "true" ] && echo 1 || echo 0)"
    state=$(read_state)
    instance=$(resolve_instance "$state")
    send_instance_update "$instance" "W"
    ;;

  pre_tool)
    tool_name=$(echo "$HOOK_JSON" | jq -r '.tool_name // "unknown"' 2>/dev/null || echo "unknown")
    tool_input=$(echo "$HOOK_JSON" | jq -r '
      .tool_input |
      if type == "string" then .[0:28]
      else (.command // .file_path // .pattern // .query // .description // .prompt // .skill // (to_entries | first | .value | tostring))[0:28]
      end' 2>/dev/null || echo "")
    tool_name="${tool_name//,/;}"
    tool_input="${tool_input//,/;}"

    state=$(read_state)
    instance=$(resolve_instance "$state")
    state=$(read_state)
    next_slot=$(echo "$state" | jq '.next_slot' 2>/dev/null || echo 0)

    state=$(echo "$state" | jq \
      --argjson idx "$next_slot" \
      --arg name "$tool_name" \
      --arg detail "$tool_input" \
      --argjson inst "$instance" \
      '.slots[$idx] = {"index": $idx, "name": $name, "status": "R", "detail": $detail, "instance": $inst}' 2>/dev/null)

    new_next=$(( (next_slot + 1) % MAX_SLOTS ))
    state=$(echo "$state" | jq --argjson ns "$new_next" '.next_slot = $ns' 2>/dev/null)

    write_state "$state"
    if [[ "$SHOW_CLOCK" == "true" ]]; then
      send_cmd "T,$(date +%H:%M:%S)"
    fi
    send_cmd "A,${next_slot},${tool_name},R,${instance},${tool_input}"
    send_instance_update "$instance" "W"
    ;;

  post_tool)
    tool_name=$(echo "$HOOK_JSON" | jq -r '.tool_name // "unknown"' 2>/dev/null || echo "unknown")
    tool_name="${tool_name//,/;}"

    state=$(read_state)

    slot_idx=$(echo "$state" | jq -r \
      --arg name "$tool_name" \
      '[.slots[] | select(.name == $name and .status == "R")] | last | .index // empty' 2>/dev/null || echo "")

    if [[ -n "$slot_idx" ]]; then
      detail=$(echo "$state" | jq -r --argjson idx "$slot_idx" '.slots[$idx].detail // ""' 2>/dev/null || echo "")
      instance=$(echo "$state" | jq -r --argjson idx "$slot_idx" '.slots[$idx].instance // 0' 2>/dev/null || echo 0)
      state=$(echo "$state" | jq --argjson idx "$slot_idx" '.slots[$idx].status = "I"' 2>/dev/null)
      write_state "$state"
      send_cmd "A,${slot_idx},${tool_name},I,${instance},${detail}"
      send_instance_update "$instance" "W"
    fi
    ;;

  stop)
    state=$(read_state)
    instance=$(resolve_instance "$state")
    state=$(read_state)

    slots_to_idle=$(echo "$state" | jq -r --argjson inst "$instance" \
      '[.slots[] | select(.status == "R" and .instance == $inst) | .index] | .[]' 2>/dev/null || true)

    for idx in $slots_to_idle; do
      name=$(echo "$state" | jq -r --argjson i "$idx" '.slots[$i].name // ""' 2>/dev/null || echo "")
      detail=$(echo "$state" | jq -r --argjson i "$idx" '.slots[$i].detail // ""' 2>/dev/null || echo "")
      state=$(echo "$state" | jq --argjson i "$idx" '.slots[$i].status = "I"' 2>/dev/null)
      send_cmd "A,${idx},${name},I,${instance},${detail}"
    done

    write_state "$state"
    send_instance_update "$instance" "A"
    ;;

  session_end)
    state=$(read_state)
    instance=$(echo "$state" | jq -r --arg sid "$session_id" '.sessions[$sid] // empty' 2>/dev/null || echo "")
    if [[ -n "$instance" ]]; then
      for idx in $(echo "$state" | jq -r --argjson inst "$instance" \
        '[.slots[] | select(.instance == $inst and .name != "") | .index] | .[]' 2>/dev/null || true); do
        state=$(echo "$state" | jq --argjson i "$idx" \
          '.slots[$i] = {"index": $i, "name": "", "status": "I", "detail": "", "instance": 0}' 2>/dev/null)
        send_cmd "A,${idx},,I,${instance},"
      done
      state=$(echo "$state" | jq --arg sid "$session_id" 'del(.sessions[$sid])' 2>/dev/null)
      write_state "$state"
      send_cmd "D,${instance}"
    fi
    ;;

  pre_compact|post_compact)
    state=$(read_state)
    instance=$(resolve_instance "$state")
    send_instance_update "$instance" "W"
    ;;

  *)
    ;;
esac

exit 0
