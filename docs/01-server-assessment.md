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
| Accounts | `infosec` (uid 1001, wheel, logs in with a password) and `devops` (uid 1000, wheel, `NOPASSWD:ALL`, keys from `ansible-control` and `xbbovsransb001`, 75 logins from 10.100.8.50) | `devops` is the Ansible automation account of the infrastructure team (§1.7); its playbooks may manage files phase 2 changes |
| SSH | port 22, `PermitRootLogin no`, `PasswordAuthentication yes`, keys allowed, `AllowUsers devops infosec` | Password auth to be disabled (docs/02 §2.2) once key login is confirmed |
| Crypto policy | `DEFAULT:NO-WEAKMAC:NO-SSHWEAKMACS` | Fine, keep |
| SELinux | **Disabled** via `SELINUX=disabled` in `/etc/selinux/config` only (no `selinux=0` on the kernel line); files created since are unlabeled (`?`) | Must be re-enabled before deployment (docs/02 §2.1) with a forced relabel; the units rely on it |
| firewalld | installed, **not running** | To be enabled with an explicit inbound policy (docs/02 §2.7) |
| nftables | 1.1.1 installed, service state unknown | Used for the egress policy (docs/02 §2.8) |
| Listening | sshd 22; rsyslogd **TCP 514 on all interfaces**; zabbix_agentd 10050; `pmd` UDP+TCP 33221; chronyd 323 (loopback) | `pmd` is the Cortex XDR agent (keep, §1.7); rsyslog forwards to the SIEM and also runs an unused receiver on 514 (§1.7); Zabbix server is 10.100.7.150 |
| Network | `ens33` 10.50.4.68/24, gateway 10.50.4.254, resolvers 10.100.0.1 and 10.100.0.2 | Egress policy resolvers filled in; LAN address for the client-facing port later |
| Time / audit | chronyd active, auditd active | Keep |
| Subscription | **Not registered, no dnf repositories**; the Satellite capsule CA package is installed and `/etc/rhsm/ca/katello-server-ca.pem` exists | The company runs a Satellite (`capsule.xalqbank.az`); registration there is the package source (docs/03 §3.0 option A) |
| Egress | at assessment time ghcr.io, Docker Hub, GitHub, cdn.redhat.com all **timed out**; **internet access was enabled afterwards** (owner, 2026-09-14) | Packages and images are fetched on the server (D-18); §1.4 re-checks what is reachable and whether a proxy is in the path |
| cgroups | `cpu memory pids` delegated to user sessions | CPU and memory quotas work for the rootless service account without any drop-in |
| Containers | Podman, skopeo, container-selinux, passt not installed | Installed in phase 3 |
| user namespaces | `user.max_user_namespaces = 62627` | Rootless Podman possible |

## 1.3 Open questions (answers needed before phase 2 starts)

1. **Package source.** Answered by §1.7: the company Satellite via
   `capsule.xalqbank.az` (its CA package is installed, `rhc` and `insights-client` too,
   and the January update came through it). Direct Red Hat registration is not an
   option anyway: the firewall decrypts TLS to the Red Hat hosts and `cdn.redhat.com`
   authenticates clients with entitlement certificates, which does not survive
   interception. Needed from the Satellite owner (the `devops` team): an activation key
   and the organisation name, and a content view that carries RHEL 10 BaseOS and
   AppStream. Before registering, the host needs a real hostname (§1.7).
2. **SELinux.** It is disabled. Was that a deliberate choice by whoever built the VM? The
   plan re-enables it (permissive, relabel, then enforcing); confirm before phase 2.
3. **`pmd` on port 33221**: answered (§1.7), it is the Cortex XDR agent, kept. **rsyslog
   listener on 514**: it is a receiver with no clients next to the SIEM forwarder; remove
   the two listener lines, or keep them if the SIEM team says the host is meant to relay.
   Is `/etc/rsyslog.conf` managed by the Ansible playbooks (§1.8 block B tells)?
4. **`devops` account**: the infrastructure team's admin account, used for the XDR
   agent and the CIS build kit; Ansible connected once and nothing under `/etc` is
   playbook-managed (§1.9). Keeping it is the likely answer. Its `NOPASSWD:ALL` sudo and
   password login stay as the team's standard unless you decide otherwise; phase 2 tells
   the team what changed so a future CIS or Ansible run does not revert it.
