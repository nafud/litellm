# Phase 1: Server assessment (read-only)

Goal: know exactly what we are deploying onto before changing anything. Hardening
(phase 2) is driven by this report, not by a generic checklist. Nothing in this phase
modifies the server.

## 1.1 How it was done

The admin (`infosec`) ran read-only commands over SSH and pasted the output into the
working conversation; `scripts/assess.sh` covers the same ground in one run
(`scp scripts/assess.sh infosec@<server>:/tmp/ && sudo bash /tmp/assess.sh /tmp/assessment.txt`)
and can be re-run after hardening for a diff. Reports stay out of the repository
(`reports/` is git-ignored): they list users, ports and network details.

## 1.2 Findings (2026-09-14)

| Area | Finding | Consequence |
|------|---------|-------------|
| OS | RHEL 10.1 (Coughlan), kernel 6.12.0-124.28.1.el10_1, x86_64, VMware guest (`ens33`) | Podman + Quadlet (D-11) |
| CPU / RAM | 8 cores (Xeon Platinum 8280, 1 thread/core), 15 GiB RAM, 2 GiB swap | Budget: LiteLLM 2 CPU / 6 GiB, Presidio 4 CPU / 6 GiB, PostgreSQL 1 CPU / 1.5 GiB, OS the rest (D-15) |
| Disk | LVM root 417 GB, 405 GB free; `/tmp` tmpfs 7.7 GB | `/opt/llm-gateway` on root, including the image store (~4 GB after the pulls) |
| Accounts | `infosec` (uid 1001, wheel) and `devops` both allowed by sshd; both have subordinate id ranges | Decide whether `devops` keeps access (open question) |
| SSH | port 22, `PermitRootLogin no`, `PasswordAuthentication yes`, keys allowed, `AllowUsers devops infosec` | Password auth to be disabled (docs/02 §2.2) once key login is confirmed |
| Crypto policy | `DEFAULT:NO-WEAKMAC:NO-SSHWEAKMACS` | Fine, keep |
| SELinux | **Disabled** | Must be re-enabled before deployment (docs/02 §2.5); the units rely on it |
| firewalld | installed, **not running** | To be enabled with an explicit inbound policy (docs/02 §2.7) |
| nftables | 1.1.1 installed, service state unknown | Used for the egress policy (docs/02 §2.8) |
| Listening | sshd 22; rsyslogd **TCP 514 on all interfaces**; zabbix_agentd 10050; `pmd` UDP+TCP 33221; chronyd 323 (loopback) | rsyslog input listener and `pmd` need explanation (open questions); zabbix is monitoring |
| Network | `ens33` 10.50.4.68/24, gateway 10.50.4.254, resolvers 10.100.0.1 and 10.100.0.2 | Egress policy resolvers filled in; LAN address for the client-facing port later |
| Time / audit | chronyd active, auditd active | Keep |
| Subscription | **Not registered, no dnf repositories** | Podman cannot be installed until a package source exists (docs/03 §3.0) |
| Egress | at assessment time ghcr.io, Docker Hub, GitHub, cdn.redhat.com all **timed out**; **internet access was enabled afterwards** (owner, 2026-09-14) | Packages and images are fetched on the server (D-18); §1.4 re-checks what is reachable and whether a proxy is in the path |
| cgroups | `cpu memory pids` delegated to user sessions | CPU and memory quotas work for the rootless service account without any drop-in |
| Containers | Podman, skopeo, container-selinux, passt not installed | Installed in phase 3 |
| user namespaces | `user.max_user_namespaces = 62627` | Rootless Podman possible |

## 1.3 Open questions (answers needed before phase 2 starts)

1. **Package source.** §1.4 showed Red Hat's registration and content hosts blocked
   while GitHub and the registries answer. Best practice is registration (updates keep
   flowing, `dnf-automatic`); it needs the network firewall to allow the host to
   `subscription.rhsm.redhat.com:443` and `cdn.redhat.com:443` (plus
   `cert-api.access.redhat.com:443` only if Insights is wanted). Alternatives: an
   internal Satellite if the company has one, or the RHEL 10.1 ISO (no updates).
   §1.6 block A characterises the block precisely for the firewall request; block B
   shows how the VM was built (kickstart repo, Satellite CA) which may settle this.
2. **SELinux.** It is disabled. Was that a deliberate choice by whoever built the VM? The
   plan re-enables it (permissive, relabel, then enforcing); confirm before phase 2.
