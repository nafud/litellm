# Phase 1: Server assessment (read-only)

Goal: know exactly what we are deploying onto before changing anything. Hardening
(phase 2) is driven by this report, not by a generic checklist.

Nothing in this phase modifies the server.

## 1.1 Get the script onto the server

Either clone the repository (private: use a read-only deploy key or a fine-grained PAT),
or copy the single file:

```bash
# from your workstation, inside this repository
scp scripts/assess.sh <admin>@<server>:/tmp/assess.sh
```

## 1.2 Run it as root

```bash
ssh <admin>@<server>
sudo bash /tmp/assess.sh /tmp/assessment.txt
```

Runtime is under a minute. The script only reads; the only network activity is a
handful of HTTPS HEAD/GET requests to registries and provider APIs (section 11) to learn
whether egress is open, which we need to know before phase 3.

## 1.3 Bring the report back

```bash
# from your workstation
scp <admin>@<server>:/tmp/assessment.txt reports/assessment-$(date +%Y%m%d).txt
```

`reports/` is git-ignored: the report lists users, sudo rules, open ports and key
locations. Keep it out of the repository; share it in the conversation instead.

## 1.4 What we decide from it

| Report section | Decision it drives |
|----------------|--------------------|
| 1 OS / arch | Runtime choice (RHEL 10 -> Podman, DECISIONS.md D-11), amd64 vs arm64 images (all pinned images are multi-arch) |
| 2 capacity | Presidio analyzer workers (~1 GB RAM each), PostgreSQL `shm_size`, disk for the `pgdata` volume and image cache (plan for at least 10 GB free) |
| 3 accounts | Which accounts to keep, whether a dedicated admin user exists, a free subordinate id range for the `llmgw` service account |
| 4 SSH | Key-only auth, root login, allowed users, cipher policy |
| 5 network | Which interface/IP LiteLLM should bind to (`PublishPort=` in the LiteLLM unit), the host resolvers for the egress policy, whether a proxy is required for egress |
| 6 firewall | firewalld zone and rules; nftables backend (needed for the egress policy in docs/02 §2.8) |
| 8 packages | Pending security updates; whether Podman/container-selinux are already installed and at which version |
| 9 controls | SELinux/AppArmor mode, audit, time sync, sysctl baseline |
| 10 runtime | Existing containers, quadlets, subuid ranges and lingering users we must not disturb |
| 11 egress | Confirms the path to `ghcr.io`, Docker Hub, GitHub (cosign, repo clone), Red Hat CDN and provider APIs; if blocked, image transfer must be done out-of-band |
| 12 ports | Conflicts on 4000/5432/3000 |

## 1.5 Facts already established (2026-09-14)

From the commands run so far on the server:

| Item | Value |
|------|-------|
| OS | Red Hat Enterprise Linux 10.1 (Coughlan), kernel 6.12.0-124.28.1.el10_1.x86_64 |
| Admin account | `infosec` (uid 1001), member of `wheel` |
| Memory | 15 GiB total, 14 GiB available, 2 GiB swap |
| Disk | LVM root, 417 GB, 405 GB free (`/opt` and `/home` are on it); `/tmp` is tmpfs (7.7 GB) |
| Boot | EFI |

Still to collect (read-only), all from the admin account:

```bash
rpm -q podman netavark aardvark-dns container-selinux passt shadow-utils-subid skopeo nftables firewalld chrony audit
podman --version 2>/dev/null; getenforce
sudo ss -tulpn
ip -br addr; ip route; cat /etc/resolv.conf
sudo firewall-cmd --state; sudo firewall-cmd --list-all
sudo sshd -T | grep -Ei '^(port|permitrootlogin|passwordauthentication|pubkeyauthentication|allowusers|kbdinteractiveauthentication) '
systemctl is-active chronyd auditd firewalld; sudo subscription-manager status; dnf repolist
cat /etc/subuid /etc/subgid; sysctl user.max_user_namespaces
```

## 1.6 Exit criteria

- Report reviewed together, findings listed in the next message.
- `docs/02-hardening.md` items marked as required / not applicable for this host.
- The LAN address for `PublishPort=` (docs/05 §5.10) and the analyzer `WORKERS` value chosen.