5. **Zabbix server**: answered, `Server=10.100.7.150` (passive checks; `ServerActive` is
   loopback, so no outbound). **Admin source networks**: logins came from 10.240.234.19
   (you, now), 10.50.12.2 (you), 10.100.8.50 and 10.100.7.60 (`devops`). Name the
   ranges to allow for SSH (a VPN pool and the automation hosts), not single addresses
   if they are dynamic.
6. **Internet path**: answered by §1.4 (2026-09-14): direct via 10.50.4.254, no proxy
   anywhere. Selective: `github.com` 200, `ghcr.io/v2/` and `registry-1.docker.io/v2/`
   401 (open), `subscription.rhsm.redhat.com` and `cdn.redhat.com` 000 (blocked).
   The provider is decided later (D-19), so no provider-specific rule is needed now;
   the host policy limits the service account to TCP 443 (docs/02 §2.8).
7. **Workstation OS** (the machine you SSH from): `scp` is enough for the deployment;
   `skopeo` and `cosign` are needed only to run `scripts/verify-pins.sh` when an image
   pin is chosen or changed (D-18).
8. **Hostname**: the host is `localhost`. Satellite needs a unique FQDN and the SIEM,
   Zabbix and audit records need a stable name. Which name and domain
   (`xalqbank.az` is the company domain seen in the configs)?
9. **SSH key for `infosec`**: logins so far were password logins. A key must be
   installed and tested before docs/02 §2.2 disables passwords (§1.8 block C).

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

## 1.7 Results of the targeted checks (2026-09-14)

| Item | Result | Consequence |
|------|--------|-------------|
| Red Hat hosts | IPv4 fails with "self-signed certificate in certificate chain" (`subscription.rhsm.redhat.com`, `cdn.redhat.com`) and "unable to get local issuer certificate" (`cert-api.access.redhat.com`); no IPv6 address or route; `access.redhat.com`, `pypi.org`, `quay.io`, `api.openai.com` pass with valid TLS | A firewall decryption policy covers the Red Hat content hosts; direct registration is out. Everything the deployment pulls (GHCR, Docker Hub) passed certificate verification, so it is not decrypted; the blob hosts are checked in §1.8 |
| Build | Kickstart from the RHEL 10 ISO on 2025-07-18, minimal environment, no `selinux` line (default enforcing at install), `timesource --ntp-disable`, `network --ipv6=auto` | SELinux was disabled by hand after installation; chrony was configured later (synced to `ntp2/ntp3.xalqbank.az`) |
| Satellite | `katello-ca-consumer-capsule.xalqbank.az-1.0-2` installed, `katello-server-ca.pem` present, `redhat.repo` present, `rhc` and `insights-client` installed; not registered now; `dnf history` shows a 16-package update on 2026-01-22 (kernel 6.12.0-124.28.1.el10_1) | The host was registered to the Satellite at least once and is unregistered now (why is a question for the `devops` team); re-registering restores updates without any internet dependency |
| SELinux | `SELINUX=disabled` in the config; kernel line clean; kernel logs "SELinux: Initializing" then the runtime-disable deprecation notice; `/etc/passwd`, `/home/infosec`, `/opt/traps` unlabeled, `/home/devops` labeled | Policy is simply not loaded; the D-17 procedure applies and the forced relabel is mandatory |
| `pmd` 33221 | `/opt/traps/bin/pmd`, `traps_pmd.service`, "Palo Alto Networks Cortex XDR Agent", not from a package (installed from `/opt/traps/download/installer.rpm` on 2026-01-07), about 1 GiB RSS, 106 threads, no established connections on 33221 | Corporate EDR, kept and never touched. Its memory is part of the OS share of the budget (D-15 amended). Port 33221 is not opened in firewalld unless the XDR administrators say it must be |
| rsyslog | `*.* @@linux-mon.xalqbank.az` (forwards everything to the SIEM over TCP), `imfile` on `/var/log/audit/audit.log`, plus `$ModLoad imtcp` / `$InputTCPServerRun 514` with nobody connected | Forwarding stays (container logs reach the SIEM through the journal); the receiver is unused and is removed in phase 2 unless the SIEM team objects |
| Zabbix | `Server=10.100.7.150`, `ServerActive=127.0.0.1`, `Hostname=Zabbix server` (template default) | firewalld rule: TCP 10050 from 10.100.7.150 only |
| Admin logins | `infosec` by password from 10.240.234.19 and 10.50.12.2; `devops` by key from 10.100.8.50 (`ansible-control`) and 10.100.7.60 | Ranges to be named (question 5); a key for `infosec` before passwords go (question 9) |
| `devops` | uid 1000, wheel, `/etc/sudoers.d/devops: NOPASSWD:ALL`, password set, two keys (`devops@ansible-control`, `devops@xbbovsransb001.xalqbank.az`), three sessions this morning between 10:15 and 10:25 around the 10:22 reboot | Ansible automation account; its playbooks are the thing to understand before phase 2 (§1.8 block B) |
| firewalld / nftables | both `disabled`; `public` zone on disk still has the installer defaults (`ssh`, `dhcpv6-client`, `cockpit`, `forward`); nft ruleset empty | Clean slate for docs/02 §2.7 and §2.8; `cockpit` service is removed from the zone (not installed) |
| Hostname | `localhost` | Set an FQDN before Satellite registration (question 8) |
| Extras | `openssl-devel`, `openssl-perl` and 60 other packages from `install openssl*`, `htop` | Development packages are not needed on a gateway; removal is a phase 2 option, not a requirement |
| Time | chrony synced to two internal servers, timezone Asia/Baku, RTC in UTC | Fine |

