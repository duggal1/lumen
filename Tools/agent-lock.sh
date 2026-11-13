#!/bin/sh
# Serialises `swift build` / `swift test` across concurrent agent lanes.
# SwiftPM holds one lock on .build, so two lanes must never build at once.
#
# Usage:
#   Tools/agent-lock.sh acquire <lane> [timeout-seconds]
#   Tools/agent-lock.sh release <lane>
#
# A lock whose owning pid is gone is treated as stale and broken, so one
# crashed lane cannot wedge every other lane.
set -eu

LOCK_DIR=".build/agent-lock"
LANE="${2:-unknown}"
TIMEOUT="${3:-5400}"

alive() {
    pid=$1
    [ -n "$pid" ] || return 1
    kill -0 "$pid" 2>/dev/null
}

acquire() {
    deadline=$(( $(date +%s) + TIMEOUT ))
    while ! mkdir "$LOCK_DIR" 2>/dev/null; do
        owner=$(cat "$LOCK_DIR/owner" 2>/dev/null || echo "")
        owner_pid=$(printf '%s' "$owner" | sed -n 's/.*pid=\([0-9]*\).*/\1/p')
        if [ -z "$owner" ] || ! alive "$owner_pid"; then
            rm -rf "$LOCK_DIR"
            continue
        fi
        if [ "$(date +%s)" -ge "$deadline" ]; then
            echo "agent-lock: TIMEOUT waiting for build lock (held by $owner)" >&2
            exit 1
        fi
        sleep 3
    done
    printf '%s pid=%s\n' "$LANE" "$$" > "$LOCK_DIR/owner"
    echo "agent-lock: $LANE acquired the build lock"
}

release() {
    if [ -d "$LOCK_DIR" ]; then
        rm -rf "$LOCK_DIR"
        echo "agent-lock: $LANE released the build lock"
    fi
}

case "${1:-}" in
    acquire) acquire ;;
    release) release ;;
    *) echo "usage: $0 acquire|release <lane> [timeout]" >&2; exit 2 ;;
esac