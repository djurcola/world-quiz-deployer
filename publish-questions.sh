#!/usr/bin/env bash
set -euo pipefail

# World Quiz — Question Publisher
# Usage: ./publish-questions.sh [--theme <theme>]
#
# Publishes compiled question JSONs to the local SpacetimeDB instance.
# Must be run AFTER the module has been published (so the admin identity
# and SyncState table exist).
#
# Environment:
#   SERVICE_USER    Linux user that owns the SpacetimeDB data (default: $SUDO_USER or $(whoami))
#   SPACETIME_PORT  Local SpacetimeDB port (default: 3080)

APP_DIR="/opt/world-quiz"
SERVICE_USER="${SERVICE_USER:-${SUDO_USER:-$(whoami)}}"
SPACETIME_PORT="${SPACETIME_PORT:-3080}"
LOCAL_SERVER_URL="ws://127.0.0.1:${SPACETIME_PORT}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${RED}[!]${NC} $*"; }
info() { echo -e "${YELLOW}[*]${NC} $*"; }

# --- Check Node.js ---
if ! command -v node &>/dev/null; then
    warn "Node.js is not installed. It is required to publish questions."
    warn "Install it with:"
    warn "  curl -fsSL https://deb.nodesource.com/setup_20.x | bash -"
    warn "  apt-get install -y nodejs"
    exit 1
fi

NODE_VERSION=$(node --version | sed 's/v//')
log "Node.js version: ${NODE_VERSION}"

if ! command -v npm &>/dev/null; then
    warn "npm is not installed. Please install Node.js 20+ (which includes npm)."
    exit 1
fi

# --- Check token ---
TOKEN_PATH="/home/${SERVICE_USER}/.config/spacetime/cli.toml"
if [[ ! -f "${TOKEN_PATH}" ]]; then
    warn "No SpacetimeDB token found at ${TOKEN_PATH}"
    warn "Please run: spacetime login --server-issued-login local"
    exit 1
fi

# --- Install npm dependencies ---
SCRIPTS_DIR="${APP_DIR}/scripts"
cd "${SCRIPTS_DIR}"

if [[ ! -d "node_modules" ]]; then
    log "Installing publisher dependencies..."
    npm install --production
else
    log "Publisher dependencies already installed."
fi

# --- Publish questions ---
log "Publishing questions to ${LOCAL_SERVER_URL} ..."

# Run as the service user so the token is found in the correct home directory
export HOME="/home/${SERVICE_USER}"
export SPACETIMEDB_TOKEN=""

# Extract token from cli.toml for the environment variable
if grep -q 'spacetimedb_token' "${TOKEN_PATH}"; then
    export SPACETIMEDB_TOKEN=$(grep 'spacetimedb_token' "${TOKEN_PATH}" | sed 's/.*= *"\(.*\)".*/\1/')
fi

node "${SCRIPTS_DIR}/publish.js" --server "${LOCAL_SERVER_URL}" --db-name world-quiz "$@"

log "Question publishing complete!"
