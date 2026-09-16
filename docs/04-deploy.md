# Phase 4: Deploy the stack

Everything in this phase runs as the service account (`sudo machinectl shell llmgw@`,
docs/03 §3.6), with the tree at `/opt/llm-gateway` and the images loaded and verified
(docs/03 §3.7). Nothing here needs root.

## 4.1 Create the two secret files

```bash
llmgw$ install -m 600 /opt/llm-gateway/postgres/postgres.env.example /opt/llm-gateway/postgres/postgres.env
llmgw$ install -m 600 /opt/llm-gateway/litellm/litellm.env.example  /opt/llm-gateway/litellm/litellm.env
```

Generate the values and write them into the two files without printing them (hex only:
they are embedded in a URL, passed without quoting, and safe for `sed`). The variables
are unset afterwards; the shell history holds only the commands, never the values:

```bash
llmgw$ PGPW=$(openssl rand -hex 32); MK="sk-$(openssl rand -hex 32)"; SK="sk-$(openssl rand -hex 32)"; UIPW=$(openssl rand -hex 24)
llmgw$ sed -i "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=$PGPW|" /opt/llm-gateway/postgres/postgres.env
llmgw$ sed -i -e "s|^LITELLM_MASTER_KEY=.*|LITELLM_MASTER_KEY=$MK|" -e "s|^LITELLM_SALT_KEY=.*|LITELLM_SALT_KEY=$SK|" -e "s|^DATABASE_URL=.*|DATABASE_URL=postgresql://litellm:$PGPW@postgres:5432/litellm|" -e "s|^UI_PASSWORD=.*|UI_PASSWORD=$UIPW|" /opt/llm-gateway/litellm/litellm.env
llmgw$ unset PGPW MK SK UIPW
llmgw$ grep -c REPLACE /opt/llm-gateway/*/*.env                                # both must print 0
llmgw$ ls -l /opt/llm-gateway/*/*.env                                           # -rw------- llmgw llmgw
llmgw$ grep -hE '^[A-Z_]+=' /opt/llm-gateway/*/*.env | sed -E 's/=.*/=<set>/'   # the six variables, values hidden
```

| File | Variable | Value |
|------|----------|-------|
| `postgres/postgres.env` | `POSTGRES_PASSWORD` | generated |
| `litellm/litellm.env` | `DATABASE_URL` | carries the same password |
| `litellm/litellm.env` | `LITELLM_MASTER_KEY`, `LITELLM_SALT_KEY`, `UI_PASSWORD` | generated |
| `litellm/litellm.env` | provider keys | **none yet**: the provider is chosen after validation (D-19, docs/05 §5.7) |

Store `LITELLM_SALT_KEY` in the company password manager now (`cat` the file to read
it; do not paste it anywhere else): it cannot be rotated without losing encrypted DB
content, and a restored database is useless without it. Store `LITELLM_MASTER_KEY` and
`UI_PASSWORD` with it.
The database and role names (`litellm`/`litellm`) are fixed in
`postgres/llmgw-postgres.container`; only the password is in the env file.

## 4.2 Install the Quadlet units

The units stay next to their components; the rootless Quadlet search path
`~/.config/containers/systemd` receives symlinks to them (supported by
`podman-systemd.unit(5)`):

```bash
llmgw$ bash /opt/llm-gateway/bin/link-quadlets.sh
llmgw$ /usr/libexec/podman/quadlet --user --dryrun >/dev/null && echo "quadlet: OK"
```

Expected: six generated units (`llmgw-backend-network`, `llmgw-egress-network`,
`llmgw-postgres`, `llmgw-presidio-analyzer`, `llmgw-presidio-anonymizer`,
`llmgw-litellm`). `--dryrun` prints the generated services; any error in a unit file is
reported there, before anything runs. To read one generated service in full:
`systemctl --user cat llmgw-litellm.service`.

## 4.3 Start in order and watch

Start the services one at a time so that each one's log is read before the next
depends on it. Logs are read from the admin account: journald keeps the output of
system accounts (uid below 1000, `llmgw` is 989) in the system journal, which `llmgw`
cannot open, and `podman logs` with the journald driver reads the same files. The
filter `_SYSTEMD_USER_UNIT=<unit>` selects one gateway unit; `journalctl --user-unit`
does not work here because as root it also matches uid 0 (D-25). A unit with `Notify=healthy` only reports "started" once its health
check passes, so `systemctl --user start` blocks until then (or fails).

```bash
llmgw$ systemctl --user start llmgw-postgres.service
sudo journalctl _SYSTEMD_USER_UNIT=llmgw-postgres.service -n 30 --no-pager   # (admin) "database system is ready to accept connections"
llmgw$ ls -l /opt/llm-gateway/postgres/data/                            # 18/ owned by llmgw

llmgw$ systemctl --user start llmgw-presidio-anonymizer.service llmgw-presidio-analyzer.service
sudo journalctl _SYSTEMD_USER_UNIT=llmgw-presidio-analyzer.service -n 20 --no-pager   # (admin) 3 gunicorn workers booted (~1 min: spaCy model load)

llmgw$ systemctl --user start llmgw-litellm.service
sudo journalctl _SYSTEMD_USER_UNIT=llmgw-litellm.service -n 80 --no-pager   # (admin)
```

What a good LiteLLM start looks like in the log:

1. Prisma `migrate deploy` applying the schema (first run) or "No pending migrations".
2. The `presidio-pii` guardrail initialised (no `Missing PRESIDIO_ANALYZER_API_BASE` error).
3. `Uvicorn running on http://0.0.0.0:4000`.

