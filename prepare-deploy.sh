#!/usr/bin/env bash
set -euo pipefail

# World Quiz — Prepare Deploy Package
# Usage: ./.deploy/prepare-deploy.sh [SPACETIME_PUBLIC_URI]
#
# This script prepares the .deploy/ folder with all artifacts needed for a
# production VPS deployment. It MUST be run from the project root.
#
# What it does:
#   1. Generates TypeScript client bindings from the server module
#      (this also builds server.wasm as a side effect)
#   2. Builds the production frontend with VITE_SPACETIME_URI baked in
#   3. Copies server.wasm into .deploy/
#   4. Copies the built frontend (dist/) into .deploy/dist/
#   5. Copies compiled question data into .deploy/data/
#   6. Copies publisher scripts into .deploy/scripts/
#   7. Verifies the frontend was built for the correct URI
#
# After running this, commit and push from inside .deploy/:
#   cd .deploy
#   git add .
#   git commit -m "deploy: update production artifacts"
#   git push
#
# Environment:
#   SPACETIME_PUBLIC_URI   Public WebSocket URI (default: wss://spacetime.dnas.place)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SPACETIME_PUBLIC_URI="${1:-${SPACETIME_PUBLIC_URI:-wss://spacetime.dnas.place}}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${RED}[!]${NC} $*"; }
info() { echo -e "${YELLOW}[*]${NC} $*"; }

# --- Check we are in the project root ---
if [[ ! -d "$PROJECT_ROOT/server/spacetimedb" ]] || [[ ! -d "$PROJECT_ROOT/client" ]]; then
    warn "This script must be run from the World Quiz project root."
    warn "Expected to find server/spacetimedb/ and client/ directories."
    exit 1
fi

log "Preparing deploy package..."
info "Project root: $PROJECT_ROOT"
info "Public URI:   $SPACETIME_PUBLIC_URI"
echo ""

# --- Check prerequisites ---
for cmd in spacetime node npm; do
    if ! command -v "$cmd" &>/dev/null; then
        warn "Missing prerequisite: $cmd"
        exit 1
    fi
done

log "Prerequisites OK (spacetime, node, npm)"

# --- Step 1: Generate bindings (also builds wasm) ---
log "Step 1/4: Generating TypeScript bindings and building server.wasm..."
cd "$PROJECT_ROOT"
spacetime generate --lang typescript --out-dir ./client/src/module_bindings --module-path ./server/spacetimedb

WASM_SOURCE="$PROJECT_ROOT/server/spacetimedb/target/wasm32-unknown-unknown/release/server.wasm"
if [[ ! -f "$WASM_SOURCE" ]]; then
    warn "server.wasm not found at expected path: $WASM_SOURCE"
    exit 1
fi

cp "$WASM_SOURCE" "$PROJECT_ROOT/.deploy/server.wasm"
log "Copied server.wasm ($(du -sh "$PROJECT_ROOT/.deploy/server.wasm" | cut -f1))"

# --- Step 2: Build production frontend ---
log "Step 2/4: Building production frontend..."
cd "$PROJECT_ROOT/client"

if [[ ! -d "node_modules" ]]; then
    log "Installing npm dependencies..."
    npm install --no-bin-links
fi

VITE_SPACETIME_URI="$SPACETIME_PUBLIC_URI" npm run build
log "Frontend built successfully."

# --- Step 3: Copy frontend to deploy ---
log "Step 3/4: Copying frontend to .deploy/dist/..."

# Clean stale hashed assets (keep flags/ and other static dirs)
rm -f "$PROJECT_ROOT/.deploy/dist/assets/index-"*.js
rm -f "$PROJECT_ROOT/.deploy/dist/assets/index-"*.css

# Copy new build
cp -r "$PROJECT_ROOT/client/dist/"* "$PROJECT_ROOT/.deploy/dist/"
log "Copied frontend ($(du -sh "$PROJECT_ROOT/.deploy/dist" | cut -f1))."

# --- Step 4: Copy data and scripts ---
log "Step 4/4: Copying question data and publisher scripts..."

# Ensure directories exist
mkdir -p "$PROJECT_ROOT/.deploy/data/questions"
mkdir -p "$PROJECT_ROOT/.deploy/scripts"

# Copy question data and manifest
rsync -a --delete "$PROJECT_ROOT/data/questions/" "$PROJECT_ROOT/.deploy/data/questions/"
cp "$PROJECT_ROOT/data/manifest.json" "$PROJECT_ROOT/.deploy/data/manifest.json"

# Copy publisher scripts
cp "$PROJECT_ROOT/scripts/publish.js" "$PROJECT_ROOT/.deploy/scripts/publish.js"
cp "$PROJECT_ROOT/scripts/package.json" "$PROJECT_ROOT/.deploy/scripts/package.json"
cp "$PROJECT_ROOT/scripts/package-lock.json" "$PROJECT_ROOT/.deploy/scripts/package-lock.json"

log "Copied question data and scripts."

# --- Verify frontend URI ---
echo ""
BUILT_URI=$(grep -oP 'wss?://[^"\x27`,;\s]+' "$PROJECT_ROOT/.deploy/dist/assets/index-"*.js 2>/dev/null | head -1 || echo "unknown")
if [[ "$BUILT_URI" != "$SPACETIME_PUBLIC_URI" ]]; then
    warn "Frontend was built for '$BUILT_URI' but expected '$SPACETIME_PUBLIC_URI'."
    warn "This mismatch will cause connection errors in production."
    exit 1
fi
log "Frontend URI verified: $BUILT_URI"

# --- Done ---
echo ""
log "Deploy package prepared successfully!"
echo ""
echo "  server.wasm:   $PROJECT_ROOT/.deploy/server.wasm"
echo "  dist/:          $PROJECT_ROOT/.deploy/dist/"
echo "  data/questions: $PROJECT_ROOT/.deploy/data/questions/"
echo "  scripts/:       $PROJECT_ROOT/.deploy/scripts/"
echo ""
echo "Next steps:"
echo "  cd .deploy"
echo "  git add ."
echo "  git commit -m 'deploy: update production artifacts'"
echo "  git push"
echo ""
echo "Then on your VPS:"
echo "  cd /opt/world-quiz && git pull"
echo "  sudo bash install.sh"
