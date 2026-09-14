# Phase 3: Podman, service account, /opt tree, images

The gateway host has internet access (confirmed after phase 1, see docs/01 §1.4) but
no package repositories yet. Packages and images are therefore fetched **on the
server**; the deployment tree still comes from the repository checkout on the
workstation by `scp` (the server never talks to GitHub, working agreement in README).
Runtime rationale: D-11; image trust chain: D-13 and D-18.

## 3.0 Prerequisite: a package source on the server

`dnf` currently has no repositories (`Not registered`, `No repositories available`).
With internet access the normal path is registration with Red Hat; the ISO remains the
fallback if no subscription is available (phase 1 open question 1 decides).

**Option A: register with Red Hat** (needs a Red Hat account or an activation key from
the customer portal; RHEL 10 uses Simple Content Access, so no `attach` step). On
2026-09-14 the network firewall blocked `subscription.rhsm.redhat.com` and
`cdn.redhat.com` (docs/01 §1.4); both must be allowed for this host on TCP 443 first,
and the §1.4 loop must show an HTTP code for both before running this:

```bash
sudo subscription-manager register --username <portal-user>            # prompts for the password
# or, with an activation key:
sudo subscription-manager register --org <org-id> --activationkey <key-name>
sudo subscription-manager status                                        # Overall Status: Registered (or Disabled, with SCA)
sudo dnf repolist                                                       # rhel-10-for-x86_64-baseos-rpms, rhel-10-for-x86_64-appstream-rpms
```

If the host reaches the internet through an HTTP proxy (docs/01 §1.4 tells), set it for
both tools before registering, otherwise skip this block:

```bash
sudo subscription-manager config --server.proxy_hostname=<proxy> --server.proxy_port=<port>
echo 'proxy=http://<proxy>:<port>' | sudo tee -a /etc/dnf/dnf.conf
```

**Option B: RHEL 10.1 installation ISO as a local repository** (no updates until
repeated with a newer ISO; docs/02 §2.4 then needs a manual monthly refresh):

```bash
sudo mkdir -p /mnt/rhel10 && sudo mount -o ro,loop /path/to/rhel-10.1-x86_64-dvd.iso /mnt/rhel10
sudo tee /etc/yum.repos.d/rhel10-iso.repo >/dev/null <<'EOT'
[rhel10-iso-baseos]
name=RHEL 10.1 ISO BaseOS
baseurl=file:///mnt/rhel10/BaseOS
enabled=1
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-redhat-release
[rhel10-iso-appstream]
name=RHEL 10.1 ISO AppStream
baseurl=file:///mnt/rhel10/AppStream
enabled=1
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-redhat-release
EOT
sudo dnf repolist
```

Podman, skopeo, passt, container-selinux and systemd-container are all in AppStream.

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

## 3.7 Images: pull by pinned digest on the server

Every unit pins `Image=repository:tag@sha256:<linux/amd64 manifest digest>` with
`Pull=never`; `bin/images.tsv` records, per image, the multi-arch index digest the pin
was taken from. The LiteLLM index was cosign-verified with the vendored key when the
pins were chosen (`scripts/verify-pins.sh` on the workstation, D-18); on the server the
pull is by digest, so Podman itself rejects any manifest that does not hash to the pin.

No proxy is in the path on this host (docs/01 §1.4), and `ghcr.io` and Docker Hub
answered, so nothing to configure for Podman. (With a proxy it would go into
`~llmgw/.config/environment.d/proxy.conf` as `https_proxy=`.)

**Server**, as `llmgw`:

```bash
llmgw$ bash /opt/llm-gateway/bin/pull-images.sh
```

For each of the four images the script reads the index from the registry by its pinned
digest, checks that it lists the pinned `linux/amd64` digest, pulls exactly
`repository:tag@digest` (the string the unit uses), and finally checks every `Image=`
line resolves in local storage. Expected ending:

```
OK       ghcr.io/berriai/litellm-non_root:v1.100.1@sha256:833abd...
OK       docker.io/library/postgres:18.6@sha256:7341002d...
OK       ghcr.io/data-privacy-stack/presidio-analyzer:2.2.364@sha256:674328b4...
OK       ghcr.io/data-privacy-stack/presidio-anonymizer:2.2.364@sha256:65a9f96c...
RESULT: every unit's Image= resolves in local storage by digest.
```

About 4 GB lands in `/opt/llm-gateway/storage`. Docker Hub (PostgreSQL) allows
anonymous pulls at a limited rate; one pull is far below it. Verified with Podman on
2026-09-14 (D-18): an image pulled as `name:tag@digest` is stored without the tag and
resolves under that exact reference with `--pull=never`; a wrong digest is refused at
pull ("manifest unknown") and at lookup ("image not known").

## 3.8 Egress policy (server)

Now that `llmgw` exists, apply docs/02 §2.8.

## 3.9 Exit criteria

- `podman info` as `llmgw` reports rootless, SELinux enabled, netavark, crun, graphroot under `/opt`.
- `llmgw` has subordinate id ranges and lingering enabled.
- `/opt/llm-gateway/*` exists with the ownership and modes of §3.3.
- `pull-images.sh` ends with `RESULT: every unit's Image= resolves ...`.
- `sudo nft list table inet llmgw_egress` is loaded; `sudo ausearch -m AVC -ts recent` shows no denials.
