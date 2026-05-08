#!/usr/bin/env bash
set -euo pipefail

# World Quiz — One-Command VPS Deployment
# Usage: sudo bash install.sh [SPACETIME_PUBLIC_URI]
#
# This script installs SpacetimeDB, publishes the pre-built module,
# loads questions via publish-questions.sh, creates systemd services,
# and starts everything.
# Safe to re-run on an existing deployment — it will update files and
# restart services WITHOUT clearing the database.
#
# To update the module code while preserving player data and rooms:
#   sudo bash install.sh --update
#
# To force a fresh install (wipe database):
#   sudo bash install.sh --clear-database
#
# Environment variables:
#   SPACETIME_PUBLIC_URI   The public WebSocket URL clients connect to
#                          (default: wss://spacetime.dnas.place)
#   SPACETIME_PORT         Local port SpacetimeDB listens on (default: 3080)
#   WEB_PORT               Local port for static file server (default: 8060)
#   SERVICE_USER           Linux user to run services as (default: $SUDO_USER)

APP_DIR="/opt/world-quiz"
SPACETIME_VERSION="2.1.0"
SERVICE_USER="${SERVICE_USER:-${SUDO_USER:-$(whoami)}}"
SPACETIME_PORT="${SPACETIME_PORT:-3080}"
WEB_PORT="${WEB_PORT:-8060}"
CLEAR_DATABASE="${CLEAR_DATABASE:-false}"
UPDATE_MODULE="${UPDATE_MODULE:-false}"

# Parse arguments: first non-flag positional arg is the public URI
SPACETIME_PUBLIC_URI="${SPACETIME_PUBLIC_URI:-wss://spacetime.dnas.place}"
for arg in "$@"; do
    if [[ "$arg" == "--clear-database" ]]; then
        CLEAR_DATABASE="true"
    elif [[ "$arg" == "--update" ]]; then
        UPDATE_MODULE="true"
    elif [[ "$arg" != --* ]]; then
        SPACETIME_PUBLIC_URI="$arg"
    fi
done

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${RED}[!]${NC} $*"; }
info() { echo -e "${YELLOW}[*]${NC} $*"; }

# --- Check root ---
if [[ $EUID -ne 0 ]]; then
    warn "This script must be run as root (sudo)."
    exit 1
fi

log "Deploying World Quiz to target machine..."
info "SpacetimeDB public URI: ${SPACETIME_PUBLIC_URI}"
info "SpacetimeDB local port: ${SPACETIME_PORT}"
info "Web server local port:  ${WEB_PORT}"

# --- 0. Install prerequisites ---
for cmd in curl git python3 systemctl rsync openssl node npm; do
    if [[ "$cmd" == "node" || "$cmd" == "npm" ]]; then
        # Node.js is only needed for publishing questions, not critical for install
        if ! command -v "$cmd" &>/dev/null; then
            warn "${cmd} is not installed. It is required to publish questions after deployment."
            warn "Install Node.js 20+ before running publish-questions.sh."
        fi
        continue
    fi
    if ! command -v "$cmd" &>/dev/null; then
        log "Installing missing prerequisite: ${cmd}..."
        if command -v apt-get &>/dev/null; then
            apt-get update -qq && apt-get install -y -qq "$cmd"
        elif command -v dnf &>/dev/null; then
            dnf install -y "$cmd"
        elif command -v pacman &>/dev/null; then
            pacman -S --noconfirm "$cmd"
        else
            warn "Could not install ${cmd}. Please install it manually."
            exit 1
        fi
    fi
done

# --- 1. Install SpacetimeDB ---
SPACETIME_BIN="/home/${SERVICE_USER}/.local/share/spacetime/bin/${SPACETIME_VERSION}/spacetimedb-standalone"
SPACETIME_CLI="/home/${SERVICE_USER}/.local/share/spacetime/bin/${SPACETIME_VERSION}/spacetimedb-cli"

if [[ -x "$SPACETIME_BIN" ]]; then
    log "SpacetimeDB ${SPACETIME_VERSION} already installed at ${SPACETIME_BIN}"
else
    log "Installing SpacetimeDB ${SPACETIME_VERSION}..."
    ARCH="x86_64-unknown-linux-gnu"
    URL="https://github.com/clockworklabs/SpacetimeDB/releases/download/v${SPACETIME_VERSION}/spacetime-${ARCH}.tar.gz"
    INSTALL_DIR="/home/${SERVICE_USER}/.local/share/spacetime/bin/${SPACETIME_VERSION}"
    mkdir -p "${INSTALL_DIR}"

    log "Downloading from ${URL}..."
    curl -sSL "${URL}" | tar xz -C "${INSTALL_DIR}"
    chmod +x "${INSTALL_DIR}/spacetimedb-cli" "${INSTALL_DIR}/spacetimedb-standalone"
    chown -R "${SERVICE_USER}:${SERVICE_USER}" "/home/${SERVICE_USER}/.local/share/spacetime"
