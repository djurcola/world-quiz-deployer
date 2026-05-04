#!/bin/bash
set -euo pipefail

# Start SpacetimeDB local server on port 3080 for World Quiz

SPACETIME_PORT=3080
LISTEN_ADDR="0.0.0.0:${SPACETIME_PORT}"

echo "Starting SpacetimeDB on $LISTEN_ADDR..."

# Find spacetimedb-cli
if command -v spacetimedb-cli &> /dev/null; then
    SPACETIME_CMD="spacetimedb-cli"
elif [ -x "$HOME/.local/share/spacetime/bin/2.1.0/spacetimedb-cli" ]; then
    SPACETIME_CMD="$HOME/.local/share/spacetime/bin/2.1.0/spacetimedb-cli"
else
    echo "Error: spacetimedb-cli not found. Please install SpacetimeDB 2.1.0."
    exit 1
fi

# Check if already running
if pgrep -f "spacetimedb-cli.*$LISTEN_ADDR" > /dev/null 2>&1; then
    echo "SpacetimeDB already running on $LISTEN_ADDR"
    exit 0
fi

# Start in background with setsid so it persists after shell exit
setsid "$SPACETIME_CMD" start --listen-addr "$LISTEN_ADDR" > /tmp/spacetime-3080.log 2>&1 &

echo "SpacetimeDB started on port $SPACETIME_PORT"
echo "Logs: tail -f /tmp/spacetime-3080.log"
echo ""
echo "To publish the module:"
echo "  cd server/spacetimedb && spacetimedb-cli publish world-quiz --server local --no-config -p . -y"
