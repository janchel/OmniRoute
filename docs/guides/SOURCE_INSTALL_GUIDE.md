---
title: "📦 Source Install & Deployment Guide"
version: 3.8.50
lastUpdated: 2026-08-06
---

# 📦 Source Install & Deployment Guide

> Complete, verified walkthrough for installing OmniRoute **from source** and deploying it
> on a Linux server. Every command in this guide was executed against a real
> Ubuntu 26.04 x86_64 box (Node.js 24.19.0, npm 11.17.0) and verified end-to-end,
> including the failure modes and their fixes documented below.

This is the long-form companion to the [From Source](./SETUP_GUIDE.md#from-source) section of
the Setup Guide. If you just want the happy path, the tl;dr is:

```bash
cp .env.example .env
npm install
npm run dev            # → http://localhost:20128
```

Everything below is the "why it is not always that simple" version — prerequisites,
the npm 11 native-dependency gate, the first-run bootstrap, and the issues that can
bite a fresh environment.

---

## Table of Contents

- [1. Prerequisites](#1-prerequisites)
- [2. Install Node.js](#2-install-nodejs)
- [3. Install Build Tools](#3-install-build-tools)
- [4. Get the Source & Prepare `.env`](#4-get-the-source--prepare-env)
- [5. Install Dependencies](#5-install-dependencies)
- [6. Start the Dev Server](#6-start-the-dev-server)
- [7. First-Run Setup (API Key + Free Provider)](#7-first-run-setup-api-key--free-provider)
- [8. Verifying the Installation](#8-verifying-the-installation)
- [9. Issues Encountered & Fixes](#9-issues-encountered--fixes)
- [10. The "Spinning Login Page" Fix](#10-the-spinning-login-page-fix)
- [11. Troubleshooting Quick Reference](#11-troubleshooting-quick-reference)

---

## 1. Prerequisites

| Requirement | Minimum / Supported            | Notes                                                                                                 |
| ----------- | ------------------------------ | ----------------------------------------------------------------------------------------------------- |
| Node.js     | `>=22 <23` **or** `>=24 <27`   | `engines.node` in `package.json` is authoritative. Node 24 LTS ("Krypton") is the safe pick.          |
| npm         | ships with Node                | npm ≥11 enables the `allow-scripts` install gate described in §5.                                     |
| Build tools | `make`, `g++`, Python 3        | Only required to compile the native SQLite engine (`better-sqlite3`) when no prebuilt binary applies. |
| Network     | registry.npmjs.org, nodejs.org | The apt mirror is **not** required (see §9, Issue 1).                                                 |

> **Database engine note.** `better-sqlite3` is declared as an **optional dependency**
> (`optionalDependencies` in `package.json`). It ships a prebuilt binary for most
> platforms; when one is unavailable it falls back to compiling from source. There is
> also a pure-JS fallback (`node:sqlite` on Node 22+, else the bundled `sql.js` WASM).
> In practice the Next.js dev server fails to bundle `node:sqlite` (see §9, Issue 3),
> so getting the native `better-sqlite3` working is effectively required for a
> source install.

---

## 2. Install Node.js

The easiest path is usually your distro package manager, but in this deployment the
apt mirror (`ph.archive.ubuntu.com`) was unreachable from the host (see §9, Issue 1).
Install the LTS tarball directly from nodejs.org instead:

```bash
# Find the latest LTS (look for a non-empty "lts" field):
curl -s https://nodejs.org/dist/index.json | python3 -c \
  "import json,sys; d=json.load(sys.stdin); [print(v['version'], v.get('lts') or '') for v in d if v['lts']][:5]"

# Download + install Node 24 LTS for linux-x64 into /usr/local:
cd /tmp
curl -fsSL -o node.tar.xz https://nodejs.org/dist/v24.19.0/node-v24.19.0-linux-x64.tar.xz
tar -xJf node.tar.xz
cp -r node-v24.19.0-linux-x64/* /usr/local/
rm -rf node-v24.19.0-linux-x64 node.tar.xz

node --version   # v24.19.0
npm --version    # 11.17.0
```

Adjust the version/arch (`linux-arm64` for ARM) and confirm with
`uname -m`. Alternatively, `nvm` or a distro package (e.g. `apt install nodejs npm`)
work when your mirror is reachable — the repo just needs a Node version in the
supported range.

---

## 3. Install Build Tools

`better-sqlite3` compiles with `node-gyp` when no prebuilt binary is used, which
requires `make`, a C++ compiler, and Python:

```bash
apt-get update
apt-get install -y make g++ python3
```

If your apt mirror is down, use the Node.js binary approach above or switch the
`sources.list` mirror before running `apt-get` (§9, Issue 2).

---

## 4. Get the Source & Prepare `.env`

```bash
git clone https://github.com/diegosouzapw/OmniRoute.git
cd OmniRoute

# Check out the active release branch (never develop directly on main):
git checkout release/v3.8.50

cp .env.example .env
```

> `npm install` auto-generates `.env` from `.env.example` if it does not exist, and
> never overwrites an existing one.

`JWT_SECRET` and `API_KEY_SECRET` ship empty in the example and **must** be set before
first boot, or authentication is disabled. Generate them per the repo conventions:

```bash
openssl rand -base64 48     # → JWT_SECRET
openssl rand -hex 32        # → API_KEY_SECRET
```

Then edit `.env`:

```dotenv
JWT_SECRET=<generated>
API_KEY_SECRET=<generated>
INITIAL_PASSWORD=<choose a strong initial admin password>
PORT=20128
REQUIRE_API_KEY=false       # API-key requirement toggle
```

`.env` is covered by `.gitignore`, so these secrets never enter the repository.

---

## 5. Install Dependencies

```bash
npm install
```

This is where npm 11's **`allow-scripts` security gate** matters. npm ≥11 refuses to run
`postinstall`/`install` scripts by default for packages that are not explicitly approved,
so native modules ship without their platform binaries. The install warns:

```text
npm warn allow-scripts 13 packages have install scripts not yet covered by allowScripts:
npm warn allow-scripts   @swc/core@1.15.43 (postinstall: node postinstall.js)
npm warn allow-scripts   esbuild@0.28.1 (postinstall: node install.js)
...
```

### 5a. Approve the native-build scripts

Approve the packages whose install scripts download/verify native binaries:

```bash
npm approve-scripts @swc/core esbuild @parcel/watcher core-js protobufjs unrs-resolver \
  bun keytar koffi libxmljs2 onnxruntime-node tls-client-node
```

(SWCs and esbuild binaries are used by the Next.js build; `bun` runs a few
allow-listed gate scripts per `AGENTS.md`.)

### 5b. Install + build `better-sqlite3`

Because it is an **optional** dependency, npm silently drops `better-sqlite3` when its
install script is blocked — the module directory is simply absent afterwards
(`Cannot find module 'better-sqlite3'` at boot). Install it explicitly, approve its
script, and rebuild:

```bash
npm install better-sqlite3@13.0.1
npm approve-scripts better-sqlite3   # npm approve-scripts <pkg> (may need it present first)
npm rebuild better-sqlite3 --foreground-scripts
```

Verify it loads:

```bash
node -e "const D=require('better-sqlite3'); const d=new D(':memory:'); d.exec('create table t(a)'); console.log('better-sqlite3 OK')"
```

> If `node-gyp rebuild` fails with `not found: make`, go back to §3 — the build tools
> are missing (§9, Issue 4).

---

## 6. Start the Dev Server

```bash
PORT=20128 npm run dev
```

Boot sequence you should see (first run also generates a storage-encryption key and a
SQLite DB under `DATA_DIR`, default `~/.omniroute/`):

```text
[bootstrap] ✨ STORAGE_ENCRYPTION_KEY auto-generated (first run)
[Migration] SQLite database ready: .../storage.sqlite
[Next] dev server listening on http://0.0.0.0:20128 (turbopack)
```

Server binds `0.0.0.0` by default, so it is reachable over the LAN
(e.g. `http://<server-ip>:20128`) as well as `localhost`.

To run it detached:

```bash
nohup npm run dev > /tmp/omniroute-dev.log 2>&1 &
```

---

## 7. First-Run Setup (API Key + Free Provider)

A fresh source install starts with **zero connected providers**, so `model: auto`
resolves to an empty candidate pool until you connect one. Do the two-step setup:

### 7a. Create an API key (dashboard session)

The dashboard login uses `INITIAL_PASSWORD`. Authenticate and issue a key:

```bash
# 1. Login (JWT session cookie stored in cookies.txt)
curl -s -c cookies.txt -H "Content-Type: application/json" \
  -d '{"password":"<INITIAL_PASSWORD>"}' \
  http://localhost:20128/api/auth/login

# 2. Create an API key (requires the session cookie)
curl -s -b cookies.txt -H "Content-Type: application/json" \
  -d '{"name":"local-dev-key"}' \
  http://localhost:20128/api/keys
```

The response returns the raw `key` **once** — store it (e.g. `sk-...`).

> The `/api/keys` endpoint (management session) is the one that creates keys accepted
> by `/v1/*`. The `/api/v1/registered-keys` endpoint creates a different kind of
> registered key that the OpenAI-compatible surface does not validate against.

### 7b. Connect a keyless free provider

OpenCode Free requires no API key:

```bash
curl -s -b cookies.txt -H "Content-Type: application/json" \
  -d '{"provider":"opencode","apiKey":"","name":"OpenCode Free"}' \
  http://localhost:20128/api/providers
```

Other free options (Kiro AI for free Claude, etc.) are available from the
**Dashboard → Providers** UI.

---

## 8. Verifying the Installation

```bash
KEY=sk-...   # from step 7a

# Models list
curl -s http://localhost:20128/v1/models -H "Authorization: Bearer $KEY"

# Chat — explicit free model
curl -s http://localhost:20128/v1/chat/completions \
  -H "Content-Type: application/json" -H "Authorization: Bearer $KEY" \
  -d '{"model":"oc/big-pickle","messages":[{"role":"user","content":"Say OK"}],"stream":false}'

# Chat — auto routing (needs ≥1 connected provider, see §7b)
curl -s http://localhost:20128/v1/chat/completions \
  -H "Content-Type: application/json" -H "Authorization: Bearer $KEY" \
  -d '{"model":"auto","messages":[{"role":"user","content":"Hello!"}]}'
```

Expected: `HTTP 200` with a JSON or SSE response containing model output. Other
OpenAI-compatible endpoints to sanity-check: `/v1/completions`, `/v1/messages`,
`/v1/responses`.

---

## 9. Issues Encountered & Fixes

These are the real failure modes hit while performing this exact source install,
with the fix that resolved each one.

### Issue 1 — Unreachable apt mirror

**Symptom:** `apt-get update` hangs/fails on `http://ph.archive.ubuntu.com` with
`Unable to connect`.

**Root cause:** The distro's default mirror host was not reachable from this network,
while `archive.ubuntu.com`, `registry.npmjs.org`, and `nodejs.org` were.

**Fix:** Point apt at a reachable mirror (or skip apt entirely — see Issue 2):

```bash
sed -i 's|http://ph.archive.ubuntu.com/ubuntu/|http://archive.ubuntu.com/ubuntu/|g' \
  /etc/apt/sources.list.d/ubuntu.sources
apt-get update
```

### Issue 2 — No Node.js installed and apt can't provide it

**Symptom:** `node: command not found`.

**Fix:** Install Node.js 24 LTS from the nodejs.org binary tarball (§2). This needs
no package manager at all.

### Issue 3 — `node:sqlite` bundling failure in the Next.js dev server

**Symptom:** at boot:

```text
[DB] Sync driver 'better-sqlite3' failed to open ... Cannot find module 'better-sqlite3'
[DB] Sync driver 'node:sqlite' failed to open ... Unsupported external type Url for commonjs reference
[FATAL] Failed to start Next custom server: ... Cannot find module 'better-sqlite3'
```

**Root cause:** `better-sqlite3` was never installed (§5b), and the pure-JS fallback
`node:sqlite` cannot be bundled by the Next dev server on this setup.

**Fix:** install + build the native `better-sqlite3` (§5b).

### Issue 4 — `node-gyp` fails: `not found: make`

**Symptom:** `npm rebuild better-sqlite3` fails with `gyp ERR! Error: not found: make`.

**Root cause:** `better-sqlite3` compiled from source, but `make`/`g++` were not
installed.

**Fix:** `apt-get install -y make g++ python3` (§3), then rerun the rebuild.

### Issue 5 — Stale dev-server state → `/v1/chat/completions` returns HTML 404

**Symptom:** after the first (crashed) server start, `/v1/chat/completions` returns the
dashboard **HTML 404 page** even though the route file exists and the log says
`○ Compiling /api/v1/chat/completions`.

**Root cause:** the `.next` build cache was corrupted by the earlier FATAL crash; the
orphaned `next-server` process from the first boot was still holding the port, so the
"restart" never actually replaced the broken server.

**Fix:** kill **all** `run-next`/`next-server` processes, delete `.next`, and start
fresh:

```bash
ps aux | grep -E "run-next|next-server" | grep -v grep | awk '{print $2}' | xargs -r kill -9
rm -rf .next
npm run dev
```

### Issue 6 — `model: auto` returns 404 / empty pool on a fresh install

**Symptom:**

```text
[MODEL] Ambiguous model 'auto'. Use provider/model prefix (ex: tr/auto or dify/auto).
[AUTO] auto/coding:pro matched no connected models; returning an empty pool.
```

**Root cause:** several providers register a model literally named `auto`, so the bare
id is ambiguous, and with **zero connected providers** the auto-combo pool is empty.

**Fix:** connect at least one provider first (§7b), then `model: auto` routes through
it. Use a provider-prefixed model (`oc/big-pickle`, `kiro/...`) to bypass ambiguity.

---

## 10. The "Spinning Login Page" Fix

**Symptom:** `http://<server-ip>:20128/login` loads the HTML (server log shows
`GET /login 200`) but the page **spins forever** instead of rendering.

**Server log:**

```text
⚠ Blocked cross-origin request to Next.js dev resource /_next/webpack-hmr from "192.168.5.50".
Cross-origin access to Next.js dev resources is blocked by default for safety.
```

**Root cause:** in development, Next.js blocks the **Hot Module Replacement (HMR)
WebSocket** for any origin not listed in `allowedDevOrigins`. When the browser cannot
open the HMR socket, the dev client never finishes connecting and the page appears
stuck. `localhost` and `127.0.0.1` are allowed by default, but a LAN IP is not.

**Fix:** add the LAN IP to `allowedDevOrigins` in `next.config.mjs` and restart:

```js
allowedDevOrigins: ["localhost", "127.0.0.1", "192.168.0.250", "192.168.5.50"],
```

After restart, the blocked-origin warning disappears and the page loads. **Hard-refresh
the browser** (Ctrl/Cmd+Shift+R) afterwards to drop the stuck HMR client.

> This is a **dev-server-only** behavior. Production builds (Docker image, `next start`,
> `npm run build`) are not affected, because there is no HMR in production.

---

## 11. Troubleshooting Quick Reference

| Symptom                                   | Likely cause                           | Fix                                                                |
| ----------------------------------------- | -------------------------------------- | ------------------------------------------------------------------ |
| `Cannot find module 'better-sqlite3'`     | optional dep dropped by npm gate       | §5b install + approve + rebuild                                    |
| `gyp ERR! not found: make`                | build tools missing                    | `apt-get install -y make g++ python3`                              |
| HTML 404 on `/v1/chat/completions`        | stale/corrupt `.next`, orphaned server | kill processes, `rm -rf .next`, restart                            |
| Page spins on `http://<ip>:20128`         | HMR origin blocked                     | add IP to `allowedDevOrigins`, restart, hard-refresh               |
| `Ambiguous model 'auto'` / empty pool     | no provider connected                  | connect a free provider, or prefix the model                       |
| `Invalid API key` on `/v1/*`              | wrong key type                         | create the key via `POST /api/keys`, not `/api/v1/registered-keys` |
| Port `20128` already in use               | orphaned dev process                   | `ps aux \| grep next-server` → kill by PID                         |
| Login disabled / 500 `JWT_SECRET not set` | secrets empty in `.env`                | set `JWT_SECRET` + `API_KEY_SECRET` (§4)                           |