fi

# Ensure SpacetimeDB data directory and JWT keys exist
SPACETIME_DATA_DIR="/home/${SERVICE_USER}/.local/share/spacetime/data"
SPACETIME_JWT_DIR="${SPACETIME_DATA_DIR}/jwt"
mkdir -p "${SPACETIME_JWT_DIR}"

if [[ ! -f "${SPACETIME_JWT_DIR}/id_ecdsa" ]]; then
    log "Generating JWT key pair..."
    openssl ecparam -genkey -name prime256v1 -noout -out "${SPACETIME_JWT_DIR}/id_ecdsa.legacy"
    openssl ec -in "${SPACETIME_JWT_DIR}/id_ecdsa.legacy" -pubout -out "${SPACETIME_JWT_DIR}/id_ecdsa.pub"
    # Convert private key to PKCS#8 format (required by SpacetimeDB Rust libraries)
    openssl pkcs8 -topk8 -nocrypt -in "${SPACETIME_JWT_DIR}/id_ecdsa.legacy" -out "${SPACETIME_JWT_DIR}/id_ecdsa"
    rm -f "${SPACETIME_JWT_DIR}/id_ecdsa.legacy"
    chown -R "${SERVICE_USER}:${SERVICE_USER}" "${SPACETIME_JWT_DIR}"
    log "JWT keys generated and converted to PKCS#8 format."
else
    # Ensure existing key is in PKCS#8 format (check for SEC1 header)
    if openssl ec -in "${SPACETIME_JWT_DIR}/id_ecdsa" -check &>/dev/null; then
        log "Converting existing JWT private key to PKCS#8 format..."
        cp "${SPACETIME_JWT_DIR}/id_ecdsa" "${SPACETIME_JWT_DIR}/id_ecdsa.legacy"
        openssl pkcs8 -topk8 -nocrypt -in "${SPACETIME_JWT_DIR}/id_ecdsa.legacy" -out "${SPACETIME_JWT_DIR}/id_ecdsa"
        rm -f "${SPACETIME_JWT_DIR}/id_ecdsa.legacy"
        chown -R "${SERVICE_USER}:${SERVICE_USER}" "${SPACETIME_JWT_DIR}"
    fi
fi

# --- 2. Register local server with SpacetimeDB CLI ---
LOCAL_SERVER_URL="http://127.0.0.1:${SPACETIME_PORT}"
if ! su "${SERVICE_USER}" -c "HOME=/home/${SERVICE_USER} ${SPACETIME_CLI} server list" 2>/dev/null | grep -q "${LOCAL_SERVER_URL}"; then
    log "Registering local SpacetimeDB server with CLI..."
    su "${SERVICE_USER}" -c "HOME=/home/${SERVICE_USER} ${SPACETIME_CLI} server add local ${LOCAL_SERVER_URL}" || true
fi

# --- 3. Detect if this is a re-run ---
IS_RERUN=false
if systemctl is-active --quiet world-quiz-db.service 2>/dev/null || \
   systemctl is-active --quiet world-quiz-web.service 2>/dev/null; then
    IS_RERUN=true
    log "Existing deployment detected. Updating in-place..."
fi



# --- 4. Copy application files ---
log "Copying application files to ${APP_DIR}..."
mkdir -p "${APP_DIR}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
rsync -avz --exclude='install.sh' "${SCRIPT_DIR}/" "${APP_DIR}/"
chown -R "${SERVICE_USER}:${SERVICE_USER}" "${APP_DIR}"

# --- 5. Warn if frontend URI doesn't match public URI ---
BUILT_URI=$(grep -oP 'wss?://[^"\x27`,;\s]+' "${APP_DIR}/dist/assets/index-"*.js 2>/dev/null | head -1 || echo "unknown")
if [[ "${BUILT_URI}" != "${SPACETIME_PUBLIC_URI}" ]]; then
    warn "Frontend was built for '${BUILT_URI}' but you are deploying for '${SPACETIME_PUBLIC_URI}'."
    warn "Players may not be able to connect. To fix, rebuild the frontend on your dev machine:"
    warn "  cd client && VITE_SPACETIME_URI=${SPACETIME_PUBLIC_URI} npm run build"
    warn "  cp -r dist/ ../.deploy/ && git push"
fi

# --- 6. Create systemd services ---
log "Creating systemd services..."

cat > /etc/systemd/system/world-quiz-db.service <<SVC
[Unit]
Description=SpacetimeDB Server (World Quiz)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SERVICE_USER}
ExecStart=${SPACETIME_BIN} start --listen-addr 0.0.0.0:${SPACETIME_PORT} --data-dir ${SPACETIME_DATA_DIR} --jwt-pub-key-path ${SPACETIME_JWT_DIR}/id_ecdsa.pub --jwt-priv-key-path ${SPACETIME_JWT_DIR}/id_ecdsa
Restart=always
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
SVC

