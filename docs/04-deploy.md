# Phase 4: Deploy the stack

Everything in this phase runs as the service account (`sudo machinectl shell llmgw@`,
docs/03 §3.3), with the repository at `/opt/llm-gateway/repo` and the images already
pulled and verified (docs/03 §3.6). Nothing here needs root.

## 4.1 Create the two secret files

```bash
llmgw$ install -m 600 /opt/llm-gateway/repo/deploy/env/postgres.env.example /opt/llm-gateway/env/postgres.env
llmgw$ install -m 600 /opt/llm-gateway/repo/deploy/env/litellm.env.example  /opt/llm-gateway/env/litellm.env
```

Generate values (hex only: they are embedded in a URL and passed without quoting):

```bash
llmgw$ PGPW=$(openssl rand -hex 32)
llmgw$ echo "POSTGRES_PASSWORD=$PGPW"
llmgw$ echo "DATABASE_URL=postgresql://litellm:$PGPW@postgres:5432/litellm"
llmgw$ echo "LITELLM_MASTER_KEY=sk-$(openssl rand -hex 32)"
llmgw$ echo "LITELLM_SALT_KEY=sk-$(openssl rand -hex 32)"
llmgw$ echo "UI_PASSWORD=$(openssl rand -hex 24)"
```

Edit both files (`vi`) and fill in:

| File | Variable | Value |
|------|----------|-------|
| `postgres.env` | `POSTGRES_PASSWORD` | generated |
| `litellm.env` | `DATABASE_URL` | the line printed above (same password) |
| `litellm.env` | `LITELLM_MASTER_KEY`, `LITELLM_SALT_KEY`, `UI_PASSWORD` | generated |
| `litellm.env` | `ANTHROPIC_API_KEY` (and others) | the company's provider keys |

```bash
llmgw$ grep -c REPLACE /opt/llm-gateway/env/*.env      # both must print 0
llmgw$ ls -l /opt/llm-gateway/env                       # -rw------- llmgw llmgw
```

Store `LITELLM_SALT_KEY` in the company password manager now: it cannot be rotated
without losing encrypted DB content, and a restored database is useless without it.
The database and role names (`litellm`/`litellm`) are fixed in
`deploy/quadlet/llmgw-postgres.container`; only the password is in the env file.

## 4.2 Install the Quadlet units

The units stay in the repository; the rootless Quadlet search path is a symlink to them
(symlinks are supported for the base of the search path, `podman-systemd.unit(5)`).

```bash
llmgw$ mkdir -p ~/.config/containers
llmgw$ ln -s /opt/llm-gateway/repo/deploy/quadlet ~/.config/containers/systemd
llmgw$ /usr/libexec/podman/quadlet --user --dryrun >/dev/null && echo "quadlet: OK"
llmgw$ systemctl --user daemon-reload
llmgw$ systemctl --user list-unit-files 'llmgw-*'
```

Expected: six generated units (`llmgw-backend-network`, `llmgw-egress-network`,
`llmgw-postgres`, `llmgw-presidio-analyzer`, `llmgw-presidio-anonymizer`,
`llmgw-litellm`). `--dryrun` prints the generated services; any error in a unit file is
reported there, before anything runs. To read one generated service in full:
`systemctl --user cat llmgw-litellm.service`.

## 4.3 Start in order and watch

Start the services one at a time so that each one's log is read before the next
depends on it. A unit with `Notify=healthy` only reports "started" once its health
check passes, so `systemctl --user start` blocks until then (or fails).

```bash
llmgw$ systemctl --user start llmgw-postgres.service
llmgw$ journalctl --user -u llmgw-postgres.service -n 30 --no-pager   # "database system is ready to accept connections"
llmgw$ ls -l /opt/llm-gateway/data/postgres/                            # 18/ owned by llmgw

llmgw$ systemctl --user start llmgw-presidio-anonymizer.service llmgw-presidio-analyzer.service
llmgw$ journalctl --user -u llmgw-presidio-analyzer.service -n 20 --no-pager   # gunicorn workers booted (~1 min: spaCy model load)

llmgw$ systemctl --user start llmgw-litellm.service
llmgw$ journalctl --user -u llmgw-litellm.service -n 80 --no-pager
```

