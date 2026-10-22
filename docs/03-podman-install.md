# Phase 3: Podman, service account, /opt tree, images

The gateway host has internet access (confirmed after phase 1, see docs/01 §1.4) but
no package repositories yet. Packages and images are therefore fetched **on the
server**; the deployment tree still comes from the repository checkout on the
workstation by `scp` (the server never talks to GitHub, working agreement in README).
Runtime rationale: D-11; image trust chain: D-13 and D-18.

## 3.0 Prerequisite: a package source on the server

`dnf` currently has no repositories (`Not registered`). docs/01 §1.7 established that
the company runs a Red Hat Satellite reached through `capsule.example.org`, that this
host was registered to it before (the capsule CA package, `redhat.repo`, `rhc` and
`insights-client` are installed, and the January 2026 update came from it), and that
direct registration with Red Hat is impossible here (the firewall decrypts TLS to the
Red Hat hosts, and `cdn.redhat.com` authenticates clients with certificates).

**Option A (decided, docs/01 §1.14): register to the Satellite.** Run in phase 2 right
after docs/02 §2.0 sets the hostname and `/etc/hosts` (the Satellite records the name
the host reports at registration time). The Satellite administrator generates a
"global registration" command in the Satellite UI (Hosts, Register Host): a `curl` of
`https://satellite.example.org/register?...` with a bearer token valid for four hours,
piped to `bash`. It carries the activation key, host group, location, organisation and
operating system chosen by the administrator; `update_packages=false` leaves the
update to docs/02 §2.4. The token is a secret: never in the repository or a chat log.

Run it in a reviewable form rather than `curl | bash`: fetch the script with the
Satellite CA that is already installed instead of `--insecure`, read it, then run it as
root. The host's previous record was deleted on the Satellite (rhsm log `410 Gone`,
docs/01 §1.9), so the stale local identity is cleaned first (consumer certificate,
cached entitlements and facts, nothing else):

```bash
getent hosts satellite.example.org
curl -sS --cacert /etc/rhsm/ca/katello-server-ca.pem -o /dev/null -w 'satellite HTTP %{http_code}\n' --max-time 8 https://satellite.example.org/
sudo subscription-manager clean
curl -sS --cacert /etc/rhsm/ca/katello-server-ca.pem -o /tmp/register.sh 'https://satellite.example.org/register?<parameters as generated>' --header 'Authorization: Bearer <token>'
less /tmp/register.sh                     # what it does: installs the CA RPM, registers with the activation key, enables repositories
sudo bash /tmp/register.sh && rm -f /tmp/register.sh
```

If the first `curl` fails with a certificate error, the Satellite uses a different CA
than the capsule; then, and only then, `--insecure` for the two fetches is the
bootstrap the Satellite documentation itself prescribes (the script installs the
proper CA). Verification:

```bash
sudo subscription-manager identity                                     # system identity, org name
sudo subscription-manager status | head -3
grep -E '^(hostname|baseurl)\s*=' /etc/rhsm/rhsm.conf                   # satellite or capsule: the administrator's choice via the host group
sudo subscription-manager repos --list-enabled | grep -E '^Repo ID'   # rhel-10-for-x86_64-baseos-rpms, rhel-10-for-x86_64-appstream-rpms
sudo dnf repolist && sudo dnf -q check-update | head -5
```