cat > /etc/systemd/system/world-quiz-web.service <<SVC
[Unit]
Description=World Quiz Web Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SERVICE_USER}
WorkingDirectory=${APP_DIR}/dist
ExecStart=/usr/bin/python3 -m http.server ${WEB_PORT}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SVC

systemctl daemon-reload

# --- 7. Enable and start/restart services ---

log "Enabling services to start on boot..."
systemctl enable world-quiz-db.service
systemctl enable world-quiz-web.service

if [[ "$IS_RERUN" == "true" ]]; then
    log "Restarting SpacetimeDB server (config may have changed)..."
    systemctl restart world-quiz-db.service
else
    log "Starting SpacetimeDB server..."
    systemctl start world-quiz-db.service
fi

log "Waiting for SpacetimeDB to be ready..."
for i in $(seq 1 30); do
    if curl -s "http://127.0.0.1:${SPACETIME_PORT}" >/dev/null 2>&1; then
        log "SpacetimeDB is up."
        break
    fi
    sleep 1
    if [[ $i -eq 30 ]]; then
        warn "Timed out waiting for SpacetimeDB to start"
    fi
done

# --- 8. Publish module ---

MODULE_EXISTS=false
if su "${SERVICE_USER}" -c "HOME=/home/${SERVICE_USER} ${SPACETIME_CLI} logs world-quiz --server ${LOCAL_SERVER_URL} -n 1" &>/dev/null; then
    MODULE_EXISTS=true
fi

if [[ "$CLEAR_DATABASE" == "true" ]]; then
    warn "You are about to WIPE all existing game data (rooms, players, scores, and questions)."
    read -p "Are you sure? Type 'yes' to continue: " confirm
    if [[ "$confirm" != "yes" ]]; then
        log "Aborted."
        exit 0
    fi
    log "Publishing World Quiz module with --clear-database (wiping existing data)..."
    su "${SERVICE_USER}" -c "HOME=/home/${SERVICE_USER} ${SPACETIME_CLI} publish world-quiz --server ${LOCAL_SERVER_URL} --no-config -b ${APP_DIR}/server.wasm --clear-database -y"
    log "Module published. Questions are empty — run publish-questions.sh to load them."
elif [[ "$UPDATE_MODULE" == "true" ]]; then
    log "Updating World Quiz module (preserves existing rooms, players, scores, and questions)..."
    su "${SERVICE_USER}" -c "HOME=/home/${SERVICE_USER} ${SPACETIME_CLI} publish world-quiz --server ${LOCAL_SERVER_URL} --no-config -b ${APP_DIR}/server.wasm -y"
    log "Module updated successfully."
elif [[ "$MODULE_EXISTS" == "true" ]]; then
    log "Module 'world-quiz' already published. Skipping publish to preserve existing data."
    log "If you need to update the module code, run:"
    log "  sudo bash install.sh --update"
    log "If you need to wipe data, run:"
    log "  sudo bash install.sh --clear-database"
else
    log "Publishing World Quiz module for the first time..."
    su "${SERVICE_USER}" -c "HOME=/home/${SERVICE_USER} ${SPACETIME_CLI} publish world-quiz --server ${LOCAL_SERVER_URL} --no-config -b ${APP_DIR}/server.wasm --clear-database -y"
    log "Module published. Questions are empty — run publish-questions.sh to load them."
fi

# --- 8b. Publish questions (only after fresh publish or clear-database) ---
if [[ "$CLEAR_DATABASE" == "true" ]] || [[ "$MODULE_EXISTS" == "false" ]]; then
    if su "${SERVICE_USER}" -c "command -v node &>/dev/null && command -v npm &>/dev/null"; then
        log "Publishing questions to the database..."
        su "${SERVICE_USER}" -c "cd ${APP_DIR} && bash ${APP_DIR}/publish-questions.sh"
    else
        warn "Node.js/npm not found for user ${SERVICE_USER}. Skipping automatic question publishing."
        warn "To publish questions manually after installing Node.js 20+:"
        warn "  sudo bash ${APP_DIR}/publish-questions.sh"
    fi
fi

if [[ "$IS_RERUN" == "true" ]]; then
    log "Restarting web server (static files may have changed)..."
    systemctl restart world-quiz-web.service
else
    log "Starting web server..."
    systemctl start world-quiz-web.service
fi

# --- 9. Done ---

log "Deployment complete!"
echo ""
echo "  SpacetimeDB local:   http://127.0.0.1:${SPACETIME_PORT}"
echo "  SpacetimeDB public:  ${SPACETIME_PUBLIC_URI}"
echo "  Web app local:       http://127.0.0.1:${WEB_PORT}"
echo ""
echo "  Service management:"
echo "    systemctl status world-quiz-db"
echo "    systemctl status world-quiz-web"
echo "    journalctl -u world-quiz-db -f"
echo ""
echo "  If using an nginx/SWAG reverse proxy, see nginx/ folder for example configs."
echo ""
