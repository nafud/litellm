# Phase 3: Podman, service account, /opt tree, images

The gateway host has internet access (confirmed after phase 1, see docs/01 §1.4) but
no package repositories yet. Packages and images are therefore fetched **on the
server**; the deployment tree still comes from the repository checkout on the
workstation by `scp` (the server never talks to GitHub, working agreement in README).
Runtime rationale: D-11; image trust chain: D-13 and D-18.

## 3.0 Prerequisite: a package source on the server

`dnf` currently has no repositories (`Not registered`). docs/01 §1.7 established that
the company runs a Red Hat Satellite reached through `capsule.xalqbank.az`, that this
host was registered to it before (the capsule CA package, `redhat.repo`, `rhc` and
`insights-client` are installed, and the January 2026 update came from it), and that
direct registration with Red Hat is impossible here (the firewall decrypts TLS to the
Red Hat hosts, and `cdn.redhat.com` authenticates clients with certificates).

**Option A (decided, docs/01 §1.14): register to the Satellite.** Run in phase 2 right
after docs/02 §2.0 sets the hostname and `/etc/hosts` (the Satellite records the name
the host reports at registration time). The Satellite administrator generates a
"global registration" command in the Satellite UI (Hosts, Register Host): a `curl` of
`https://satellite.xalqbank.az/register?...` with a bearer token valid for four hours,
piped to `bash`. It carries the activation key, host group, location, organisation and
operating system chosen by the administrator; `update_packages=false` leaves the
update to docs/02 §2.4. The token is a secret: never in the repository or a chat log.

Run it in a reviewable form rather than `curl | bash`: fetch the script with the
Satellite CA that is already installed instead of `--insecure`, read it, then run it as
root. The host's previous record was deleted on the Satellite (rhsm log `410 Gone`,
docs/01 §1.9), so the stale local identity is cleaned first (consumer certificate,
cached entitlements and facts, nothing else):

```bash
getent hosts satellite.xalqbank.az
curl -sS --cacert /etc/rhsm/ca/katello-server-ca.pem -o /dev/null -w 'satellite HTTP %{http_code}\n' --max-time 8 https://satellite.xalqbank.az/
sudo subscription-manager clean
curl -sS --cacert /etc/rhsm/ca/katello-server-ca.pem -o /tmp/register.sh 'https://satellite.xalqbank.az/register?<parameters as generated>' --header 'Authorization: Bearer <token>'
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

If the capsule CA package were missing or stale (`rpm -qi katello-ca-consumer-capsule.xalqbank.az`
shows its date), the Satellite owner re-issues it:
`sudo dnf install http://capsule.xalqbank.az/pub/katello-ca-consumer-latest.noarch.rpm`
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
grep -rl $'\r' /tmp/opt /tmp/llmgw; echo "crlf-check rc=$?"   # must print nothing, rc=1: a checkout made before .gitattributes may carry CRLF
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

## 3.8 Egress policy (server)

Now that `llmgw` exists, apply docs/02 §2.8.

## 3.9 Exit criteria

- `podman info` as `llmgw` reports rootless, SELinux enabled, netavark, crun, graphroot under `/opt`.
- `llmgw` has subordinate id ranges and lingering enabled.
- `/opt/llm-gateway/*` exists with the ownership and modes of §3.3.
- `pull-images.sh` ends with `RESULT: every unit's Image= resolves ...`.
- `sudo nft list table inet llmgw_egress` is loaded; `sudo ausearch -m AVC -ts recent` shows no denials.
