# World Quiz Deployment Package

This folder is a **self-contained deployment package** for World Quiz. It contains everything needed to deploy the game to a VPS without needing Rust, Node.js, or the full source code on the target machine.

## What's Included

| File / Folder | Purpose |
|---------------|---------|
| `dist/` | Pre-built React frontend (static HTML/JS/CSS) |
| `server.wasm` | Pre-built SpacetimeDB Rust module (2,147 questions per language, 5 themes) |
| `install.sh` | **One-command VPS deployment** — installs SpacetimeDB, publishes the module, creates systemd services, and starts everything |
| `start-spacetime.sh` | Start SpacetimeDB on port 3080 (for manual/local use) |
| `start-web.sh` | Start static file server on port 8060 (for manual/local use) |
| `world-quiz-db.service` | systemd service template for SpacetimeDB |
| `world-quiz-web.service` | systemd service template for static files |
| `.env.example` | Example environment variables (used during frontend build) |
| `nginx/` | Example SWAG/nginx reverse proxy configs |

## Quick Start — Fresh VPS

```bash
# 1. Clone this deploy repo onto your VPS
git clone <your-deploy-repo-url> world-quiz
cd world-quiz

# 2. Run the one-command installer
sudo bash install.sh
```

That's it. The script will:
- Install SpacetimeDB 2.1.0
- Generate JWT keys in PKCS#8 format (required by SpacetimeDB)
- Copy application files to `/opt/world-quiz/`
- Create and enable systemd services
- Start SpacetimeDB on port 3080
- Publish the pre-built `server.wasm` module (seeds all questions across 5 themes)
- Start the static web server on port 8060

After it finishes, open `http://your-vps:8060` in a browser.

### Re-running on an existing deployment

`install.sh` is **idempotent** — you can safely run it again to update files or config without losing game data:

```bash
# Update static files and restart services (preserves database)
sudo bash install.sh
```

On re-run it will:
- Update `/opt/world-quiz/` with the latest files from this repo
- Restart systemd services so config changes take effect
- **Skip** the `publish --clear-database` step, preserving all rooms, players, and scores

To force a fresh install and wipe the database:
```bash
sudo bash install.sh --clear-database
```

### Custom public URI

If your SpacetimeDB will be accessed via a public URL (e.g. behind an nginx proxy):

```bash
sudo SPACETIME_PUBLIC_URI=wss://spacetime.yourdomain.com bash install.sh
```

The script will warn you if the frontend was built for a different URI.

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `SPACETIME_PUBLIC_URI` | `wss://spacetime.dnas.place` | Public WebSocket URL clients connect to |
| `SPACETIME_PORT` | `3080` | Local port SpacetimeDB listens on |
| `WEB_PORT` | `8060` | Local port for static file server |
| `SERVICE_USER` | `$SUDO_USER` | Linux user to run services as |

## Manual Start (without systemd)

If you prefer not to use systemd:

```bash
# Terminal 1: Start SpacetimeDB
./start-spacetime.sh

# Terminal 2: Start web server
./start-web.sh
```

## Prerequisites

- Linux VPS (Ubuntu/Debian recommended)
- `curl`, `git`, `python3`, `systemctl`, `rsync`, `openssl`
- Root access (for `install.sh`)

## Ports

| Service | Port | Description |
|---------|------|-------------|
| SpacetimeDB | 3080 | WebSocket endpoint for game server |
| Static web | 8060 | React frontend |

## Service Management

```bash
# Check status
systemctl status world-quiz-db
systemctl status world-quiz-web

# View logs
journalctl -u world-quiz-db -f
journalctl -u world-quiz-web -f

# Restart
systemctl restart world-quiz-db
systemctl restart world-quiz-web
```

## Firewall

```bash
sudo ufw allow 8060/tcp
sudo ufw allow 3080/tcp
```

## Reverse Proxy Setup (SWAG / Nginx)

If you want to serve SpacetimeDB and the web app through HTTPS with custom domains, use the example nginx configs in `nginx/`.

### Why two subdomains?

SpacetimeDB uses WebSockets at the root path and is sensitive to path rewriting. A dedicated `spacetime.*` subdomain avoids subtle protocol bugs.

### Setup

1. Ensure DNS A records point to your VPS:
   - `spacetime.yourdomain.com` -> your VPS IP
   - `quiz.yourdomain.com` -> your VPS IP

2. Copy the nginx configs into your SWAG proxy-confs folder:
   ```bash
   cp nginx/spacetime.conf /config/nginx/proxy-confs/
   cp nginx/quiz.conf /config/nginx/proxy-confs/
   ```

3. Update the `$upstream_app` in each config if SpacetimeDB/web run on a different host than nginx.

4. Restart SWAG/nginx.

5. Rebuild the frontend with the public SpacetimeDB URI:
   ```bash
   # On your dev machine
   cd client
   VITE_SPACETIME_URI=wss://spacetime.yourdomain.com npm run build
   cp -r dist/ ../deploy/
   # Commit and push to your deploy repo
   ```

6. Run `install.sh` on the VPS with your public URI:
   ```bash
   sudo SPACETIME_PUBLIC_URI=wss://spacetime.yourdomain.com bash install.sh
   ```

**Important proxy settings** (already in the example configs):
- `proxy_http_version 1.1;`
- `proxy_set_header Upgrade $http_upgrade;`
- `proxy_set_header Connection "upgrade";`
- `proxy_send_timeout 3600s;` and `proxy_read_timeout 3600s;`

## Updating the Deployment

To update after a new release:

```bash
# On your dev machine: rebuild and copy files into deploy/
# Then push to your deploy repo and pull on the VPS
cd /opt/world-quiz
git pull

# Republish the module (this clears the database)
sudo systemctl stop world-quiz-db
spacetimedb-cli publish world-quiz --server http://127.0.0.1:3080 --no-config -b server.wasm --clear-database -y
sudo systemctl start world-quiz-db world-quiz-web
```

## Troubleshooting

### Port already in use
```bash
lsof -Pi :3080 -sTCP:LISTEN
lsof -Pi :8060 -sTCP:LISTEN
```

### Module publish fails
Ensure SpacetimeDB is running:
```bash
systemctl status world-quiz-db
curl -s http://127.0.0.1:3080
```

### SpacetimeDB fails to start with JWT key error
The install script converts keys to PKCS#8 automatically. If you manually created keys, convert them:
```bash
openssl pkcs8 -topk8 -nocrypt -in id_ecdsa -out id_ecdsa.pkcs8
mv id_ecdsa.pkcs8 id_ecdsa
```

### Frontend can't connect
Check that the WebSocket URI baked into `dist/assets/index-*.js` matches your SpacetimeDB endpoint. If you need a different endpoint, rebuild the frontend with `VITE_SPACETIME_URI` set:

```bash
# On dev machine
cd ../client
VITE_SPACETIME_URI=wss://spacetime.yourdomain.com npm run build
cp -r dist/ ../deploy/
```

## How This Package Was Built

This package was generated from the main World Quiz development repo:

1. `cargo test` passed (88/88 tests)
2. `npm run build` produced `client/dist/`
3. `server.wasm` was built via `spacetime build`
4. Both artifacts were copied into this `deploy/` folder

Do not hand-edit `dist/` or `server.wasm` — always rebuild from the main repo.
