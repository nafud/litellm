# Phase 3: Podman, service account, cosign, image verification

Runtime decision and rationale: DECISIONS.md D-11. Everything the stack needs comes from
Red Hat's own repositories except cosign (a static binary from the sigstore project).

## 3.1 Packages

```bash
sudo dnf -y install podman skopeo passt container-selinux systemd-container
rpm -q podman netavark aardvark-dns crun conmon passt container-selinux shadow-utils-subid skopeo
podman --version
```

Expect Podman 5.x. The Quadlet keys used by `deploy/quadlet/*.container` were checked
against the 5.4 and 5.6 manual pages (`podman-systemd.unit(5)`); the same key table
applies to both. `passt` provides the rootless network path (`pasta`), `skopeo` is used
in operations to resolve digests, `systemd-container` provides `machinectl shell`.

No Docker packages, no `podman-docker`, no `docker` group.

## 3.2 Service account

```bash
sudo useradd --system --add-subids-for-system --create-home --home-dir /home/llmgw \
  --shell /bin/bash --comment "LLM gateway service account" llmgw
grep -E '^llmgw:' /etc/subuid /etc/subgid        # one range of 65536 ids in each file
sudo loginctl enable-linger llmgw
ls /var/lib/systemd/linger/                       # llmgw listed
```

- `--system`: uid below 1000, no password, no aging. A system account gets no
  subordinate id range by default; `--add-subids-for-system` requests one (shadow-utils
  4.14+, RHEL 10 ships 4.15). If the `grep` prints nothing, allocate a free range by hand
  after checking `/etc/subuid` for overlaps:
  `sudo usermod --add-subuids 200000-265535 --add-subgids 200000-265535 llmgw`.
- Linger starts the user's systemd manager at boot, so the Quadlet units run without
  anyone logging in and keep running after the admin logs out.
- `/bin/bash` is needed to operate the stack as this user; SSH login is still impossible
  (no password, not in `AllowUsers`).

## 3.3 Working as the service account

Podman and `systemctl --user` need a proper login session for `llmgw`. Open one with
`machinectl` (this is the method the Podman troubleshooting guide recommends over
`sudo -u`/`su -`):

```bash
sudo machinectl shell llmgw@
systemctl --user status | head -3             # State: running
podman info --format 'rootless={{.Host.Security.Rootless}} selinux={{.Host.Security.SELinuxEnabled}} backend={{.Host.NetworkBackend}} runtime={{.Host.OCIRuntime.Name}} graphroot={{.Store.GraphRoot}}'
```

Expected: `rootless=true selinux=true backend=netavark runtime=crun graphroot=/home/llmgw/.local/share/containers/storage`.

Fallback without `machinectl`: `sudo -iu llmgw`, then
`export XDG_RUNTIME_DIR=/run/user/$(id -u) DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus`.

All later commands written as `llmgw$` run inside this session.

## 3.4 cosign

cosign is not packaged by Red Hat. Install the release binary and check it against the
checksum file published with the same release:

```bash
V=<cosign version from https://github.com/sigstore/cosign/releases/latest, e.g. 2.5.3>
cd /tmp
curl -sSLO "https://github.com/sigstore/cosign/releases/download/v${V}/cosign-linux-amd64"
curl -sSLO "https://github.com/sigstore/cosign/releases/download/v${V}/cosign_checksums.txt"
grep ' cosign-linux-amd64$' cosign_checksums.txt | sha256sum -c -
sudo install -m 755 -o root -g root cosign-linux-amd64 /usr/local/bin/cosign
cosign version
```

(`cosign-<V>-1.x86_64.rpm` in the same release is an alternative if you prefer rpm.)

## 3.5 Deployment directory and repository checkout

```bash
sudo mkdir -p /opt/llm-gateway/repo /opt/llm-gateway/env /opt/llm-gateway/data/postgres
sudo chown root:llmgw /opt/llm-gateway && sudo chmod 750 /opt/llm-gateway
sudo chown -R llmgw:llmgw /opt/llm-gateway/repo /opt/llm-gateway/env /opt/llm-gateway/data
sudo chmod 750 /opt/llm-gateway/repo
sudo chmod 700 /opt/llm-gateway/env /opt/llm-gateway/data /opt/llm-gateway/data/postgres
```

Then, as `llmgw`, clone this repository into `repo/`. The checkout must be owned by
`llmgw` because Podman relabels the bind-mounted `config.yaml` (`:Z`), which requires
file ownership. Use a **read-only** credential (a fine-grained personal access token with
`Contents: read` on this repository, or a read-only deploy key):

```bash
llmgw$ git clone https://github.com/nafud/litellm.git /opt/llm-gateway/repo
llmgw$ cd /opt/llm-gateway/repo && git log --oneline -1
```

If the server has no route to GitHub, copy the checkout instead:
`scp -r <workstation-checkout> llmgw@...` is not possible (no SSH login for llmgw), so
`scp` to the admin account and `sudo cp -a ... && sudo chown -R llmgw:llmgw /opt/llm-gateway/repo`.

## 3.6 Pull by digest and verify signatures

```bash
llmgw$ bash /opt/llm-gateway/repo/scripts/verify-images.sh
```

Expected: four pulls and

```
== ghcr.io/berriai/litellm-non_root:v1.100.1@sha256:c36f3b...
   pulled: ghcr.io/berriai/litellm-non_root@sha256:c36f3b...
   cosign signature: VERIFIED with litellm-cosign.pub
...
RESULT: all images pulled by digest; LiteLLM signature verified.
llmgw$ podman images --digests
```

If a digest fails to pull, the registry no longer serves that manifest; do not "fix" it
by removing the digest. Re-resolve deliberately (docs/06-operations.md §6.3) and record it.

Why the script and not Podman's own signature policy: Podman can enforce sigstore
signatures at pull time (`policy.json`, `sigstoreSigned`), but it looks for a signature
on the platform manifest it pulls, and LiteLLM signs only the multi-arch index. Tested on
2026-09-14 with skopeo against the pinned image: the policy rejects it with "A signature
was required, but no signature exists". cosign verifies the index, which is the digest we
pin, so the pull-by-digest + cosign pair is the enforcement point (DECISIONS.md D-13).

## 3.7 Egress policy

Now that `llmgw` exists, apply docs/02-hardening.md §2.8 and confirm the image pull still
works afterwards (`podman pull` uses TCP 443 only):

```bash
llmgw$ podman pull --quiet docker.io/library/postgres@sha256:4ef4dbc939d61acea57712655ddb4b4ab27419c913f94cca0cd57cb3ea3c2280
```

## 3.8 Exit criteria

- `podman info` as `llmgw` reports rootless, SELinux enabled, netavark, crun.
- `llmgw` has subordinate id ranges and lingering enabled.
- `/opt/llm-gateway/{repo,env,data}` exist with the ownership and modes above.
- `scripts/verify-images.sh` ends with `RESULT: all images pulled by digest ...`.
- `sudo nft list table inet llmgw_egress` is loaded and pulls still succeed.
