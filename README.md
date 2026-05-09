# World Quiz Deployment Package

This folder is a **self-contained deployment package** for World Quiz. It contains everything needed to deploy the game to a VPS without needing Rust, Node.js, or the full source code on the target machine.

> **Recent change (May 2026):** Questions are no longer embedded in `server.wasm`. They are published dynamically via `publish-questions.sh` after the module is live. This decouples the question bank from the server code.

---

## What's Included

| File / Folder | Purpose |
|---------------|---------|
| `dist/` | Pre-built React frontend (static HTML/JS/CSS) |
| `server.wasm` | Pre-built SpacetimeDB Rust module (questions published dynamically) |
| `install.sh` | **One-command VPS deployment** — installs SpacetimeDB, publishes module, loads questions, creates systemd services |
| `publish-questions.sh` | Loads compiled question JSONs into the live SpacetimeDB module |
| `prepare-deploy.sh` | **Dev-machine script** — rebuilds wasm, regenerates bindings, builds frontend, copies everything into `.deploy/` |
| `data/questions/<theme>/<lang>.json` | Compiled question datasets for all themes × 4 languages |
| `scripts/publish.js` | Node.js CLI that publishes questions to SpacetimeDB |
| `start-spacetime.sh` | Start SpacetimeDB on port 3080 (manual/local use) |
| `start-web.sh` | Start static file server on port 8060 (manual/local use) |
| `world-quiz-db.service` | systemd service template for SpacetimeDB |
| `world-quiz-web.service` | systemd service template for static files |
| `nginx/` | Example SWAG/nginx reverse proxy configs |

---

## Prerequisites

### Dev machine (where you run `prepare-deploy.sh`)
- Rust + Cargo
- Node.js 20+ and npm
- SpacetimeDB CLI 2.1.0 (`spacetime` or `spacetimedb-cli` in PATH)
- Git

### VPS (where you run `install.sh`)
- Linux (Ubuntu/Debian recommended)
- Root access
- `curl`, `git`, `python3`, `systemctl`, `rsync`, `openssl`
- **Node.js 20+ and `npm`** (required to publish questions)

---

## The Deploy Workflow

This is the entire process from code change to live production:

```bash
# 1. On your dev machine — prepare the deploy package
./.deploy/prepare-deploy.sh

# 2. Commit and push from inside .deploy/
cd .deploy
git add .
git commit -m "deploy: update production artifacts"
git push

# 3. On your VPS — pull and install
cd /opt/world-quiz
git pull
sudo bash install.sh --update

# 4. If question data changed, republish
sudo bash publish-questions.sh
```

---

## Preparing a Release (dev machine)

Run `prepare-deploy.sh` from the **project root** (not from inside `.deploy/`):

```bash
cd /path/to/world-quiz
./.deploy/prepare-deploy.sh
```

This single script:
1. Generates TypeScript client bindings (also rebuilds `server.wasm`)
2. Builds the production frontend with `VITE_SPACETIME_URI=wss://spacetime.dnas.place`
3. Copies `server.wasm`, `client/dist/`, question data, and publisher scripts into `.deploy/`
4. Verifies the frontend URI matches the expected public endpoint (fails fast if wrong)

For a custom domain:
```bash
./.deploy/prepare-deploy.sh wss://spacetime.yourdomain.com
```

> **Critical:** Always use `prepare-deploy.sh`. Do not manually copy files. It cleans stale hashed assets, regenerates bindings, and verifies the URI so you don't hit `RangeError` or `Mixed Content` errors in production.

---

## Deploying to the VPS

### Fresh VPS (first time)

```bash
# Clone the deploy repo on your VPS
git clone <your-deploy-repo-url> /opt/world-quiz
cd /opt/world-quiz

# Run the one-command installer
sudo bash install.sh
```

`install.sh` will:
- Install SpacetimeDB 2.1.0 and generate JWT keys
- Copy files to `/opt/world-quiz/`
- Create and enable systemd services
- Start SpacetimeDB on port 3080
- Publish `server.wasm` (module starts with empty question bank)
- Run `publish-questions.sh` to load all compiled questions
- Start the static web server on port 8060

> **Note:** If Node.js is not installed, automatic question publishing is skipped. Install Node.js 20+ and run `sudo bash /opt/world-quiz/publish-questions.sh` manually.

### Update an existing deployment (preserve data)

Use this when you have new features but want to keep existing rooms, players, and scores:

```bash
cd /opt/world-quiz
git pull
sudo bash install.sh --update
```

This copies new `dist/` and `server.wasm`, restarts services, and republishes the module **without wiping the database**. It only fails if the new module has a breaking schema change (in which case use `--clear-database`).

### Wipe everything (clear database)

Use this only if `--update` fails due to a breaking schema change:

```bash
cd /opt/world-quiz
sudo bash install.sh --clear-database
```

You will be prompted to type `yes` to confirm.

### Re-running without any changes

`install.sh` is idempotent. Running it again without flags just copies files and restarts services without touching the module or database.

---

## Custom Domains & Reverse Proxy

If serving through HTTPS with custom domains, use the example nginx configs in `nginx/`.

### DNS
- `spacetime.yourdomain.com` → your VPS IP
- `quiz.yourdomain.com` → your VPS IP

