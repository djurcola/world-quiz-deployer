# World Quiz Deployment Package

This folder is a **self-contained deployment package** for World Quiz. It contains everything needed to deploy the game to a VPS without needing Rust, Node.js, or the full source code on the target machine.

## What's Included

| File / Folder | Purpose |
|---------------|---------|
| `dist/` | Pre-built React frontend (static HTML/JS/CSS) |
| `server.wasm` | Pre-built SpacetimeDB Rust module (1,220 questions embedded) |
| `install.sh` | **One-command VPS deployment** — installs SpacetimeDB, publishes the module, creates systemd services, and starts everything |
| `start-spacetime.sh` | Start SpacetimeDB on port 3080 (for manual/local use) |
| `start-web.sh` | Start static file server on port 8060 (for manual/local use) |
| `world-quiz-db.service` | systemd service template for SpacetimeDB |
| `world-quiz-web.service` | systemd service template for static files |
| `.env.example` | Example environment variables (used during frontend build) |

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
- Copy application files to `/opt/world-quiz/`
- Create and enable systemd services
- Start SpacetimeDB on port 3080
- Publish the pre-built `server.wasm` module (seeds all 1,220 questions)
- Start the static web server on port 8060

After it finishes, open `http://your-vps:8060` in a browser.

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
- `curl`, `git`, `python3`, `systemctl`
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

1. `cargo test` passed (36/36 tests)
2. `npm run build` produced `client/dist/`
3. `server.wasm` was built via `spacetimedb-cli publish`
4. Both artifacts were copied into this `deploy/` folder

Do not hand-edit `dist/` or `server.wasm` — always rebuild from the main repo.