## 1.8 Second round of read-only checks

**A. Image pull path: the layer downloads redirect to other hosts than the registries**

```bash
probe() {
  local reg=$1 tok repo=$3 dg=$4 cfg
  tok=$(curl -sS --max-time 10 "$2" | python3 -c 'import json,sys;print(json.load(sys.stdin)["token"])') || { echo "$reg: no token"; return; }
  cfg=$(curl -sS --max-time 10 -H "Authorization: Bearer $tok" -H 'Accept: application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json' \
        "https://$reg/v2/$repo/manifests/$dg" | python3 -c 'import json,sys;print(json.load(sys.stdin)["config"]["digest"])') || { echo "$reg: manifest unreadable"; return; }
  printf '%-24s manifest OK, config blob %s\n' "$reg" "${cfg:0:19}"
  curl -sS --max-time 20 -L -o /dev/null -w '                         blob: HTTP %{http_code} %{size_download} bytes from %{url_effective}\n' \
       -H "Authorization: Bearer $tok" "https://$reg/v2/$repo/blobs/$cfg" 2>&1 | sed -E 's#(https://[^/]+)/.*#\1#'
}
probe ghcr.io 'https://ghcr.io/token?scope=repository:berriai/litellm-non_root:pull' berriai/litellm-non_root sha256:833abd09590afee0119dd574212fb01294dcc7d940ad21fabc0bf0681a9f4aea
probe registry-1.docker.io 'https://auth.docker.io/token?service=registry.docker.io&scope=repository:library/postgres:pull' library/postgres sha256:7341002d2b8c7c5bdd7542a671a95b36196c0b5b888daf454ae4fc33ba5346d7
```

Expected: `HTTP 200` with a few thousand bytes from `pkg-containers.githubusercontent.com`
and from `production.cloudfront.docker.com` (or another `*.docker.com` host). A
certificate error or `000` there means the pull will fail although the registries
answered, and that host has to be exempted from decryption.

**B. What the Ansible playbooks manage on this host (question 4, and phase 2 safety)**

```bash
sudo grep -rlE 'Ansible managed|ansible' /etc 2>/dev/null | head -30
sudo journalctl _COMM=sudo --since -90d | grep 'devops' | grep -oE 'COMMAND=.*' | sed -E 's/[0-9a-f]{32,}//g' | sort | uniq -c | sort -rn | head -25
sudo ls -la /home/devops/ /home/devops/.ansible 2>&1 | head -20
sudo grep -iE 'register|unregister|identity|error' /var/log/rhsm/rhsm.log 2>/dev/null | tail -10
```

The `sudo` journal shows the commands Ansible ran as root (with hashes removed to keep
lines short); files under `/etc` carrying an "Ansible managed" header are the ones a
playbook will rewrite. The rhsm log shows when and why the host left the Satellite.

**C. Satellite reachability and the current rhsm configuration (question 1)**

