# Phase 3: Podman, service account, /opt tree, image transfer

The gateway host has no internet access and no package repositories (phase 1). This
phase therefore has two sides: the **workstation** (internet, `scp` to the server) and
the **server**. Runtime rationale: D-11; transfer design: D-16.

## 3.0 Prerequisite: a package source on the server

`dnf` currently has no repositories (`Not registered`, `No repositories available`).
One of these must be in place first; the choice is the phase 1 open question 1:

| Option | What it needs | Result |
|--------|---------------|--------|
| Red Hat registration | outbound HTTPS to `subscription.rhsm.redhat.com` and `cdn.redhat.com`, directly or via a proxy (`subscription-manager config --server.proxy_hostname=... --server.proxy_port=...`) | BaseOS + AppStream, updates keep flowing |
| Satellite / Capsule | the internal Satellite host reachable, its CA and activation key | same, through the internal server |
| RHEL 10.1 installation ISO | the ISO copied to the server (`scp`) and mounted; two `.repo` entries pointing at `BaseOS` and `AppStream` on the mount | one-time install, no updates until repeated with a newer ISO |

Podman, skopeo, passt, container-selinux and systemd-container are all in AppStream.
Commands for the chosen option are added here once decided.

## 3.1 Packages (server)

```bash
sudo dnf -y install podman skopeo passt container-selinux systemd-container
rpm -q podman netavark aardvark-dns crun conmon passt container-selinux shadow-utils-subid skopeo systemd-container
podman --version
sudo ausearch -m AVC -ts recent | tail -5      # SELinux is permissive at this point (docs/02 §2.1)
```

Expect Podman 5.x. The Quadlet keys used by the units were checked against the 5.4 and
5.6 manual pages (`podman-systemd.unit(5)`); the key table is identical in both.

## 3.2 Service account (server)

```bash
sudo useradd --system --add-subids-for-system --create-home --home-dir /home/llmgw \
  --shell /bin/bash --comment "LLM gateway service account" llmgw
grep -E '^llmgw:' /etc/subuid /etc/subgid        # one range of 65536 ids in each file
sudo loginctl enable-linger llmgw
ls /var/lib/systemd/linger/                       # llmgw listed
```

- `--system`: uid below 1000, no password, no aging. System accounts get no subordinate
  id range unless `--add-subids-for-system` is given (shadow-utils 4.14+, RHEL 10 ships
  4.15). If the `grep` prints nothing, allocate a free range by hand: the existing
  ranges end at 589824+65536, so
  `sudo usermod --add-subuids 655360-720895 --add-subgids 655360-720895 llmgw`.
- Linger starts the user's systemd manager at boot, so the units run without a login and
  keep running after the admin logs out.
- `/bin/bash` is needed to operate the stack as this user; SSH login stays impossible
  (no password, not in `AllowUsers`).

## 3.3 The /opt tree (server, as root)

```bash
sudo mkdir -p /opt/llm-gateway/{litellm,presidio,postgres/data,network,bin,storage}
sudo chown root:llmgw /opt/llm-gateway && sudo chmod 750 /opt/llm-gateway
sudo chown -R llmgw:llmgw /opt/llm-gateway/{litellm,presidio,postgres,network,bin,storage}
sudo chmod 750 /opt/llm-gateway/{litellm,presidio,network,bin}
sudo chmod 700 /opt/llm-gateway/postgres /opt/llm-gateway/postgres/data /opt/llm-gateway/storage
```

## 3.4 Copy the deployment tree (workstation, then server)

From the repository checkout on the workstation:

```bash
scp -r deploy/opt deploy/llmgw infosec@10.50.4.68:/tmp/
```

On the server, put the files in place with `llmgw` ownership. `cp -a` preserves the
executable bit of the scripts; the env templates are copied as templates only (the real
files are created in docs/04 §4.1):

```bash
sudo cp -a /tmp/opt/. /opt/llm-gateway/
sudo chown -R llmgw:llmgw /opt/llm-gateway/{litellm,presidio,postgres,network,bin}
sudo install -d -m 700 -o llmgw -g llmgw /home/llmgw/.config/containers
sudo install -m 600 -o llmgw -g llmgw /tmp/llmgw/storage.conf /home/llmgw/.config/containers/storage.conf
rm -rf /tmp/opt /tmp/llmgw
find /opt/llm-gateway -maxdepth 2 -printf '%M %u:%g %p\n'
```

