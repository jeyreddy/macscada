#!/usr/bin/env bash
# run.sh — build and launch IndustrialHMI, killing any stale instances first.
# Usage:  ./run.sh
# Alias:  add `alias hmi='cd ~/Downloads/IndustrialHMI && ./run.sh'` to ~/.zshrc

set -euo pipefail
PROJ="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="IndustrialHMI"

# ── 1. Kill every running instance ──────────────────────────────────────────
echo "⏹  Stopping existing ${APP_NAME} processes…"
PIDS=$(pgrep -x "$APP_NAME" 2>/dev/null || true)
if [[ -n "$PIDS" ]]; then
    echo "   Killing PIDs: $PIDS"
    pkill -x "$APP_NAME" 2>/dev/null || true
    sleep 0.4
    # Force-kill anything still alive
    PIDS=$(pgrep -x "$APP_NAME" 2>/dev/null || true)
    [[ -n "$PIDS" ]] && pkill -9 -x "$APP_NAME" 2>/dev/null || true
else
    echo "   No running instances."
fi

# ── 2. Trash any stale .app bundle in the project directory ─────────────────
STALE_APP="$PROJ/${APP_NAME}.app"
if [[ -d "$STALE_APP" ]]; then
    echo "🗑  Moving stale ${APP_NAME}.app to Trash…"
    osascript -e "tell application \"Finder\" to delete POSIX file \"$STALE_APP\"" 2>/dev/null \
        || rm -rf "$STALE_APP"
fi

# ── 3. Build and run ─────────────────────────────────────────────────────────
echo "🔨 Building…"
cd "$PROJ"
swift run