```bash
grep -E '^(hostname|port|prefix|baseurl|repo_ca_cert)\s*=' /etc/rhsm/rhsm.conf
rpm -qi katello-ca-consumer-capsule.xalqbank.az | grep -E '^(Version|Install Date)'
getent hosts capsule.xalqbank.az
curl -sS --cacert /etc/rhsm/ca/katello-server-ca.pem -o /dev/null -w 'capsule HTTP %{http_code}\n' --max-time 8 https://capsule.xalqbank.az/
curl -sS --cacert /etc/rhsm/ca/katello-server-ca.pem -o /dev/null -w 'rhsm API HTTP %{http_code}\n' --max-time 8 https://capsule.xalqbank.az/rhsm/
sudo grep -vE '^\s*(#|$)' /etc/yum.repos.d/redhat.repo | head -12
hostnamectl
ls -l ~/.ssh/authorized_keys 2>&1
```

`hostname = capsule.xalqbank.az` in `rhsm.conf` and an HTTP code from both URLs mean
the registration path is intact; `redhat.repo` shows which repositories the last
registration enabled (RHEL 10 BaseOS and AppStream are needed). The last line answers
question 9.

**D. Cortex XDR agent details (informational, read-only)**

```bash
sudo /opt/traps/bin/cytool info 2>&1 | head -12
sudo ss -tulpnH sport = :33221
```

Shows the agent version and whether 33221 is bound to loopback or to all addresses.

## 1.5 Exit criteria

- Findings reviewed together; the open questions answered.
- `docs/02-hardening.md` items marked required / already in place / not applicable.

## 1.9 Results of the second round (2026-09-14)

| Item | Result | Consequence |
|------|--------|-------------|
| Image layer hosts | `pkg-containers.githubusercontent.com` and `production.cloudfront.docker.com` both HTTP 200 with valid TLS | The pull path is fully open; docs/03 §3.7 needs nothing more |
| Ansible | No "Ansible managed" file under `/etc` (the two hits are Insights and SELinux context files); no `sudo` use by `devops` in the journal; `~devops/.ansible` created once on 2026-01-07 | The host is not under continuous configuration management; a playbook reverting phase 2 is unlikely, but the `devops` team should be told what changes |
| `devops` home | `CIS-LBK/` (CIS Linux Build Kit, 2025-10-14), the RHEL 10 CIS Benchmark build kit tarball and `cortex-8.9.tar.gz` (2026-01-07), a CIS-CAT report `localhost-CIS_Red_Hat_Enterprise_Linux_10_Benchmark-20260113T171547Z.html` (2026-01-13) | `devops` is the infrastructure team's admin account, used to deploy the XDR agent and to run CIS hardening; the crypto policy `NO-WEAKMAC:NO-SSHWEAKMACS` and other settings probably come from that kit. Phase 2 must inventory what the kit already changed (§1.10 block A) and the CIS report tells the current posture |
| rhsm log | Today at 10:57, 12:10 and 12:28: `HTTP error (410 - Gone): Unit 0066fa1f-... has been deleted` | The host was registered to the Satellite and its record was deleted on the Satellite side (a `localhost` entry is an obvious cleanup candidate). Local rhsm state is stale: `subscription-manager clean` before re-registering (docs/03 §3.0) |
| Capsule | `rhsm.conf` points at `capsule.xalqbank.az` (10.100.8.203, prefix `/rhsm`, content at `/pulp/content`); capsule CA installed 2026-01-07; `/rhsm/` answers 200 with the katello CA; `redhat.repo` empty | Registration path intact; repositories appear once registered |
| Hostname, key | static hostname `localhost`; no `~infosec/.ssh/authorized_keys` | Questions 8 and 9 confirmed |
| Cortex XDR | `cytool info` is not a command; 33221 is bound on `0.0.0.0` for UDP and TCP (TCP backlog 2) | Whether anything must reach 33221 from outside is a question for the XDR administrators; §1.10 block C shows the agent's own outbound connection |

## 1.10 Third round of read-only checks

**A. What the CIS build kit already changed (needed before docs/02 §2.3, §2.5, §2.6)**

