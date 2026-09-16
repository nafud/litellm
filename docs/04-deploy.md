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

Result (2026-09-16): PostgreSQL initialised and healthy at first start; both Presidio
services healthy after about 30 s; LiteLLM applied 161 Prisma migrations, passed its
post-migration sanity check, loaded `mock-echo`, and the liveness probe answered 200
within 25 s of "Application startup complete". Six units active, four containers
healthy. Prisma logs a "distro wolfi" warning (engine fallback to the debian build);
harmless.

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

Egress: from the internal network it must fail (property of the `Internal=true`
network, independent of host policy); from LiteLLM the TCP 443 path must work:

```bash
llmgw$ podman exec presidio-anonymizer curl -sS --max-time 5 https://ghcr.io/ || echo "no egress from backend network: OK"
llmgw$ podman exec litellm python3 -c "import urllib.request, urllib.error
try: print(urllib.request.urlopen('https://ghcr.io/v2/', timeout=10).status)
except urllib.error.HTTPError as e: print(e.code)"                                                   # 401: TCP 443 open
```

Any HTTP status from the last command proves the TCP 443 path from the container; the
provider itself is tested in docs/05 §5.7 once chosen. The two checks below need the
host egress policy of docs/02 §2.8, deferred until after phase 5 (D-22); run them when
it is applied:

```bash
llmgw$ podman exec litellm python3 -c "import socket; socket.create_connection(('1.1.1.1', 80), timeout=5)"   # must time out
sudo journalctl -k --since -5min | grep llmgw-egress-drop                                                       # one drop logged
```

Result (2026-09-16): all as expected. LiteLLM user 65534, all capabilities dropped,
`no-new-privileges`; PostgreSQL user 999 (inspect reports the keep-id mapping as
`userns=private`; `podman exec postgres id` gives uid 999 and the data directory is
owned by `llmgw` on the host); analyzer read-only root, user 1001; backend network
internal; pasta/rootlessport/conmon all `llmgw`; limits 6G/2s, 5G/3s, 1G/1s, 1500M/1s
with the cgroup files agreeing; anonymizer cannot resolve ghcr.io (no egress from the
internal network); LiteLLM gets 401 from ghcr.io over 443; only `127.0.0.1:4000`
listens, owned by rootlessport. No container-related AVC. One new host AVC:
`rhsmcertd_t` reading `/etc/insights-client/machine-id` (`insights_client_etc_rw_t`),
Red Hat's subscription daemon, a policy gap unrelated to the gateway; handled in §4.5
together with the rsyslog one.

## 4.5 Gateway audit rules, SELinux findings, one reboot, then enforcing

The audit configuration has been immutable since the docs/02 §2.1 reboot (`enabled 2`),
so the gateway watches are added to `rules.d` now that every target exists, and the
reboot loads them. `deploy/host` reaches the server the same way as §3.4 (ZIP, `scp`):

```bash
grep -rl $'\r' /tmp/host; echo "crlf-check rc=$?"                          # nothing, rc=1
sudo install -m 640 -o root -g root /tmp/host/llm-gateway.rules /etc/audit/rules.d/llm-gateway.rules
rm -rf /tmp/host
for d in /etc/containers /opt/llm-gateway /home/llmgw/.config/containers /etc/nftables /etc/firewalld; do sudo test -d "$d" && echo "ok $d" || echo "MISSING $d"; done
sudo augenrules --check          # "Rules have changed and should be updated"; it cannot load them now
```

### Denial census before enforcing

Every domain denied anything since the relabel reboot, with the stack running:

```bash
sudo ausearch -m AVC -ts this-week | grep -oE 'scontext=[^ ]+ tcontext=[^ ]+ tclass=[a-z_]+' | sort | uniq -c | sort -rn
```

Result (2026-09-16): no container-related denial at all; three host pairs, each traced
to its cause in the policy sources (fedora-selinux/selinux-policy, branch c10s) rather
than allowed blindly:

