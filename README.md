# DevOps Assignment — Notifications API

Containerized version of the Spare DevOps take-home starter API: Node.js + Express + PostgreSQL, wrapped in Docker, Docker Compose, CI, and a small ops script. The application code itself is untouched — everything below is the containerization/ops layer around it.

## Quick start

```bash
docker compose up -d --build
curl http://localhost:8080/health
curl http://localhost:8080/users
```

No `.env` needed to get going — the compose file has sensible defaults for everything. Copy `.env.example` to `.env` if you want to override the port or DB credentials.

Or with the ops script:

```bash
./scripts/ops.sh up
./scripts/ops.sh smoke
./scripts/ops.sh down
```

## Endpoints

| Method | Path | Description |
|--------|------|-------------|
| GET | `/health` | Health check (includes DB connectivity) |
| GET | `/users` | List all users |
| POST | `/users` | Create a user (`{ "name": "Alice" }`) |
| GET | `/notifications?user_id=<id>` | List notifications for a user |
| POST | `/notifications` | Create a notification |

## Part 1 — Dockerfile

Single-stage build on `node:22-alpine`. No transpile/bundle step and no devDependencies in this app, so multi-stage wouldn't actually shed anything — it'd just copy the same `node_modules`/`src` into the same final image through an extra layer.

- Non-root: reuses the `node` user that ships with the alpine image (uid 1000) instead of creating a new one.
- `HEALTHCHECK` hits `/health` with `node -e` rather than curl/wget, since curl/wget aren't in the base image and node already is. `/health` itself checks DB connectivity, so the healthcheck also catches a dead database, not just a dead process.
- `package.json`/`package-lock.json` are copied and installed before the rest of the source, so that layer only rebuilds when dependencies actually change.

## Part 2 — docker-compose.yml

- `postgres` (named volume `pgdata`, so data survives `docker compose down`) and `api`, on a bridge network (`backend`), reachable by service name.
- `api` waits on `postgres: condition: service_healthy`, not just "started." This matters more than it sounds — the app tries the DB exactly once at boot and exits if it's not reachable, it doesn't retry. Without the health gate, `api` would race postgres's startup and crash.
- Config comes from compose `environment:` blocks with defaults (`${DB_NAME:-notifications}`, etc.), so `docker compose up` works with zero setup. `.env` is optional and overrides those defaults if present (same variable names as `.env.example`).
- One exception: `DB_HOST` is hardcoded to `postgres` in the api service, not read from `.env`. That's not a user setting, it's the network topology of the compose file — `.env`'s `DB_HOST=localhost` only applies if you run the app natively without Docker.

## Part 3 — CI (`.github/workflows/ci.yml`)

Two jobs:

**`build-test`** — PRs and push to main:
1. build the image
2. `docker compose up`
3. poll `/health` from the runner, not just trust the container's own HEALTHCHECK (this also catches port-mapping/networking mistakes the container-internal check wouldn't see)
4. `./scripts/ops.sh smoke`
5. on failure, dump `docker compose logs`

**`push`** — only on push to main, and only after `build-test` passes (`needs:`), so a broken build never gets published:
- logs into GHCR with the built-in `GITHUB_TOKEN`, no stored credentials
- tags `latest` + the commit SHA via `docker/metadata-action`
- builds and pushes with `docker/build-push-action`, using the GitHub Actions cache (`type=gha`)

One gotcha handled here: GHCR requires an all-lowercase image path, and `github.repository` isn't guaranteed to be lowercase, so there's a one-line step to lowercase it before use.

## Part 4 — scripts/ops.sh

```
./scripts/ops.sh up       # build + start, idempotent, waits for both services to be healthy
./scripts/ops.sh down     # stop the stack
./scripts/ops.sh status   # docker compose ps
./scripts/ops.sh logs     # last 200 lines from both services
./scripts/ops.sh smoke    # creates a user, creates a notification, asserts the responses
```

`smoke` deliberately does *not* start the stack for you — it only checks whatever's currently running. Run `up` first. If the stack's down, `smoke` fails fast (bounded `curl --max-time`) with a clear message instead of hanging or quietly starting things up.

Every subcommand exits non-zero on failure; `set -euo pipefail` throughout.

## Assumptions / notes

- The brief asks for a healthcheck "on the API service" in compose. It's implemented once, in the Dockerfile's `HEALTHCHECK`, and compose inherits it rather than duplicating the same check in both places — `docker compose ps` reports it either way.
- Image tags are `latest` + the short commit SHA (metadata-action's default `type=sha`), not the full 40-character hash.
- No bonus items attempted (Trivy / Makefile / cloud deploy / structured logging) — kept scope to the 4 required parts.
- A first push to GHCR can land as a private package depending on org defaults. Worth checking its visibility if you want the built image itself pullable, separately from the repo being public.

## Environment variables

| Variable | Description | Default |
|----------|-------------|---------|
| `PORT` | HTTP port | `8080` |
| `DB_HOST` | PostgreSQL host | `localhost` (native) / `postgres` (compose) |
| `DB_PORT` | PostgreSQL port | `5432` |
| `DB_NAME` | Database name | `notifications` |
| `DB_USER` | Database user | `app` |
| `DB_PASSWORD` | Database password | `app` |

## Run locally without Docker

```bash
cp .env.example .env
npm install
npm start
```

Needs a local PostgreSQL instance reachable at whatever `DB_HOST`/`DB_PORT` you set in `.env`.