```bash
ls -la /etc/sysctl.d/ /etc/ssh/sshd_config.d/ /etc/audit/rules.d/ /etc/modprobe.d/ /etc/security/limits.d/ 2>&1
sudo grep -vE '^\s*(#|$)' /etc/ssh/sshd_config
sudo grep -rvhE '^\s*(#|$)' /etc/sysctl.d/ 2>/dev/null | sort | uniq | head -60
sudo auditctl -l 2>&1 | head -40; sudo ls -l /etc/audit/rules.d/
sudo find /var/log /home/devops/CIS-LBK -maxdepth 3 -iname '*lbk*' -o -maxdepth 3 -iname '*cis*log*' 2>/dev/null | head
sudo grep -E "^> " /home/devops/.viminfo | head -20          # files devops edited by hand
sudo cat /home/devops/.bash_history                          # 166 bytes, today: what was done at the reboot
```

The CIS-CAT report is the current posture in one file. Copy it out to read it in a
browser (the `cp` is the only write, into `/tmp`):

```bash
sudo cp /home/devops/localhost-CIS_Red_Hat_Enterprise_Linux_10_Benchmark-20260113T171547Z.html /tmp/cis-report.html && sudo chown infosec /tmp/cis-report.html
# workstation:  scp infosec@10.50.4.68:/tmp/cis-report.html .   then open it; afterwards rm /tmp/cis-report.html on the server
```

**B. Journal persistence (decides how far back the `sudo` evidence goes)**

```bash
ls -ld /var/log/journal 2>&1; journalctl --list-boots | head -3; journalctl --disk-usage
```

**C. Cortex XDR: outbound only?**

```bash
sudo ss -tnpH state established | grep pmd
sudo journalctl -u traps_pmd.service --since today | tail -5
sudo /opt/traps/bin/cytool -h 2>&1 | grep -iE 'checkin|runtime|status|version|last'
```

An established connection from `pmd` to a Palo Alto address on 443 shows the agent
talks outbound; then no inbound rule is required on 33221, subject to the XDR
administrators' confirmation.

## 1.11 Results of the third round (2026-09-14)

| Item | Result | Consequence |
|------|--------|-------------|
| CIS Build Kit, sshd | Remediation lines in `/etc/ssh/sshd_config` **above** the `Include sshd_config.d` line: `PermitRootLogin no`, `MaxAuthTries 4`, `LoginGraceTime 60`, `ClientAliveInterval 15` / `CountMax 3`, `LogLevel VERBOSE`, `MaxStartups`, `MaxSessions 10`, `PermitEmptyPasswords no`, `PermitUserEnvironment no`, `HostbasedAuthentication no`, `IgnoreRhosts yes`, `Banner /etc/issue.net`, `AllowUsers`/`AllowGroups devops infosec`, `DenyUsers`/`DenyGroups root` | sshd keeps the first value read, so these cannot be changed by a drop-in; `deploy/host/10-sshd-hardening.conf` was reduced to what CIS did not set (password and keyboard-interactive off, no X11/agent forwarding, local TCP forwarding) |
| CIS, sysctl | `/etc/sysctl.d/60-{fs,ipv4,ipv6,kernel}_sysctl.conf` (2026-01-07): dumpable, dmesg, ASLR, ptrace, redirects, source routing, forwarding off, martians, rp_filter, syncookies, IPv6 RA | `deploy/host/90-hardening.conf` reduced to the missing keys |
| CIS, modules | blacklists for `sctp`, `tipc`, `can`, `l2tp*`, `usb-storage` | Nothing Podman needs |
| CIS, audit | full rule set in `/etc/audit/rules.d/50-*.rules` and `privileged.rules`, `99-finalize.rules` = `-e 2`. **All rule files are owned `devops:devops`** (644, `audit.rules` 600) | Runtime turned out mutable (§1.13), so rules can be loaded at any time; the gateway rules still go in before the SELinux reboot (docs/02 §2.1) to be verified once. Ownership is fixed to `root:root 640` in the same step (CIS conformance; `/etc/audit` itself is root 750) |
| SELinux | `devops` edited `/etc/selinux/config` with vim (viminfo, bash history: `sestatus`, `vim /etc/selinux/config`) | Disabled by hand by the infrastructure team on 2026-01-07; they are informed before phase 2 re-enables it |
| Journal | `/var/log/journal` absent: volatile journal, 8 MB, only since the 10:22 boot | The `sudo` evidence of §1.9 covers today only. Made persistent in docs/02 §2.5, container logs depend on it |
| Cortex XDR | established connection from `pmd` to 10.100.1.100:8888 (a Cortex XDR Broker VM); `cytool status`, `last_checkin`, `runtime query`, `websocket query` exist | Outbound only, to an internal broker; no inbound rule on 33221 expected. `cytool status` is the post-change health check |
| `devops` history | `yum install openssl*`, `sestatus`, `vim /etc/selinux/config`, `lsblk`, `vgs`, `sudo -i` | Consistent with the January work (XDR, CIS kit, SELinux off); nothing automated |
| CIS-CAT report | copied to `/tmp/cis-report.html` on the server | To be fetched and read (§1.12) |

