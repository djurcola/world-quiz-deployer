#!/bin/bash
set -euo pipefail

# World Quiz Deployment Build Script
# Usage: ./deploy/build.sh [spacetime_uri] [db_name]
#
# This script:
# 1. Publishes the Rust SpacetimeDB module to the local server
# 2. Builds the React frontend into static files
#
# Prerequisites:
# - SpacetimeDB CLI 2.1.0 installed and available in PATH
# - Node.js 20+ and npm installed
# - CARGO_TARGET_DIR set (defaults to $HOME/.cargo-target)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

SPACETIME_URI="${1:-ws://localhost:3080}"
DB_NAME="${2:-world-quiz}"

echo "=== World Quiz Build ==="
echo "Project root: $PROJECT_ROOT"
echo "SpacetimeDB URI: $SPACETIME_URI"
echo "Database name: $DB_NAME"
echo ""

# Step 1: Publish Rust module
echo "Step 1: Publishing Rust module to local SpacetimeDB..."
cd "$PROJECT_ROOT/server/spacetimedb"

# Ensure CARGO_TARGET_DIR is set
if [ -z "${CARGO_TARGET_DIR:-}" ]; then
    export CARGO_TARGET_DIR="$HOME/.cargo-target"
    echo "CARGO_TARGET_DIR not set, using default: $CARGO_TARGET_DIR"
fi

# Find SpacetimeDB CLI
if command -v spacetimedb-cli &> /dev/null; then
    SPACETIME_CMD="spacetimedb-cli"
elif command -v spacetime &> /dev/null; then
    SPACETIME_CMD="spacetime"
elif [ -x "$HOME/.local/share/spacetime/bin/2.1.0/spacetimedb-cli" ]; then
    SPACETIME_CMD="$HOME/.local/share/spacetime/bin/2.1.0/spacetimedb-cli"
else
    echo "Error: spacetime CLI not found. Please install SpacetimeDB 2.1.0."
    echo "See: https://spacetimedb.com/docs/deployments/quickstart"
    exit 1
fi

# Publish to local server
$SPACETIME_CMD publish "$DB_NAME" --server local --no-config -p "$PROJECT_ROOT/server/spacetimedb" -y

echo "Module published successfully."
echo ""

# Step 2: Build frontend
echo "Step 2: Building frontend..."
cd "$PROJECT_ROOT/client"

# Find npm
if ! command -v npm &> /dev/null; then
    echo "Error: npm not found. Please install Node.js 20+."
    exit 1
fi

# Install dependencies if needed
if [ ! -d "node_modules" ]; then
    echo "Installing npm dependencies..."
    npm install --no-bin-links
fi

VITE_SPACETIME_URI="$SPACETIME_URI" VITE_DB_NAME="$DB_NAME" npm run build

echo ""
echo "=== Build Complete ==="
echo "Static frontend files: $PROJECT_ROOT/client/dist/"
echo ""
echo "To start the services:"
echo "  SpacetimeDB: ./deploy/start-spacetime.sh"
echo "  Web server:  ./deploy/start-web.sh"
echo ""
echo "Or install systemd services from deploy/*.service"
