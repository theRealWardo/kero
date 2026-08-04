#!/bin/sh
#
# Reports a Claude Code session's state to the Kero sidebar.
#
# Install by pointing Claude Code's hooks at this script with the event name as
# the argument; see the "Agent activity in the sidebar" section of README.md.
#
# Runs on every tool call, so it stays cheap: no jq, no python, one append. It
# is silent and exits 0 everywhere — a hook that fails must never interrupt the
# agent it is reporting on, and a terminal outside Kero has nothing to report to.
#
# The state Kero shows is deliberately a short fixed vocabulary rather than the
# agent's own prose: these strings have to read well in a 220pt sidebar row.

set -u

# Outside a Kero pane there is no session to attribute this to. Kero exports
# both variables into every terminal it opens, and they are inherited by every
# descendant, so an agent's hook subprocess sees them without any setup.
[ -n "${KERO_SESSION_ID:-}" ] || exit 0
[ -n "${KERO_STATE_DIR:-}" ] || exit 0
[ -d "$KERO_STATE_DIR" ] || exit 0

event="${1:-}"
[ -n "$event" ] || exit 0

file="$KERO_STATE_DIR/$KERO_SESSION_ID.jsonl"

# Kero compacts this file as it grows. This bound is what keeps a runaway agent
# from filling the disk in between compactions.
if [ -f "$file" ]; then
    size=$(stat -f%z "$file" 2>/dev/null || echo 0)
    [ "$size" -lt 262144 ] || exit 0
fi

# The payload can carry a whole tool input, and none of it is needed beyond the
# first few fields. Bound the read rather than holding a large argument.
payload=$(head -c 8192 | tr -d '\n\r')

# Pulls one flat string field out of the payload. Values reaching the sidebar
# are sanitized below and again in Kero, so this only has to be approximately
# right — a miss yields an empty string and a generic label.
field() {
    printf '%s' "$payload" |
        sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" |
        head -n 1
}

# Tool names are identifiers (including MCP's server__tool form). Anything else
# is dropped rather than escaped, which keeps the appended line valid JSON
# without this script needing a JSON encoder.
safe_tool() {
    printf '%s' "$1" | tr -cd 'A-Za-z0-9_.-' | cut -c1-32
}

state=""
text=""

case "$event" in
    PermissionRequest)
        # The agent is blocked asking to run something. This is the event that
        # matters most, and it names the tool structurally — no prose parsing.
        tool=$(safe_tool "$(field tool_name)")
        state="pending"
        if [ -n "$tool" ]; then
            text="Permission to use $tool"
        else
            text="Permission needed"
        fi
        ;;
    Notification)
        # notification_type is a closed set, so map it rather than reading the
        # human-facing message.
        case "$(field notification_type)" in
            worker_permission_prompt)
                state="pending"
                text="Permission needed"
                ;;
            agent_needs_input|idle_prompt)
                state="pending"
                text="Waiting for input"
                ;;
            agent_completed)
                state="done"
                text="Done"
                ;;
            *)
                exit 0
                ;;
        esac
        ;;
    PreToolUse)
        tool=$(safe_tool "$(field tool_name)")
        state="working"
        if [ -n "$tool" ]; then
            text="Running $tool"
        else
            text="Working"
        fi
        ;;
    UserPromptSubmit)
        state="working"
        text="Working"
        ;;
    Stop)
        state="done"
        text="Done"
        ;;
    SessionEnd)
        state="clear"
        ;;
    *)
        exit 0
        ;;
esac

# One line, one write. O_APPEND makes a write this small atomic against the
# other hooks of a parallel agent, so no locking is needed.
if [ -n "$text" ]; then
    printf '{"ts":%s,"event":"%s","text":"%s"}\n' \
        "$(date +%s)" "$state" "$text" >>"$file" 2>/dev/null
else
    printf '{"ts":%s,"event":"%s"}\n' \
        "$(date +%s)" "$state" >>"$file" 2>/dev/null
fi

exit 0
