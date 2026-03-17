#!/bin/bash
# Claude Code hook script for WezTerm Agent Deck
# Writes agent status to state files that the plugin reads for status detection.
#
# Setup: Add to your Claude Code hooks config (~/.claude/settings.json):
#   {
#     "hooks": {
#       "SessionStart":    [{ "type": "command", "command": "/path/to/claude-code.sh" }],
#       "Stop":            [{ "type": "command", "command": "/path/to/claude-code.sh" }],
#       "UserPromptSubmit":[{ "type": "command", "command": "/path/to/claude-code.sh" }],
#       "PreToolUse":      [{ "type": "command", "command": "/path/to/claude-code.sh" }],
#       "PostToolUse":     [{ "type": "command", "command": "/path/to/claude-code.sh" }],
#       "Notification":    [{ "type": "command", "command": "/path/to/claude-code.sh" }],
#       "SessionEnd":      [{ "type": "command", "command": "/path/to/claude-code.sh" }]
#     }
#   }

set -e

STATE_DIR="${HOME}/.local/state/claude-wezterm"

# Read JSON input from stdin
INPUT=$(cat)

# Parse JSON fields using jq
if ! command -v jq &> /dev/null; then
    exit 0
fi

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
HOOK_EVENT=$(echo "$INPUT" | jq -r '.hook_event_name // empty')
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')
NOTIFICATION_TYPE=$(echo "$INPUT" | jq -r '.notification_type // empty')

# Get pane ID from environment (set by WezTerm)
PANE_ID="${WEZTERM_PANE:-unknown}"

# Exit if we don't have required info
if [[ -z "$SESSION_ID" ]] || [[ -z "$PANE_ID" ]] || [[ "$PANE_ID" == "unknown" ]]; then
    exit 0
fi

# Get workspace name via wezterm CLI
WORKSPACE=$(wezterm cli list --format json 2>/dev/null | jq -r --arg pane "$PANE_ID" '.[] | select(.pane_id == ($pane | tonumber)) | .workspace' 2>/dev/null)
if [[ -z "$WORKSPACE" ]]; then
    WORKSPACE="default"
fi

# Create state directory: workspace/pane_id/session_id
PANE_STATE_DIR="${STATE_DIR}/${WORKSPACE}/${PANE_ID}"
mkdir -p "$PANE_STATE_DIR"

SESSION_STATE_FILE="${PANE_STATE_DIR}/${SESSION_ID}"

# Determine status based on hook event
case "$HOOK_EVENT" in
    "SessionStart")
        echo "idle" > "$SESSION_STATE_FILE"
        ;;
    "UserPromptSubmit")
        echo "working" > "$SESSION_STATE_FILE"
        ;;
    "PreToolUse")
        if [[ "$TOOL_NAME" == "AskUserQuestion" ]]; then
            echo "waiting" > "$SESSION_STATE_FILE"
        fi
        ;;
    "PostToolUse")
        if [[ "$TOOL_NAME" == "AskUserQuestion" ]]; then
            echo "working" > "$SESSION_STATE_FILE"
        fi
        ;;
    "Stop")
        echo "idle" > "$SESSION_STATE_FILE"
        ;;
    "SubagentStop")
        # Subagent stopped - main agent still working
        ;;
    "Notification")
        if [[ "$NOTIFICATION_TYPE" == "idle_prompt" ]]; then
            echo "idle" > "$SESSION_STATE_FILE"
        elif [[ "$NOTIFICATION_TYPE" == "permission_prompt" ]]; then
            echo "waiting" > "$SESSION_STATE_FILE"
        fi
        ;;
    "SessionEnd")
        rm -f "$SESSION_STATE_FILE"
        ;;
esac

# Clean up stale sessions (older than 24 hours)
find "$PANE_STATE_DIR" -type f -mmin +1440 -delete 2>/dev/null || true

exit 0