What a good LiteLLM start looks like in the log:

1. Prisma `migrate deploy` applying the schema (first run) or "No pending migrations".
2. The `presidio-pii` guardrail initialised (no `Missing PRESIDIO_ANALYZER_API_BASE` error).
3. `Uvicorn running on http://0.0.0.0:4000`.

If the migration fails the container exits by design (`ENFORCE_PRISMA_MIGRATION_CHECK`),
and systemd retries every 5 s (`Restart=always`). The usual cause is a `DATABASE_URL`
that does not match `postgres.env`; fix the file and `systemctl --user restart llmgw-litellm.service`.

```bash
llmgw$ systemctl --user list-units 'llmgw-*'      # all active
llmgw$ podman ps --format '{{.Names}}\t{{.Status}}'  # four containers, each "(healthy)"
```

No `systemctl enable` is needed: the units carry `WantedBy=default.target`, so the
generator wires them into the user manager's boot; with lingering enabled they start at
host boot. Confirm: `systemctl --user list-dependencies default.target | grep llmgw`.

## 4.4 Confirm the security posture of the running containers

```bash
llmgw$ podman inspect litellm  --format 'user={{.Config.User}} capdrop={{.HostConfig.CapDrop}} secopt={{.HostConfig.SecurityOpt}}'
llmgw$ podman inspect postgres --format 'user={{.Config.User}} userns={{.HostConfig.UsernsMode}} capdrop={{.HostConfig.CapDrop}}'
llmgw$ podman inspect presidio-analyzer --format 'readonly={{.HostConfig.ReadonlyRootfs}} user={{.Config.User}}'
llmgw$ podman network inspect llmgw-backend --format 'internal={{.Internal}}'    # true
llmgw$ podman exec postgres id                                                     # uid=999(postgres)
llmgw$ ps -o user,comm -C pasta -C rootlessport -C conmon                          # all llmgw
```

From the admin account:

```bash
sudo ss -tlnp | grep ':4000 '                       # 127.0.0.1:4000 only, process owned by llmgw
sudo ss -tlnp | grep -E ':(5432|3000) ' || echo "postgres/presidio not published: OK"
```

Egress check from the internal network (must fail) and from LiteLLM (must succeed, it
is the only container on `llmgw-egress`):

```bash
llmgw$ podman exec presidio-anonymizer curl -sS --max-time 5 https://ghcr.io/ || echo "no egress from backend network: OK"
llmgw$ podman exec litellm python3 -c "import urllib.request; print(urllib.request.urlopen('https://api.anthropic.com/', timeout=10).status)"
```

The second command prints an HTTP status (any code proves the TLS path is open). If
docs/02 §2.8 is applied, a non-443 attempt from LiteLLM is dropped and logged:

```bash
llmgw$ podman exec litellm python3 -c "import socket; socket.create_connection(('1.1.1.1', 80), timeout=5)"   # must time out
sudo journalctl -k --since -5min | grep llmgw-egress-drop
```

## 4.5 Reboot test

```bash
sudo reboot
# after login:
sudo machinectl shell llmgw@
llmgw$ systemctl --user list-units 'llmgw-*' && podman ps --format '{{.Names}}\t{{.Status}}'
```

All four containers must come back healthy without anyone starting them.

## 4.6 Exit criteria

- Four containers healthy; LiteLLM log shows the guardrail loaded and Uvicorn listening.
- Only `127.0.0.1:4000` is listening on the host, owned by `llmgw`.
- `llmgw-backend` is internal and the egress test from Presidio fails.
- The stack survives a reboot.
- Proceed to `docs/05-validation.md`.
