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
| Disk | LVM root 417 GB, 405 GB free; `/tmp` tmpfs 7.7 GB | `/opt/llm-gateway` on root; image archives (~4 GB) must not be unpacked in `/tmp` of a 7.7 GB tmpfs alongside other data |
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
| Egress | ghcr.io, Docker Hub, GitHub, api.anthropic.com, cdn.redhat.com all **time out** | No internet from the host: images, cosign and the repository tree are transferred by scp from the workstation (D-16); provider API access needs a network firewall rule before phase 5 §5.7 |
| cgroups | `cpu memory pids` delegated to user sessions | CPU and memory quotas work for the rootless service account without any drop-in |
| Containers | Podman, skopeo, container-selinux, passt not installed | Installed in phase 3 |
| user namespaces | `user.max_user_namespaces = 62627` | Rootless Podman possible |

## 1.3 Open questions (answers needed before phase 2 starts)

1. **Package source.** Register the host with Red Hat (directly or through a proxy), attach
   it to a Satellite, or use the RHEL 10 installation ISO / an RPM bundle as a local
   repository? Podman, skopeo, passt and container-selinux come from AppStream.
2. **SELinux.** It is disabled. Was that a deliberate choice by whoever built the VM? The
   plan re-enables it (permissive, relabel, then enforcing); confirm before phase 2.
3. **`pmd` on port 33221** and the **rsyslog listener on 514**: what are they, and are they
   corporate standard (keep and allow in firewalld) or leftovers (remove)?
4. **`devops` account**: keep its SSH access or not?
5. **Admin source network** for the SSH firewall rule, and the **Zabbix server address**
   for port 10050.
6. **Provider egress**: who owns the network firewall, and can a rule for the gateway
   host to `api.anthropic.com:443` (and any other chosen provider) be requested now?
7. **Workstation OS** (the machine you SSH from): it needs `skopeo`, `cosign` and `scp`
   to run `scripts/fetch-images.sh`.

## 1.4 Exit criteria

- Findings reviewed together; the open questions answered.
- `docs/02-hardening.md` items marked required / already in place / not applicable.
