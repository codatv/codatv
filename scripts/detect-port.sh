#!/usr/bin/env bash
set -euo pipefail

# Auto-detect ESP32 serial port for claude-monitor
# Prints the detected port path to stdout, exits 1 if not found.

CACHE_FILE="/tmp/claude-monitor-port"
CACHE_MAX_AGE=60

# 1. User override via environment variable
if [[ -n "${CLAUDE_MONITOR_PORT:-}" ]]; then
  if [[ -e "$CLAUDE_MONITOR_PORT" ]]; then
    echo "$CLAUDE_MONITOR_PORT"
    exit 0
  fi
  # User-specified port doesn't exist; fall through to detection
fi

# 2. Check cache (valid for 60 seconds)
if [[ -f "$CACHE_FILE" ]]; then
  cached_port=$(cat "$CACHE_FILE" 2>/dev/null || true)
  if [[ -n "$cached_port" && -e "$cached_port" ]]; then
    # Check file age
    if [[ "$(uname)" == "Darwin" ]]; then
      file_age=$(( $(date +%s) - $(stat -f %m "$CACHE_FILE" 2>/dev/null || echo 0) ))
    else
      file_age=$(( $(date +%s) - $(stat -c %Y "$CACHE_FILE" 2>/dev/null || echo 0) ))
    fi
    if [[ "$file_age" -lt "$CACHE_MAX_AGE" ]]; then
      echo "$cached_port"
      exit 0
    fi
  fi
fi

# 3. Scan for serial ports
detected=""
for pattern in /dev/cu.usbmodem* /dev/ttyUSB* /dev/ttyACM*; do
  for port in $pattern; do
    if [[ -e "$port" ]]; then
      detected="$port"
      break 2
    fi
  done
done

if [[ -z "$detected" ]]; then
  exit 1
fi

# 4. Configure baud rate 115200
if [[ "$(uname)" == "Darwin" ]]; then
  stty -f "$detected" 115200 2>/dev/null || true
else
  stty -F "$detected" 115200 2>/dev/null || true
fi

# 5. Cache and output
echo "$detected" > "$CACHE_FILE"
echo "$detected"
exit 0