### Setup
```bash
# 1. Copy nginx configs
cp nginx/spacetime.conf /config/nginx/proxy-confs/
cp nginx/quiz.conf /config/nginx/proxy-confs/

# 2. Restart SWAG/nginx

# 3. Rebuild deploy package with your public URI
./.deploy/prepare-deploy.sh wss://spacetime.yourdomain.com
cd .deploy
git add . && git commit && git push

# 4. On VPS, deploy with the URI
cd /opt/world-quiz && git pull
sudo bash install.sh
```

**Important proxy settings** (already in example configs):
- `proxy_http_version 1.1;`
- `proxy_set_header Upgrade $http_upgrade;`
- `proxy_set_header Connection "upgrade";`
- `proxy_send_timeout 3600s;` and `proxy_read_timeout 3600s;`

---

## Manual Start (without systemd)

```bash
# Terminal 1: Start SpacetimeDB
./start-spacetime.sh

# Terminal 2: Start web server
./start-web.sh
```

---

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `SPACETIME_PUBLIC_URI` | `wss://spacetime.dnas.place` | Public WebSocket URL clients connect to |
| `SPACETIME_PORT` | `3080` | Local port SpacetimeDB listens on |
| `WEB_PORT` | `8060` | Local port for static file server |
| `SERVICE_USER` | `$SUDO_USER` | Linux user to run services as |

---

## Ports & Firewall

| Service | Port | Description |
|---------|------|-------------|
| SpacetimeDB | 3080 | WebSocket endpoint for game server |
| Static web | 8060 | React frontend |

```bash
sudo ufw allow 8060/tcp
sudo ufw allow 3080/tcp
```

---

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

---

## Troubleshooting

### `RangeError: Tried to read X byte(s) at relative offset Y`

**Cause:** Client bindings are out of sync with the server module (schema mismatch). You forgot to run `prepare-deploy.sh` after a schema change.

**Fix:**
```bash
# On dev machine
./.deploy/prepare-deploy.sh
cd .deploy
git add . && git commit && git push

# On VPS
cd /opt/world-quiz && git pull && sudo bash install.sh --update
```

### `Mixed Content: page loaded over HTTPS, attempted to connect to ws://...`

**Cause:** Frontend was built for the wrong URI.

**Fix:**
```bash
./.deploy/prepare-deploy.sh wss://spacetime.dnas.place
cd .deploy
git add . && git commit && git push
```

### `install.sh` says "Frontend was built for '...' but deploying for '...'"

**Cause:** The URI check detected a mismatch. You passed `--clear-database` or `--update` as the first argument before the fix, or your frontend was built for a different domain.

**Fix:** Same as Mixed Content — run `prepare-deploy.sh` with the correct URI.

### Module publish fails or SpacetimeDB not responding

**Cause:** The SpacetimeDB systemd service may not have started.

**Fix:**
```bash
sudo systemctl restart world-quiz-db
sudo systemctl status world-quiz-db
# Wait 5 seconds, then retry install.sh --update
```

### SpacetimeDB fails to start with JWT key error

**Cause:** Keys are not in PKCS#8 format.

**Fix:** The install script converts automatically. If you manually created keys:
```bash
openssl pkcs8 -topk8 -nocrypt -in id_ecdsa -out id_ecdsa.pkcs8
mv id_ecdsa.pkcs8 id_ecdsa
```

### Port already in use

```bash
lsof -Pi :3080 -sTCP:LISTEN
lsof -Pi :8060 -sTCP:LISTEN
```

---

## Quick Reference

### File paths

| File | Purpose |
|------|---------|
| `client/dist/` | Local dev frontend (do NOT commit to deploy repo) |
| `.deploy/dist/` | Production frontend (committed to deploy repo) |
| `.deploy/prepare-deploy.sh` | **Dev script** — rebuilds everything and copies to `.deploy/` |
| `server/spacetimedb/target/wasm32-unknown-unknown/release/server.wasm` | Compiled module (dev only) |
| `.deploy/server.wasm` | Copy of module for deployment |
| `.deploy/data/questions/<theme>/<lang>.json` | Compiled question datasets |
| `.deploy/scripts/publish.js` | Node.js CLI that publishes questions |
| `.deploy/publish-questions.sh` | Helper that installs deps and runs `publish.js` |
| `client/src/module_bindings/` | Auto-generated TypeScript bindings (dev only) |

### Commands

| Task | Command |
|------|---------|
| Prepare deploy package | `./.deploy/prepare-deploy.sh` |
| First deploy to VPS | `sudo bash install.sh` |
| Update deploy (preserve data) | `sudo bash install.sh --update` |
| Wipe and fresh deploy | `sudo bash install.sh --clear-database` |
| Publish questions on VPS | `sudo bash /opt/world-quiz/publish-questions.sh` |
| Check service status | `systemctl status world-quiz-db world-quiz-web` |
| View logs | `journalctl -u world-quiz-db -f` |

---

## Deployment Checklist

Before pushing to production:

- [ ] `cargo test` passes locally (85/85 tests)
- [ ] Local frontend works at `http://localhost:8080/`
- [ ] `./.deploy/prepare-deploy.sh` completed with no errors
- [ ] Frontend URI verified in output (matches your public endpoint)
- [ ] `server.wasm` rebuilt and copied to `.deploy/`
- [ ] Question data copied to `.deploy/data/questions/`
- [ ] Publisher scripts copied to `.deploy/scripts/`
- [ ] Changes committed and pushed from `.deploy/`
- [ ] VPS pulled latest code
- [ ] `sudo bash install.sh --update` completed successfully
- [ ] `sudo bash publish-questions.sh` completed successfully (if questions changed)
- [ ] Site loads and works in browser with no console errors