## 1.12 Remaining reads

```bash
sudo ls -la /etc/ssh/sshd_config.d/ && sudo cat /etc/ssh/sshd_config.d/*.conf
sudo grep -E '^Defaults' /etc/sudoers
cat /etc/security/limits.d/60-security_limits.conf
sudo auditctl -s | grep -E '^(enabled|backlog_limit|lost)'
stat -c '%U:%G %a %n' /etc/audit /etc/audit/rules.d /etc/audit/auditd.conf 2>&1
```

And on the workstation: `scp infosec@10.50.4.68:/tmp/cis-report.html .`, open it, paste
the summary (pass/fail counts per section); then `rm /tmp/cis-report.html` on the server.

## 1.13 Results of the remaining reads (2026-09-14)

| Item | Result | Consequence |
|------|--------|-------------|
| sshd drop-ins | only RHEL's `40-redhat-crypto-policies.conf` and `50-redhat.conf` (root, 600) | `10-sshd-hardening.conf` sorts before both and wins inside the include for the keys it sets (`X11Forwarding` is the one RHEL's file also sets) |
| sudoers | stock RHEL `Defaults` (`env_reset`, `secure_path`, no `logfile`, no `use_pty`) | sudo events reach the SIEM through authpriv already; the CIS `-w /var/log/sudo.log` watch points at a file that does not exist. Optional CIS items for §2.2, not required by the deployment |
| limits | `* hard core 0` | Fine; containers inherit it, nothing needs core dumps |
| audit runtime | `enabled 1`, `backlog_limit 8192`, `lost 0` | The configuration is **not** immutable at runtime although `99-finalize.rules` contains `-e 2`; `augenrules --load` will apply new rules immediately. Whether the next boot ends immutable depends on where `augenrules` places the `-e` line; §2.1 installs the rules before the reboot and verifies after it either way |
| `/etc/audit` | `root:root 750` | `devops` cannot reach its own rule files without `sudo` (which it has without a password); the ownership fix stays as a CIS conformance item, severity lower than first assessed |
| CIS-CAT report | fetched by the owner, `/tmp` copy removed | Summary to be pasted when convenient; not blocking |

Phase 1 is complete with this round. Everything else is a decision (§1.3).

## 1.14 Decisions taken by the owner (2026-09-15)

| Question | Decision |
|----------|----------|
| 1 Package source | Satellite registration, after the hostname is set. Activation key and organisation name to be obtained from the infrastructure team |
| 2 SELinux | Re-enable (D-17) |
| 3 rsyslog 514 | Remove the unused receiver; keep the SIEM forwarder |
| 4 `devops` | Keep, unchanged; the team is informed of phase 2 changes |
| 5 SSH source ranges | still open: which ranges the owner and the automation hosts connect from |
| 7 Workstation | Windows (PowerShell); the built-in OpenSSH client provides `ssh`, `scp`, `ssh-keygen`; there is no `ssh-copy-id`. `.gitattributes` forces LF line endings so a Windows checkout does not corrupt the files copied to the server |
| 8 Hostname | `xbbovsrlllm001.xalqbank.az`, following the company pattern (`xbbovsransb001`). The owner's first proposal embedded the IP address; dots inside a hostname are label separators and an all-digit last label is invalid, so the address stays in DNS and `/etc/hosts` |
| 8b XDR 33221 | No inbound rule; `cytool status` checked after firewalld comes up |
| CIS-CAT baseline (2026-01-13) | 881 pass, 146 fail, 34 manual, 1 error (result cells counted in the HTML report; the file stays outside the repository) |
