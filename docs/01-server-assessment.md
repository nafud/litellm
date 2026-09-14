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
| 1 OS / arch | Docker Engine install path (apt vs dnf), amd64 vs arm64 images (all pinned images are multi-arch) |
| 2 capacity | Presidio analyzer workers (~1 GB RAM each), PostgreSQL `shm_size`, disk for the `pgdata` volume and image cache (plan for at least 10 GB free) |
| 3 accounts | Which accounts to keep, whether a dedicated admin user exists, whether `docker` group grants exist (root-equivalent) |
| 4 SSH | Key-only auth, root login, allowed users, cipher policy |
| 5 network | Which interface/IP LiteLLM should bind to (`LITELLM_BIND_ADDR`), whether a proxy is required for egress |
| 6 firewall | Whether a host firewall exists and how it interacts with Docker's own rules |
| 8 packages | Pending security updates; whether a distro Docker package is already installed (we want docker.com packages) |
| 9 controls | SELinux/AppArmor mode, audit, time sync, sysctl baseline |
| 10 runtime | Existing containers/volumes we must not disturb |
| 11 egress | Confirms the path to `ghcr.io`, Docker Hub and provider APIs; if blocked, image transfer must be done out-of-band |
| 12 ports | Conflicts on 4000/5432/3000 |

## 1.5 Exit criteria

- Report reviewed together, findings listed in the next message.
- `docs/02-hardening.md` items marked as required / not applicable for this host.
- Values for `LITELLM_BIND_ADDR` and `PRESIDIO_ANALYZER_WORKERS` chosen.
