# Phase 4: Deploy the stack

All commands on the server, from `/opt/llm-gateway`, as the admin user with `sudo`.

## 4.1 Create the two secret files

```bash
cd /opt/llm-gateway/deploy
sudo install -m 600 -o root -g root .env.example .env
sudo install -m 600 -o root -g root litellm.env.example litellm.env
```

Generate values (hex only: they are embedded in URLs and shell-free):

```bash
echo "POSTGRES_PASSWORD=$(openssl rand -hex 32)"
echo "LITELLM_MASTER_KEY=sk-$(openssl rand -hex 32)"
echo "LITELLM_SALT_KEY=sk-$(openssl rand -hex 32)"
echo "UI_PASSWORD=$(openssl rand -hex 24)"
```

Edit `.env` and `litellm.env` (`sudoedit`) and fill in:

| File | Variable | Value |
|------|----------|-------|
| `.env` | `POSTGRES_PASSWORD` | generated |
| `.env` | `LITELLM_BIND_ADDR` | keep `127.0.0.1` for phase 5; switch to the LAN IP afterwards |
| `.env` | `PRESIDIO_ANALYZER_WORKERS` | `1` unless the assessment showed RAM to spare |
| `litellm.env` | `LITELLM_MASTER_KEY`, `LITELLM_SALT_KEY`, `UI_PASSWORD` | generated |
| `litellm.env` | `ANTHROPIC_API_KEY` (and others) | the company's provider keys |

Store `LITELLM_SALT_KEY` in the company password manager now: it cannot be rotated
without losing encrypted DB content, and a restored database is useless without it.

## 4.2 Review the effective configuration

```bash
cd /opt/llm-gateway/deploy
sudo docker compose config > /dev/null && echo "compose: OK"
sudo docker compose config | grep -A3 'ports:'          # confirm the bind address
```

`docker compose config` fails loudly if a `:?` variable is missing.

## 4.3 Start in order and watch

```bash
sudo docker compose up -d postgres
sudo docker compose logs -f postgres        # until "database system is ready to accept connections"; Ctrl-C
sudo docker compose up -d presidio-analyzer presidio-anonymizer
sudo docker compose ps                      # wait for both to show (healthy); analyzer takes ~1 min to load spaCy
sudo docker compose up -d litellm
sudo docker compose logs -f litellm
```

What a good LiteLLM start looks like in the log:

1. Prisma: `migrate deploy` applying the schema (first run) or "No pending migrations".
2. `presidio-pii` guardrail initialised (no `Missing PRESIDIO_ANALYZER_API_BASE` error).
3. `Uvicorn running on http://0.0.0.0:4000`.

If the migration fails the container exits (by design, `ENFORCE_PRISMA_MIGRATION_CHECK`).
The usual cause is a wrong `DATABASE_URL`; check `.env` and that `postgres` is healthy.

## 4.4 Confirm the security posture of the running containers

```bash
sudo docker compose ps                               # all four: Up (healthy)
sudo docker inspect llm-gateway-litellm-1 --format '{{.Config.User}} {{.HostConfig.CapDrop}} {{.HostConfig.SecurityOpt}}'
sudo docker inspect llm-gateway-postgres-1 --format '{{.Config.User}} {{.HostConfig.ReadonlyRootfs}}'
sudo docker inspect llm-gateway-presidio-analyzer-1 --format '{{.HostConfig.ReadonlyRootfs}}'
sudo docker network inspect llm-gateway_backend --format '{{.Internal}}'   # true
sudo ss -tlnp | grep 4000                              # only on LITELLM_BIND_ADDR
sudo ss -tlnp | grep -E ':(5432|3000)\s' || echo "postgres/presidio not published: OK"
```

Egress check from inside the internal network (must fail):

```bash
sudo docker compose exec presidio-anonymizer curl -sS --max-time 5 https://ghcr.io/ || echo "no egress from backend network: OK"
```

## 4.5 Exit criteria

- Four containers healthy; LiteLLM log shows the guardrail loaded and Uvicorn listening.
- Only `4000` on the chosen bind address is listening on the host.
- `backend` network is internal and the egress test from Presidio fails.
- Proceed to `docs/05-validation.md`.
