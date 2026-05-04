#!/bin/bash
set -euo pipefail

# Start static file server for World Quiz frontend on port 8060
# This script is intended to be run from within the deploy/ directory.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST_DIR="$SCRIPT_DIR/dist"
WEB_PORT=8060

if [ ! -d "$DIST_DIR" ]; then
    echo "Error: $DIST_DIR not found. Make sure the dist/ folder is present."
    exit 1
fi

echo "Starting static file server on port $WEB_PORT..."
echo "Serving: $DIST_DIR"

# Check if already running
if lsof -Pi :$WEB_PORT -sTCP:LISTEN -t > /dev/null 2>&1; then
    echo "Port $WEB_PORT is already in use."
    exit 1
fi

cd "$DIST_DIR"
python3 -m http.server "$WEB_PORT" > /tmp/world-quiz-web-8060.log 2>&1 &

echo "Web server started on http://localhost:$WEB_PORT"
echo "Logs: tail -f /tmp/world-quiz-web-8060.log"