Repeating this after any change in the repository is the update path (docs/06): copy,
`cp -a`, restart the affected unit.

## 3.5 Image store under /opt (server, as root)

`storage.conf` moves the rootless image store to `/opt/llm-gateway/storage`. SELinux
must see it as if it were the default location; this is the procedure from
`containers-storage.conf(5)` for rootless mode:

```bash
sudo semanage fcontext -a -e /home/llmgw/.local/share/containers /opt/llm-gateway/storage
sudo restorecon -R -v /opt/llm-gateway/storage
```

(`semanage` is in `policycoreutils-python-utils`, already installed.) The equivalence is
recorded in the SELinux policy store, so it survives relabels and reboots.

## 3.6 Working as the service account (server)

Podman and `systemctl --user` need a login session for `llmgw`; `machinectl` opens one
(the method Podman's troubleshooting guide recommends over `sudo -u` / `su -`):

```bash
sudo machinectl shell llmgw@
systemctl --user status | head -3             # State: running
podman info --format 'rootless={{.Host.Security.Rootless}} selinux={{.Host.Security.SELinuxEnabled}} backend={{.Host.NetworkBackend}} runtime={{.Host.OCIRuntime.Name}} graphroot={{.Store.GraphRoot}}'
```

Expected: `rootless=true selinux=true backend=netavark runtime=crun graphroot=/opt/llm-gateway/storage`.
Commands written as `llmgw$` below run in this session.

## 3.7 Images: fetch and verify on the workstation, load and verify on the server

**Workstation** (needs `skopeo`, `cosign`, `python3`; install commands depend on its OS,
phase 1 question 7):

```bash
scripts/fetch-images.sh            # writes images/*.tar and images/SHA256SUMS
```

For each of the four images the script: cosign-verifies the multi-arch index with the
vendored key (LiteLLM only, the other projects do not sign), reads that index from the
registry and checks it lists the pinned `linux/amd64` digest, copies exactly that
manifest into an OCI archive, checks the archive's digest equals the pin, and checks the
units pin the same value. Expect `RESULT: archives in ... verified`. Then:

```bash
scp images/*.tar images/SHA256SUMS infosec@10.50.4.68:/tmp/images/
```

About 4 GB in total; `/tmp` on the server is a 7.7 GB tmpfs, so copy, load, delete.

**Server**, as `llmgw`:

```bash
llmgw$ bash /opt/llm-gateway/bin/verify-images.sh /tmp/images
```

Expected ending:

```
OK       ghcr.io/berriai/litellm-non_root:v1.100.1@sha256:833abd...
OK       docker.io/library/postgres:18.6@sha256:7341002d...
OK       ghcr.io/data-privacy-stack/presidio-analyzer:2.2.364@sha256:674328b4...
OK       ghcr.io/data-privacy-stack/presidio-anonymizer:2.2.364@sha256:65a9f96c...
RESULT: every unit's Image= resolves in local storage by digest.
```

Then `sudo rm -rf /tmp/images`. Why this chain is sound: the digest in each unit is the
`linux/amd64` manifest digest, which Podman recomputes from the loaded bytes and matches
against `Image=` with `Pull=never` (verified with Podman on 2026-09-14, D-16); the
workstation proved that this digest is the one listed by the cosign-signed index.

## 3.8 Egress policy (server)

Now that `llmgw` exists, apply docs/02 §2.8.

## 3.9 Exit criteria

- `podman info` as `llmgw` reports rootless, SELinux enabled, netavark, crun, graphroot under `/opt`.
- `llmgw` has subordinate id ranges and lingering enabled.
- `/opt/llm-gateway/*` exists with the ownership and modes of §3.3.
- `verify-images.sh` ends with `RESULT: every unit's Image= resolves ...`.
- `sudo nft list table inet llmgw_egress` is loaded; `sudo ausearch -m AVC -ts recent` shows no denials.