| Denied | Cause | Fix |
|---|---|---|
| `rhsmcertd_t` read `insights_client_etc_rw_t` (`/etc/insights-client/machine-id`) | Upstream grants it with `insights_client_read_config(rhsmcertd_t)`; the line is active in rawhide and commented out in the RHEL 10 branch (selinux-policy-42.1.18-4.el10_2.3) | Local module `deploy/host/llmgw-rhsmcertd-insights.te`, the interface expanded verbatim; remove when a policy update carries it |
| `syslogd_t` read `auditd_log_t` (rsyslog imfile on audit.log) | By design: only auditd manages audit logs, no boolean; audit events reach syslog through auditd's syslog plugin | Plugin instead of imfile (docs/02 §2.5, superseded block) |
| `logrotate_t` unlink `auditd_log_t` | `/etc/logrotate.d/audit` (CIS kit) rotated the audit log in parallel with auditd; logrotate may only read audit logs | File removed; auditd rotates (`num_logs` raised, see below) |

```bash
# rhsmcertd: build and install the module (source in deploy/host, pasted to /root)
sudo sh -c 'cd /root && checkmodule -M -m -o llmgw-rhsmcertd-insights.mod llmgw-rhsmcertd-insights.te && semodule_package -o llmgw-rhsmcertd-insights.pp -m llmgw-rhsmcertd-insights.mod && semodule -i llmgw-rhsmcertd-insights.pp'
sudo semodule -l | grep llmgw                                                  # llmgw-rhsmcertd-insights
# logrotate
sudo cp -a /etc/logrotate.d/audit /root/logrotate-audit.cis-2026-01 && sudo rm /etc/logrotate.d/audit
sudo logrotate -d /etc/logrotate.conf 2>&1 | grep -c audit                     # 0
# rsyslog: audit stream by plugin, never into /var/log/messages
sudo dnf -y install audispd-plugins
sudo cp -a /etc/rsyslog.conf /root/rsyslog.conf.2026-09-16
sudo sed -i '50s/^\*\.info;mail\.none;authpriv\.none;cron\.none\b/&;local6.none/' /etc/rsyslog.conf
sudo sed -i -e 's/^active = no$/active = yes/' -e 's/^args = LOG_INFO$/args = LOG_INFO LOG_LOCAL6/' /etc/audit/plugins.d/syslog.conf
sudo mv /etc/rsyslog.d/10-audit-imfile.conf /root/10-audit-imfile.conf.2026-09-16
sudo find /var/lib/rsyslog -name 'imfile-state*' -print -delete
sudo rsyslogd -N1 2>&1 | tail -3 && sudo systemctl restart rsyslog && systemctl is-active rsyslog
sudo install -d -m 755 /etc/systemd/system/auditd.service.d
sudo install -m 644 /tmp/host/auditd-log-ratelimit.conf /etc/systemd/system/auditd.service.d/10-log-ratelimit.conf   # or paste it
sudo systemctl daemon-reload && systemctl show auditd.service -p LogRateLimitIntervalUSec   # 0
```

Plugin, `num_logs` and the audit rules all load at the reboot (auditd cannot be
restarted under `enabled 2`, and the plugin starts with auditd).

### Reboot, verify, enforce

```bash
sudo sed -i 's/^SELINUX=permissive$/SELINUX=enforcing/' /etc/selinux/config && grep '^SELINUX=' /etc/selinux/config
sudo reboot
# after login:
getenforce                                                                                     # Enforcing
systemctl is-failed audit-rules.service; sudo auditctl -s | grep -E '^enabled'                 # inactive, enabled 2
sudo auditctl -l | grep -c -E 'sshd|subid|containers|firewall|gateway'                         # 10
pgrep -a audisp-syslog; sudo journalctl -t audisp-syslog -n 2 --no-pager                       # plugin running, records flowing
sudo grep -c audisp-syslog /var/log/messages                                                   # 0
sudo ausearch -m AVC -ts boot                                                                  # <no matches>
sudo machinectl shell llmgw@
llmgw$ systemctl --user list-units 'llmgw-*' && podman ps --format '{{.Names}}\t{{.Status}}'   # six active, four healthy, nobody started them
```

Then one request from docs/05 §5.1 under enforcing.

## 4.6 Exit criteria

- Four containers healthy; LiteLLM log shows the guardrail loaded and Uvicorn listening.
- Only `127.0.0.1:4000` is listening on the host, owned by `llmgw`.
- Limits reported by `systemctl --user show` match the units.
- `llmgw-backend` is internal and the egress test from Presidio fails.
- The stack survives a reboot; SELinux is enforcing with no denials.
- Proceed to `docs/05-validation.md`.
