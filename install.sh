#!/usr/bin/env bash
set -euo pipefail

# World Quiz — One-Command VPS Deployment
# Usage: sudo bash install.sh
#
# This script installs SpacetimeDB, publishes the pre-built module,
# creates systemd services, and starts everything.
# Intended to be run on a fresh VPS after cloning the deploy repo.

APP_DIR="/opt/world-quiz"
SPACETIME_VERSION="2.1.0"
SERVICE_USER="${SUDO_USER:-$(whoami)}"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${RED}[!]${NC} $*"; }

# --- Check root ---
if [[ $EUID -ne 0 ]]; then
    warn "This script must be run as root (sudo)."
    exit 1
fi

log "Deploying World Quiz to target machine..."

# --- 0. Install prerequisites ---
for cmd in curl git python3 systemctl; do
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
    openssl ecparam -genkey -name prime256v1 -noout -out "${SPACETIME_JWT_DIR}/id_ecdsa"
    openssl ec -in "${SPACETIME_JWT_DIR}/id_ecdsa" -pubout -out "${SPACETIME_JWT_DIR}/id_ecdsa.pub"
    chown -R "${SERVICE_USER}:${SERVICE_USER}" "${SPACETIME_JWT_DIR}"
fi

# --- 2. Copy application files ---
log "Copying application files to ${APP_DIR}..."
mkdir -p "${APP_DIR}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
rsync -avz --exclude='install.sh' "${SCRIPT_DIR}/" "${APP_DIR}/"
chown -R "${SERVICE_USER}:${SERVICE_USER}" "${APP_DIR}"

# --- 3. Create systemd services ---
log "Creating systemd services..."

cat > /etc/systemd/system/world-quiz-db.service <<SVC
[Unit]
Description=SpacetimeDB Server (World Quiz)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SERVICE_USER}
ExecStart=${SPACETIME_BIN} start --listen-addr 0.0.0.0:3080 --data-dir ${SPACETIME_DATA_DIR} --jwt-pub-key-path ${SPACETIME_JWT_DIR}/id_ecdsa.pub --jwt-priv-key-path ${SPACETIME_JWT_DIR}/id_ecdsa
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
ExecStart=/usr/bin/python3 -m http.server 8060
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SVC

systemctl daemon-reload

# --- 4. Enable and start services ---

log "Enabling services to start on boot..."
systemctl enable world-quiz-db.service
systemctl enable world-quiz-web.service

log "Starting SpacetimeDB server..."
systemctl start world-quiz-db.service

log "Waiting for SpacetimeDB to be ready..."
for i in $(seq 1 30); do
    if curl -s http://127.0.0.1:3080 >/dev/null 2>&1; then
        log "SpacetimeDB is up."
        break
    fi
    sleep 1
    if [[ $i -eq 30 ]]; then
        warn "Timed out waiting for SpacetimeDB to start"
    fi
done

log "Publishing World Quiz module (this seeds all 1,220 questions)..."
su "${SERVICE_USER}" -c "HOME=/home/${SERVICE_USER} ${SPACETIME_CLI} publish world-quiz --server http://127.0.0.1:3080 --no-config -b ${APP_DIR}/server.wasm --clear-database -y"
log "Module published and questions seeded."

log "Starting web server..."
systemctl start world-quiz-web.service

# --- 5. Done ---

log "Deployment complete!"
echo ""
echo "  SpacetimeDB:  http://127.0.0.1:3080  (websocket)"
echo "  Web app:      http://127.0.0.1:8060"
echo ""
echo "  Service management:"
echo "    systemctl status world-quiz-db"
echo "    systemctl status world-quiz-web"
echo "    journalctl -u world-quiz-db -f"
echo ""
