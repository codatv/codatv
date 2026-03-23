#!/usr/bin/env bash
# CodaTV statusline script — captures context %, model, and branch.
# Claude Code calls this after each message with JSON on stdin.

CACHE_DIR="/tmp/codatv-ctx"
mkdir -p "$CACHE_DIR" 2>/dev/null

INPUT=$(cat 2>/dev/null || true)
if [[ -z "$INPUT" ]]; then exit 0; fi

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "default"' 2>/dev/null || echo "default")
CTX_PCT=$(echo "$INPUT" | jq -r '.context_window.used_percentage // 0' 2>/dev/null || echo 0 | cut -d. -f1)
MODEL=$(echo "$INPUT" | jq -r '.model.display_name // "?"' 2>/dev/null | sed 's/ (.*//;s/ /-/' | cut -c1-10)
PROJECT=$(echo "$INPUT" | jq -r '.workspace.project_dir // .workspace.current_dir // ""' 2>/dev/null || echo "")
BRANCH=""
if [[ -n "$PROJECT" ]] && command -v git &>/dev/null && git -C "$PROJECT" rev-parse --git-dir &>/dev/null 2>&1; then
  BRANCH=$(git -C "$PROJECT" branch --show-current 2>/dev/null || echo "")
fi

printf '{"pct":%s,"model":"%s","branch":"%s"}' \
  "${CTX_PCT%%.*}" "$MODEL" "$BRANCH" \
  > "$CACHE_DIR/$SESSION_ID" 2>/dev/null

exit 0