3. **`pmd` on port 33221** and the **rsyslog listener on 514**: what are they, and are they
   corporate standard (keep and allow in firewalld) or leftovers (remove)?
4. **`devops` account**: keep its SSH access or not?
5. **Admin source network** for the SSH firewall rule, and the **Zabbix server address**
   for port 10050.
6. **Internet path**: answered by §1.4 (2026-09-14): direct via 10.50.4.254, no proxy
   anywhere. Selective: `github.com` 200, `ghcr.io/v2/` and `registry-1.docker.io/v2/`
   401 (open), `subscription.rhsm.redhat.com` and `cdn.redhat.com` 000 (blocked).
   The provider is decided later (D-19), so no provider-specific rule is needed now;
   the host policy limits the service account to TCP 443 (docs/02 §2.8).
7. **Workstation OS** (the machine you SSH from): `scp` is enough for the deployment;
   `skopeo` and `cosign` are needed only to run `scripts/verify-pins.sh` when an image
   pin is chosen or changed (D-18).

## 1.4 Re-check after internet access was enabled

Read-only, run as `infosec` on the server; paste the output. It shows which hosts answer,
whether DNS works for them, and whether a proxy is already configured somewhere:

```bash
for u in https://subscription.rhsm.redhat.com/ https://cdn.redhat.com/ https://ghcr.io/v2/ https://registry-1.docker.io/v2/ https://github.com/; do
  code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 8 "$u" 2>/dev/null); printf '%-45s HTTP %s\n' "$u" "${code:-000}"
done
for h in cdn.redhat.com ghcr.io registry-1.docker.io; do getent hosts "$h" || echo "$h: NO RESOLUTION"; done
env | grep -i proxy || echo "no proxy variables in the shell"
grep -i proxy /etc/dnf/dnf.conf /etc/rhsm/rhsm.conf /etc/environment 2>/dev/null || echo "no proxy configured in dnf/rhsm/environment"
ip route get 8.8.8.8 | head -1
```

Any HTTP code (200, 301, 401, 403) means the path is open; `000` means blocked or no
DNS. `ghcr.io/v2/` and `registry-1.docker.io/v2/` normally answer `401`.

Result (2026-09-14): no proxy; default route via 10.50.4.254; GitHub 200, both
registries 401; **both Red Hat hosts 000** although they resolve. Consequence: the
proxy steps of docs/03 are skipped, image pulls work, registration does not until the
network firewall allows the Red Hat hosts (question 1).

## 1.6 Targeted read-only checks per open question

All read-only. `sudo` only reads files or process information. Paste the outputs.

**A. Question 1 / 6: characterise the Red Hat block for the firewall request**

```bash
for h in subscription.rhsm.redhat.com cdn.redhat.com cert-api.access.redhat.com; do
  for v in 4 6; do
    printf '%-32s IPv%s  ' "$h" "$v"
    curl -$v -sS -o /dev/null -w 'HTTP %{http_code} via %{remote_ip}' --max-time 8 "https://$h/" 2>&1 | tr '\n' ' '; echo
  done
done
ip -6 addr show scope global; ip -6 route show default
tracepath -n -m 12 cdn.redhat.com | tail -4
for u in https://access.redhat.com/ https://pypi.org/ https://quay.io/v2/ https://api.openai.com/; do
  code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 8 "$u" 2>/dev/null); printf '%-36s HTTP %s\n' "$u" "${code:-000}"
done
```

IPv4 timing out with no IPv6 route means a destination allowlist on the network
firewall; the last loop shows whether it is an allowlist (most 000) or a Red Hat
specific block. `tracepath` shows where packets stop answering.

**B. Question 1 / 2 / 4: how the VM was built**

```bash
sudo ls -l /root/*ks.cfg 2>&1
sudo grep -vE '^\s*(#|$)' /root/anaconda-ks.cfg 2>/dev/null | grep -viE 'rootpw|password|iscrypted'
rpm -qa --last | tail -3                      # earliest packages: installation date
rpm -qa --last | head -15                     # latest changes: agents and tools added after build
sudo dnf history list 2>&1 | head -12
ls /etc/yum.repos.d/ /etc/pki/entitlement/ /etc/pki/consumer/ /etc/rhsm/ca/ 2>&1
rpm -qa | grep -iE 'katello|satellite|insights-client|^rhc-'
rct cat-cert /etc/pki/product-default/*.pem 2>/dev/null | grep -E 'Name:|Version:|Arch:'
```

