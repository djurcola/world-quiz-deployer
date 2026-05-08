# Deployment Guide

A step-by-step guide for taking new features from local development and pushing them to the production VPS at `quiz.dnas.place`.

---

## Prerequisites

### On your dev machine
- Rust + Cargo
- Node.js 20+ and npm
- SpacetimeDB CLI 2.1.0 (`spacetime` or `spacetimedb-cli` in PATH)
- Git

### On the VPS
- Linux (Ubuntu/Debian recommended)
- Root access (for `install.sh`)
- `curl`, `git`, `python3`, `systemctl`, `rsync`, `openssl`
- Node.js 20+ and `npm` (required to publish questions via `publish-questions.sh`)

---

## Part 1: Local Development & Testing

### 1.1 Start the local SpacetimeDB server

```bash
# Terminal 1 — start SpacetimeDB on port 3000
./.deploy/start-spacetime.sh

# Or manually:
spacetime start --listen-addr 0.0.0.0:3000
```

### 1.2 Publish the server module locally

```bash
cd server/spacetimedb
spacetime publish world-quiz --server local --no-config -p . --clear-database -y
```

### 1.3 Build and run the local frontend

```bash
cd client
npm run dev
```

Open `http://192.168.20.128:8080/` (or `http://localhost:8080/`) in your browser and test.

> **Important:** The local dev build uses `ws://${window.location.hostname}:3000` as the default SpacetimeDB URI. No `VITE_SPACETIME_URI` override is needed for local testing.

### 1.4 Run tests

```bash
# Rust backend tests
cd server/spacetimedb
cargo test

# Frontend tests (if any)
cd client
npm run test
```

---

## Part 2: Prepare the Deploy Package

Once your local dev version works correctly, build the production artifacts.

### 2.1 Build the production frontend

The production frontend **must** be built with the public WebSocket URI baked in:

```bash
cd client
VITE_SPACETIME_URI=wss://spacetime.dnas.place VITE_DB_NAME=world-quiz npm run build
```

Verify the correct URI is embedded:

```bash
grep -oP 'wss?://[^"\x27`,;\s]+' dist/assets/index-*.js | head -1
# Expected output: wss://spacetime.dnas.place
```

### 2.2 Build the server module

```bash
cd server/spacetimedb
spacetime build
```

This produces `target/wasm32-unknown-unknown/release/server.wasm`.

### 2.3 Copy artifacts into the deploy folder

```bash
# From project root
cp -r client/dist/* .deploy/dist/
cp server/spacetimedb/target/wasm32-unknown-unknown/release/server.wasm .deploy/server.wasm
cp server/spacetimedb/target/wasm32-unknown-unknown/release/server.wasm server/spacetimedb/server.wasm

# Copy question data and publisher scripts
cp -r data/questions .deploy/data/
cp data/manifest.json .deploy/data/
cp scripts/publish.js .deploy/scripts/
cp scripts/package.json .deploy/scripts/
cp scripts/package-lock.json .deploy/scripts/
```

### 2.4 Clean stale assets

Remove any old hashed JS/CSS files that `vite` may have replaced:

```bash
ls .deploy/dist/assets/
# Delete any old index-*.js or index-*.css that are NOT referenced by .deploy/dist/index.html
```

### 2.5 Regenerate client bindings (if schema changed)

If you added/removed tables or reducers, regenerate the TypeScript bindings:

```bash
spacetime generate --lang typescript --out-dir client/src/module_bindings --module-path server/spacetimedb
```

Then rebuild the frontend again (step 2.1) and copy to deploy (step 2.3).

### 2.6 Commit and push

```bash
git add .deploy/ server/spacetimedb/server.wasm client/src/module_bindings/
git commit -m "build(deploy): update production artifacts for release X"
git push
```

---

## Part 3: Deploy to the VPS

### 3.1 Connect to the VPS

```bash
ssh your-user@vps-ip
```

### 3.2 Pull the latest deploy package

```bash
cd /opt/world-quiz
git pull
```

### 3.3 Choose the right install command

#### First-time deployment (fresh VPS)

```bash
cd /opt/world-quiz
sudo bash install.sh
```

On first deploy, `install.sh` will:
1. Install SpacetimeDB and start the service
2. Publish the module (with an empty question bank)
3. Automatically run `publish-questions.sh` to load all compiled questions
4. Start the web server

> **Note:** If Node.js is not installed on the VPS, the automatic question publishing will be skipped. Install Node.js 20+ and then run `sudo bash /opt/world-quiz/publish-questions.sh` manually.

#### Update an existing deployment (preserve data)

Use this when you have new features but want to keep existing rooms, players, and scores:

```bash
cd /opt/world-quiz
sudo bash install.sh --update
```

This will:
- Copy new `dist/` and `server.wasm` into `/opt/world-quiz/`
- Restart the web server
- Republish the module code **without wiping the database**

#### Force a fresh start (wipe everything)

Use this only if `--update` fails due to a breaking schema change:

```bash
cd /opt/world-quiz
sudo bash install.sh --clear-database
```

You will be prompted to type `yes` to confirm the wipe.

### 3.4 Verify the deployment

```bash
# Check services are running
systemctl status world-quiz-db
systemctl status world-quiz-web

# View recent logs
journalctl -u world-quiz-db -f
journalctl -u world-quiz-web -f

# Check SpacetimeDB is responding
curl -s http://127.0.0.1:3080

# Check the web app is serving
 curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8060/
# Expected: 200
```

### 3.5 Test in browser

Open `https://quiz.dnas.place/` and verify:
1. The "Enter your display name" screen loads
2. You can register and connect
3. Create/join rooms work
4. Questions load correctly

Open browser DevTools → Console and confirm:
- `Connecting to SpacetimeDB WS...` appears
- `wss://spacetime.dnas.place` is the connection target
- No `Mixed Content` or `RangeError` errors

---

## Part 4: Troubleshooting

### Error: `Mixed Content: The page was loaded over HTTPS, but attempted to connect to ws://...`

**Cause:** The production frontend was built without `VITE_SPACETIME_URI`.

**Fix:**
```bash
cd client
VITE_SPACETIME_URI=wss://spacetime.dnas.place npm run build
cp -r dist/* ../.deploy/
git add .deploy/ && git commit && git push
# Then re-run install.sh --update on the VPS
```

### Error: `RangeError: Tried to read X byte(s) at relative offset Y`

**Cause:** The client bindings are out of sync with the server module (schema mismatch).

**Fix:**
```bash
# On dev machine
spacetime generate --lang typescript --out-dir client/src/module_bindings --module-path server/spacetimedb
cd client
VITE_SPACETIME_URI=wss://spacetime.dnas.place npm run build
cp -r dist/* ../.deploy/
git add .deploy/ client/src/module_bindings/
git commit && git push

# On VPS
cd /opt/world-quiz && git pull && sudo bash install.sh --update
```

### Error: `Module publish fails` or `SpacetimeDB is not responding`

**Cause:** The SpacetimeDB systemd service may not have started.

**Fix:**
```bash
sudo systemctl restart world-quiz-db
sudo systemctl status world-quiz-db
# Wait 5 seconds, then retry install.sh --update
```

### Error: install.sh says "Frontend was built for '...' but deploying for '...'"

**Cause:** The URI check regex detected a mismatch.

**Fix:** Rebuild the frontend with the correct `VITE_SPACETIME_URI` (see "Mixed Content" fix above).

---

## Part 5: Quick Reference

### File paths

| File | Purpose |
|------|---------|
| `client/dist/` | Local dev frontend (do NOT commit) |
| `.deploy/dist/` | Production frontend (committed to deploy repo) |
| `server/spacetimedb/target/wasm32-unknown-unknown/release/server.wasm` | Compiled module |
| `.deploy/server.wasm` | Copy of module for deployment |
| `.deploy/data/questions/<theme>/<lang>.json` | Compiled question datasets (published dynamically) |
| `.deploy/scripts/publish.js` | Node.js CLI that publishes questions to SpacetimeDB |
| `.deploy/publish-questions.sh` | Helper script that installs deps and runs `publish.js` |
| `client/src/module_bindings/` | Auto-generated TypeScript bindings |

### Commands

| Task | Command |
|------|---------|
| Start local SpacetimeDB | `./.deploy/start-spacetime.sh` |
| Publish module locally | `spacetime publish world-quiz --server local --no-config -p . --clear-database -y` |
| Publish questions locally | `cd scripts && npm install && node publish.js --server ws://127.0.0.1:3000` |
| Run local frontend | `cd client && npm run dev` |
| Build production frontend | `cd client && VITE_SPACETIME_URI=wss://spacetime.dnas.place npm run build` |
| Build server module | `cd server/spacetimedb && spacetime build` |
| Regenerate bindings | `spacetime generate --lang typescript --out-dir client/src/module_bindings --module-path server/spacetimedb` |
| First deploy to VPS | `sudo bash install.sh` |
| Update deploy on VPS | `sudo bash install.sh --update` |
| Wipe and fresh deploy | `sudo bash install.sh --clear-database` |
| Publish questions on VPS | `sudo bash /opt/world-quiz/publish-questions.sh` |
| Check service status | `systemctl status world-quiz-db world-quiz-web` |
| View logs | `journalctl -u world-quiz-db -f` |

---

## Deployment Checklist

Before pushing to production, verify:

- [ ] `cargo test` passes locally (85/85 tests)
- [ ] Local frontend loads and game works at `http://192.168.20.128:8080/`
- [ ] Production frontend built with `VITE_SPACETIME_URI=wss://spacetime.dnas.place`
- [ ] `server.wasm` rebuilt with latest code
- [ ] Old stale assets removed from `.deploy/dist/assets/`
- [ ] Client bindings regenerated if schema changed
- [ ] Question data copied to `.deploy/data/questions/`
- [ ] Publisher scripts copied to `.deploy/scripts/`
- [ ] Changes committed and pushed to git
- [ ] VPS pulled latest code
- [ ] `sudo bash install.sh --update` completed successfully
- [ ] `sudo bash publish-questions.sh` completed successfully (if questions changed)
- [ ] `quiz.dnas.place` loads and works in browser
