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

1. **Package source.** With internet access: register with Red Hat (account, or an
   activation key from the customer portal), or use the RHEL 10.1 ISO as a local
   repository with no updates? Commands for both in docs/03 §3.0.
2. **SELinux.** It is disabled. Was that a deliberate choice by whoever built the VM? The
   plan re-enables it (permissive, relabel, then enforcing); confirm before phase 2.
3. **`pmd` on port 33221** and the **rsyslog listener on 514**: what are they, and are they
   corporate standard (keep and allow in firewalld) or leftovers (remove)?
4. **`devops` account**: keep its SSH access or not?
5. **Admin source network** for the SSH firewall rule, and the **Zabbix server address**
   for port 10050.
6. **Internet path**: direct, or through an HTTP proxy? (§1.4 shows it.) A proxy has
   to be configured for `subscription-manager`, `dnf` and Podman. The provider is
   decided later (D-19), so no provider-specific firewall rule is needed now; the host
   policy already limits the service account to TCP 443 (docs/02 §2.8).
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
DNS. `ghcr.io/v2/` and `registry-1.docker.io/v2/` normally answer `401`. Expected
absence: no proxy anywhere, in which case docs/03 §3.0 and §3.7 skip their proxy steps.

## 1.5 Exit criteria

- Findings reviewed together; the open questions answered.
- `docs/02-hardening.md` items marked required / already in place / not applicable.