The kickstart (password lines filtered out) shows the installation source (`url`,
`cdrom`, a Satellite), `selinux --disabled`, `firewall --disabled`, and which accounts
were created on purpose. A `katello-server-ca.pem` under `/etc/rhsm/ca/` means the VM
was prepared for a Satellite.

**C. Question 2: SELinux state in detail**

```bash
cat /proc/cmdline
grep -vE '^\s*(#|$)' /etc/selinux/config
sudo grubby --info=ALL | grep -E '^(kernel|args)'
rpm -q selinux-policy-targeted policycoreutils-python-utils
ls -Z /etc/passwd /opt /home 2>&1
sudo journalctl -b -k | grep -i selinux | head -5
```

`selinux=0` on the command line and `SELINUX=disabled` in the config are the two ways
it can be off; `ls -Z` printing `?` means files carry no labels, so the relabel of
docs/02 §2.1 is required, not optional.

**D. Question 3: what `pmd` and the rsyslog listener are**

```bash
P=$(pgrep -x pmd | head -1); echo "pmd pid: ${P:-not running}"
ps -o pid,user,etime,unit,cmd -p "$P"
sudo readlink /proc/$P/exe
sudo rpm -qf "$(sudo readlink /proc/$P/exe)" 2>&1
sudo rpm -qi "$(sudo rpm -qf "$(sudo readlink /proc/$P/exe)" 2>/dev/null)" 2>/dev/null | grep -E '^(Name|Version|Vendor|Summary|URL|Install Date)'
sudo systemctl status --no-pager "$(ps -o unit= -p "$P")" 2>&1 | head -12
sudo ss -tunpH state established '( sport = :33221 or dport = :33221 )'
echo "--- rsyslog"
grep -vE '^\s*(#|$)' /etc/rsyslog.conf | grep -iE 'module|input|imtcp|imudp|ruleset|@|omfwd|target'
sudo grep -rvhE '^\s*(#|$)' /etc/rsyslog.d/ 2>/dev/null
sudo ss -tnpH state established '( sport = :514 or dport = :514 )'
```

`rpm -qf` names the package and its vendor, or says "not owned by any package" (then
the path under `/opt` or `/usr/local` tells whose agent it is). For rsyslog, `imtcp`
with `input(...)` is a receiver (other hosts send logs here), `@@host:514` in a rule is
a forwarder to a SIEM; the established-connection lines show who actually talks.

**E. Question 5: admin network and Zabbix server**

```bash
sudo grep -hE '^(Server|ServerActive|Hostname|ListenIP)=' /etc/zabbix/zabbix_agentd.conf /etc/zabbix/zabbix_agentd.d/*.conf 2>/dev/null
sudo ss -tnpH state established '( sport = :10050 )'
echo "$SSH_CONNECTION"                                     # client-ip client-port server-ip server-port: your source address now
last -iw | awk '$1 != "reboot" && $3 ~ /^[0-9]/ {print $1, $3}' | sort | uniq -c | sort -rn | head
sudo journalctl -u sshd --since -60d | grep -oE 'Accepted [a-z-]+ for [a-z]+ from [0-9a-f.:]+' | sort | uniq -c
```

`Server=` in the agent config is the Zabbix server allowed to poll (that is the address
for the firewalld rule); `ServerActive=` is where the agent connects out. The login
sources give the admin network for the SSH rule.

**F. Question 4: the `devops` account**

```bash
id devops; sudo passwd -S devops
sudo lastlog -u devops; last devops | head -5
sudo ls -la /home/devops/.ssh/ 2>&1
sudo awk '{print $1, $NF}' /home/devops/.ssh/authorized_keys 2>/dev/null     # key type and comment only
sudo grep -rE 'devops' /etc/sudoers /etc/sudoers.d/ 2>/dev/null; getent group wheel
sudo journalctl -u sshd --since -90d | grep -c 'for devops'
```

**G. Phase 2 context: firewall configuration on disk, time sync**

```bash
systemctl is-enabled firewalld nftables 2>&1
sudo ls -l /etc/firewalld/zones/ 2>&1; sudo cat /etc/firewalld/zones/public.xml 2>/dev/null
sudo nft list ruleset 2>&1 | head -30
chronyc sources 2>&1; timedatectl | head -4
```

**H. Question 7** is about the workstation, not the server: its OS name and version.

## 1.5 Exit criteria

- Findings reviewed together; the open questions answered.
- `docs/02-hardening.md` items marked required / already in place / not applicable.
