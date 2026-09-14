# Phase 3: Docker Engine, cosign, image verification

## 3.1 Docker Engine from docker.com packages

Distribution packages (`docker.io`, `podman-docker`) lag and are unsupported by upstream.
Remove them if the phase 1 report shows any, then follow the official repository setup for
the detected distribution: <https://docs.docker.com/engine/install/> (choose the page for
the OS in report section 1). The steps are: add Docker's GPG key to
`/etc/apt/keyrings/docker.asc` (or the dnf repo file), add the repository, then

```bash
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo apt-mark hold docker-ce docker-ce-cli containerd.io docker-compose-plugin
```

Apply the daemon configuration from `docs/02-hardening.md` §2.7 **before** starting
anything:

```bash
sudo install -m 644 /dev/stdin /etc/docker/daemon.json <<'JSON'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "5" },
  "live-restore": true,
  "no-new-privileges": true,
  "userland-proxy": false
}
JSON
sudo systemctl enable --now docker
sudo docker info | grep -E 'Server Version|Cgroup Version|Logging Driver|Security Options|Docker Root Dir'
sudo docker compose version
```

Expect Docker Engine 27 or newer and Docker Compose v2 (the compose file uses the
`name:` top-level key, `condition: service_healthy` and YAML anchors, all Compose v2).

If the report showed an HTTP proxy for egress, configure it for the daemon (not just the
shell) via `/etc/systemd/system/docker.service.d/http-proxy.conf` with `HTTPS_PROXY` and
`NO_PROXY=localhost,127.0.0.1`.

## 3.2 `DOCKER-USER` rules

Now that the chain exists, add the rules from `docs/02-hardening.md` §2.6 and persist them.

## 3.3 cosign

Install the release binary and check it against the published checksums:

```bash
V=$(curl -sS https://api.github.com/repos/sigstore/cosign/releases/latest | grep -Po '"tag_name":\s*"v\K[^"]+')
cd /tmp
curl -sSLO "https://github.com/sigstore/cosign/releases/download/v${V}/cosign-linux-amd64"      # arm64: cosign-linux-arm64
curl -sSLO "https://github.com/sigstore/cosign/releases/download/v${V}/cosign_checksums.txt"
grep ' cosign-linux-amd64$' cosign_checksums.txt | sha256sum -c -
sudo install -m 755 cosign-linux-amd64 /usr/local/bin/cosign
cosign version
```

(Debian/RHEL packages `cosign_<V>_amd64.deb` / `.rpm` are in the same release if you
prefer package management.)

## 3.4 Put the repository on the server

```bash
sudo git clone <repo-url> /opt/llm-gateway      # or rsync the checkout
sudo chown -R root:root /opt/llm-gateway && sudo chmod 750 /opt/llm-gateway
```

## 3.5 Pull by digest and verify signatures

```bash
cd /opt/llm-gateway && sudo bash scripts/verify-images.sh
```

Expected: four `docker pull` successes and

```
== ghcr.io/berriai/litellm-non_root:v1.100.1@sha256:c36f3b...
   cosign signature: VERIFIED with litellm-cosign.pub
...
RESULT: all images pulled by digest; LiteLLM signature verified.
```

If any digest fails to pull, the registry no longer serves that manifest; do not "fix"
by removing the digest. Re-resolve the digest deliberately (docs/06-operations.md §6.3)
and record it.

## 3.6 Exit criteria

- `docker info` shows the daemon options; `docker compose version` is v2.
- `iptables -S DOCKER-USER` shows the client allow + drop rules.
- `scripts/verify-images.sh` ends with `RESULT: all images pulled by digest ...`.