If the capsule CA package were missing or stale (`rpm -qi katello-ca-consumer-capsule.example.org`
shows its date), the Satellite owner re-issues it:
`sudo dnf install http://capsule.example.org/pub/katello-ca-consumer-latest.noarch.rpm`
(over HTTP by design, it carries the CA itself; then verify its RPM signature against
the Satellite's key with the owner). Insights and `rhc` are the company's choice; they
were installed with the capsule package and are not part of this deployment.

**Option B (fallback only): the RHEL 10.1 installation ISO as a local repository**, no
updates until repeated with a newer ISO, docs/02 §2.4 then needs a manual monthly refresh:

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

Result (2026-09-15): podman 5.8.2, netavark 1.17.2, aardvark-dns 1.17.1, crun 1.27,
conmon 2.2.1, passt 20251210, container-selinux 2.248.0, skopeo 1.22.2; `/etc/containers`
labelled `etc_t`, `/var/lib/containers` `container_var_lib_t`.

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

Result (2026-09-15): uid 989, gid 988, subuid and subgid `655360:65536`, linger enabled,
home labelled `user_home_dir_t`.

## 3.3 The /opt tree (server, as root)

Disk layout verified 2026-09-15 before creating the tree: UEFI, `/boot/efi` (vfat 600 MB)
and `/boot` (xfs 1 GB) on the 20 GB disk, root LV (xfs, 416 GB, 405 GB free) spanning
that disk's LVM partition and the whole 400 GB second disk, 2 GB swap, volume group
fully allocated; `/tmp` and `/dev/shm` tmpfs with `noexec,nosuid,nodev` (CIS kit).
`/opt`, `/var`, `/var/log`, `/var/log/audit` and `/home` are on root, which CIS would
want separate; XFS cannot shrink and the VG has no free extents, so only a reinstall
would change that. Decision: `/opt/llm-gateway` stays on root (D-23); a dedicated LV
would need a new virtual disk and buys little against 405 GB of headroom and fixed-size
workloads.

```bash
sudo mkdir -p /opt/llm-gateway/{litellm,presidio,postgres/data,network,bin,storage}
sudo chown root:llmgw /opt/llm-gateway && sudo chmod 750 /opt/llm-gateway
sudo chown -R llmgw:llmgw /opt/llm-gateway/{litellm,presidio,postgres,network,bin,storage}
sudo chmod 750 /opt/llm-gateway/{litellm,presidio,network,bin}
sudo chmod 700 /opt/llm-gateway/postgres /opt/llm-gateway/postgres/data /opt/llm-gateway/storage
```

## 3.4 Copy the deployment tree (workstation, then server)

No git client is installed on the workstation (D-24). The branch is downloaded from GitHub
as a ZIP (Code → Download ZIP on the branch, or
`https://github.com/nafud/litellm/archive/refs/heads/<branch>.zip`),
extracted, and the two directories are sent with the OpenSSH `scp` that ships with Windows.
The archive is produced by `git archive`, which applies `.gitattributes`, so the files
arrive with LF endings; the check on the server confirms it. From PowerShell in the
extracted folder (`litellm-<branch>`):

```powershell
scp -r deploy/opt deploy/llmgw sysadmin@192.0.2.10:/tmp/
```

On the server, put the files in place with `llmgw` ownership. The copy must not carry
the modes of the `/tmp` tree (scp creates it as the admin user with mode 700, and
`cp -a` would apply that to `/opt/llm-gateway` and its subdirectories); `--no-preserve=all`
leaves the existing directories from §3.3 untouched. Windows keeps no Unix mode bits, so
the scripts under `bin` get their executable bit back explicitly, by full path because
the admin shell cannot expand a glob inside a directory it may not list. The env
templates are copied as templates only (the real files are created in docs/04 §4.1):

```bash
grep -rl $'\r' /tmp/opt /tmp/llmgw; echo "crlf-check rc=$?"   # must print nothing, rc=1
sudo cp -r --no-preserve=all /tmp/opt/. /opt/llm-gateway/
sudo chown -R llmgw:llmgw /opt/llm-gateway/{litellm,presidio,postgres,network,bin}
sudo chmod 750 /opt/llm-gateway/bin/link-quadlets.sh /opt/llm-gateway/bin/pull-images.sh
sudo install -d -m 700 -o llmgw -g llmgw /home/llmgw/.config /home/llmgw/.config/containers
sudo install -m 600 -o llmgw -g llmgw /tmp/llmgw/storage.conf /home/llmgw/.config/containers/storage.conf
rm -rf /tmp/opt /tmp/llmgw
sudo restorecon -R -v /opt/llm-gateway        # prints nothing when labels are already right
sudo find /opt/llm-gateway -maxdepth 2 -printf '%M %u:%g %p\n'
sudo ls -ldZ /home/llmgw/.config /home/llmgw/.config/containers /home/llmgw/.config/containers/storage.conf
```

`install -d` applies `-o/-g` only to the directories it is given, so `.config` is
named explicitly; a root-owned `.config` makes podman refuse to start ("exists and it is
not owned by the current user").

Repeating this after any change in the repository is the update path (docs/06): download
the ZIP again, `scp`, CRLF check, the same `cp`, chmod, restart the affected unit.

Result (2026-09-16): the first run used `cp -a`, which set `/opt/llm-gateway` to
`sysadmin:sysadmin 700` and the four 750 subdirectories to 700, and the glob chmod failed
as described; files were all correct. Repaired with the §3.3 chown/chmod lines and the
explicit chmod of the two scripts. The same `cp -a` also carried the `user_tmp_t` label
of the `/tmp` tree onto `/opt/llm-gateway` (fixed with `restorecon -R`), and `.config`
had been created root-owned (fixed with `chown llmgw:llmgw` + `chmod 700`). Procedure
above corrected on all three points.

## 3.5 Image store under /opt (server, as root)

`storage.conf` moves the rootless image store to `/opt/llm-gateway/storage`. SELinux
must see it as if it were the default location; this is the procedure from
`containers-storage.conf(5)` for rootless mode:

```bash
rpm -q policycoreutils-python-utils || sudo dnf -y install policycoreutils-python-utils
sudo semanage fcontext -a -e /home/llmgw/.local/share/containers /opt/llm-gateway/storage
sudo restorecon -R -v /opt/llm-gateway/storage
sudo semanage fcontext -l -C            # the equivalence is listed under local customizations
```

(`semanage` is in `policycoreutils-python-utils`.) The equivalence is
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

Result (2026-09-16): exactly that line. Podman's first run created the store under
`/opt/llm-gateway/storage`; the `overlay*` directories were labelled
`container_ro_file_t` through the §3.5 equivalence, the rest `data_home_t`.

## 3.7 Images: pull by pinned digest on the server

Every unit pins `Image=repository:tag@sha256:<linux/amd64 manifest digest>` with
`Pull=never`; `bin/images.tsv` records, per image, the multi-arch index digest the pin
was taken from. The LiteLLM index was cosign-verified with the vendored key when the
pins were chosen (`scripts/verify-pins.sh` on the workstation, D-18); on the server the
pull is by digest, so Podman itself rejects any manifest that does not hash to the pin.

No proxy is in the path on this host (docs/01 §1.4), `ghcr.io` and Docker Hub answered
with valid certificates, and docs/01 §1.8 block A must have shown the layer hosts
(`pkg-containers.githubusercontent.com`, `*.docker.com`) answering too; then nothing
is configured for Podman. (With a proxy it would go into
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

Result (2026-09-16): all four indexes read by digest, all four pulled, four `OK` lines
and the RESULT line. Sizes reported by Podman: LiteLLM 2.01 GB, analyzer 958 MB,
PostgreSQL 464 MB, anonymizer 237 MB; `du` reports 3.5 GB in the store. A `du` run as
`llmgw` prints "Permission denied" for layer directories owned by container users,
which map to the subordinate uid range and are unreadable to `llmgw` itself; that is
expected. Measure the store with `podman system df` as `llmgw` or `sudo du` as the admin.

## 3.8 Egress policy (server)

Now that `llmgw` exists, docs/02 §2.8 could be applied here. Deferred to after phase 5
with the other access restrictions (D-22).

## 3.9 Exit criteria

- `podman info` as `llmgw` reports rootless, SELinux enabled, netavark, crun, graphroot under `/opt`.
- `llmgw` has subordinate id ranges and lingering enabled.
- `/opt/llm-gateway/*` exists with the ownership and modes of §3.3.
- `pull-images.sh` ends with `RESULT: every unit's Image= resolves ...`.
- `sudo ausearch -m AVC -ts recent` shows no denials from the Podman run.
- `sudo nft list table inet llmgw_egress` is loaded (deferred with §3.8, D-22).

Phase 3 closed 2026-09-16 with the first four criteria met and the egress table deferred.