If the migration fails the container exits by design (`ENFORCE_PRISMA_MIGRATION_CHECK`),
and systemd retries every 5 s (`Restart=always`). The usual cause is a `DATABASE_URL`
that does not match `postgres.env`; fix the file and `systemctl --user restart llmgw-litellm.service`.

```bash
llmgw$ systemctl --user list-units 'llmgw-*'          # all active
llmgw$ podman ps --format '{{.Names}}\t{{.Status}}'      # four containers, each "(healthy)"
sudo ausearch -m AVC -ts recent                          # (admin) no denials while permissive
```

No `systemctl enable` is needed: the units carry `WantedBy=default.target`, so the
generator wires them into the user manager's boot; with lingering enabled they start at
host boot. Confirm: `systemctl --user list-dependencies default.target | grep llmgw`.

## 4.4 Confirm the security posture and the resource limits

```bash
llmgw$ podman inspect litellm  --format 'user={{.Config.User}} capdrop={{.HostConfig.CapDrop}} secopt={{.HostConfig.SecurityOpt}}'
llmgw$ podman inspect postgres --format 'user={{.Config.User}} userns={{.HostConfig.UsernsMode}} capdrop={{.HostConfig.CapDrop}}'
llmgw$ podman inspect presidio-analyzer --format 'readonly={{.HostConfig.ReadonlyRootfs}} user={{.Config.User}}'
llmgw$ podman network inspect llmgw-backend --format 'internal={{.Internal}}'    # true
llmgw$ podman exec postgres id                                                     # uid=999(postgres)
llmgw$ ps -o user,comm -C pasta -C rootlessport -C conmon                          # all llmgw
llmgw$ for u in litellm presidio-analyzer presidio-anonymizer postgres; do systemctl --user show llmgw-$u.service -p MemoryMax -p CPUQuotaPerSecUSec | tr '\n' ' '; echo " $u"; done
```

Expected limits: litellm `6G` / `2s` (2 CPUs), analyzer `5G` / `3s`, anonymizer `1G` /
`1s`, postgres `1500M` / `1s`. The kernel view of the same values:

```bash
llmgw$ cat /sys/fs/cgroup/user.slice/user-$(id -u).slice/user@$(id -u).service/app.slice/llmgw-litellm.service/memory.max
llmgw$ cat /sys/fs/cgroup/user.slice/user-$(id -u).slice/user@$(id -u).service/app.slice/llmgw-litellm.service/cpu.max   # "200000 100000"
```

From the admin account:

```bash
sudo ss -tlnp | grep ':4000 '                       # 127.0.0.1:4000 only, process owned by llmgw
sudo ss -tlnp | grep -E ':(5432|3000) ' || echo "postgres/presidio not published: OK"
```

Egress: from the internal network it must fail; from LiteLLM only TCP 443 is allowed by
the host policy (docs/02 §2.8):

```bash
llmgw$ podman exec presidio-anonymizer curl -sS --max-time 5 https://ghcr.io/ || echo "no egress from backend network: OK"
llmgw$ podman exec litellm python3 -c "import socket; socket.create_connection(('1.1.1.1', 80), timeout=5)"   # must time out
sudo journalctl -k --since -5min | grep llmgw-egress-drop                                                       # one drop logged
llmgw$ podman exec litellm python3 -c "import urllib.request, urllib.error
try: print(urllib.request.urlopen('https://ghcr.io/v2/', timeout=10).status)
except urllib.error.HTTPError as e: print(e.code)"                                                   # 401: TCP 443 open
```

Any HTTP status from the last command proves the TCP 443 path from the container; the
provider itself is tested in docs/05 §5.7 once chosen.

## 4.5 Gateway audit rules, reboot test, then enforcing

The audit configuration has been immutable since the docs/02 §2.1 reboot (`enabled 2`),
so the gateway watches are added to `rules.d` now that every target exists, and this
reboot loads them. Copy `deploy/host/llm-gateway.rules` with the tree (docs/03 §3.5) or
paste it with a heredoc:

```bash
sudo install -m 640 -o root -g root /tmp/host/llm-gateway.rules /etc/audit/rules.d/llm-gateway.rules
for d in /etc/containers /opt/llm-gateway /home/llmgw/.config/containers /etc/nftables /etc/firewalld; do sudo test -d "$d" && echo "ok $d" || echo "MISSING $d"; done
sudo augenrules --check          # "Rules have changed and should be updated"; it cannot load them now
sudo reboot
# after login:
systemctl is-active audit-rules.service; sudo auditctl -s | grep -E '^enabled'                 # active, enabled 2
sudo auditctl -l | grep -c -E 'sshd|subid|containers|firewall|gateway'                         # 10
# after login:
sudo machinectl shell llmgw@
llmgw$ systemctl --user list-units 'llmgw-*' && podman ps --format '{{.Names}}\t{{.Status}}'
```

All four containers must come back healthy without anyone starting them. With no AVC
denials recorded through §4.3 and §4.4 other than the known rsyslog one (docs/02 §2.1
result: `syslogd_t` reading `auditd_log_t`), resolve that one first (auditd `syslog`
plugin or local policy module, agreed with the SIEM team), then switch SELinux to
enforcing (docs/02 §2.1) and repeat `podman ps` and one request from docs/05 §5.1.

## 4.6 Exit criteria

- Four containers healthy; LiteLLM log shows the guardrail loaded and Uvicorn listening.
- Only `127.0.0.1:4000` is listening on the host, owned by `llmgw`.
- Limits reported by `systemctl --user show` match the units.
- `llmgw-backend` is internal and the egress test from Presidio fails.
- The stack survives a reboot; SELinux is enforcing with no denials.
- Proceed to `docs/05-validation.md`.
