# Security and design decisions

Each entry: what was decided, why, and what it depends on. Amend rather than delete.

## D-01 Image selection and pinning
- LiteLLM: `ghcr.io/berriai/litellm-non_root:v1.100.1` (latest stable, 2026-09-10).
  The non-root variant runs as uid 65534 and bakes the Prisma engines into `/opt/prisma`,
  so it supports PostgreSQL without any runtime download. BerriAI's own docs now advise
  pinning a version tag rather than `latest`/`main-stable`; `main-stable` currently
  resolves to the same digest as `v1.100.1`. Registry `docker.litellm.ai` is only a
  mirror of `ghcr.io/berriai`; we use the origin.
- Presidio: `2.2.364` from `ghcr.io/data-privacy-stack` (project moved out of the
  Microsoft org; `mcr.microsoft.com` images are legacy). A `-distroless-preview` variant
  exists but is four days old and labelled preview; not adopted.
- PostgreSQL: `18.6` (current minor of the current major). Note the 18 image changed
  `PGDATA` to `/var/lib/postgresql/18/docker` and the volume mount point to
  `/var/lib/postgresql`; mounting at the pre-18 path `/var/lib/postgresql/data` would
  silently fail to persist data.
- All four images are pinned `tag@sha256:digest` (fully qualified, including
  `docker.io/library/` for PostgreSQL, because Podman does not resolve short names in a
  non-interactive service), and the digests were read from the registries' manifest APIs
  on 2026-09-14. Updating = change tag + digest together on the unit's `Image=` line,
  then `scripts/verify-pins.sh` on the workstation and `bin/pull-images.sh` on the server (D-18).

## D-02 Signature verification
LiteLLM signs all `ghcr.io/berriai/*` images with one cosign key. The key is vendored in
`deploy/opt/bin/` (provenance in `COSIGN-KEY.md`). Presidio and PostgreSQL images are not
verified by signature; integrity relies on the digest pin. Verification runs with the
cosign binary, not Podman's pull-time policy: see D-13 for why.

## D-03 Provider keys live only in the LiteLLM environment
`STORE_MODEL_IN_DB=False` and `store_model_in_db: false`: models and provider keys come
from `config.yaml` + `litellm.env` only. Nothing in the admin UI can add a provider key
to the database. `LITELLM_SALT_KEY` is still set because LiteLLM uses it to encrypt any
credential-bearing object that does land in the DB; it must never change once data exists.

## D-04 Presidio guardrail semantics (verified in litellm 1.100.1 source)
- `mode: pre_call` + `output_parse_pii: true`: masking happens before the provider call;
  LiteLLM automatically appends `post_call` so the response (including streaming) has the
  `<PERSON_1>`-style tokens replaced with the original values.
- `default_on: true`: applies to every request; callers cannot opt out.
- With `pii_entities_config` set, an analyzer error or non-JSON reply raises a guardrail
  exception and the request is rejected. This is fail-closed by design: an outage of
  Presidio blocks traffic rather than leaking unmasked prompts.
- Endpoints are read from `PRESIDIO_ANALYZER_API_BASE` / `PRESIDIO_ANONYMIZER_API_BASE`.
- Language is `en`; the stock analyzer image contains only the English spaCy model.
  Multilingual detection requires a custom analyzer configuration (future decision).

## D-05 Network segmentation inside Podman
- `llmgw-backend` is an `Internal=true` network: no default route, no masquerading, so
  PostgreSQL and Presidio have no path out of the host. Only `litellm` is also on
  `llmgw-egress`. Name resolution is aardvark-dns, container names only.
- Nothing but LiteLLM publishes a port, and only on `127.0.0.1` until validation is done
  (`PublishPort=` in the unit; changed by commit, docs/05 §5.10). PostgreSQL is never
  reachable from the host network.
- Rootless Podman gives one more control for free: all container egress leaves through
  `pasta`, a process owned by `llmgw`, so a host nftables policy keyed on that uid
  (`deploy/host/llmgw-egress.nft`) restricts the stack to TCP 443 + DNS. The FQDN-level
  allow-list of provider APIs remains the network firewall's job, as in the architecture.

## D-06 Container hardening
- All services: rootless (no container process is root on the host), `NoNewPrivileges`,
  `DropCapability=all`, journald logging, `Restart=always`, `Pull=never` (images are
  pulled and verified deliberately; a service restart never touches the network),
  digest-pinned images, `Notify=healthy` so dependents start only after health.
- PostgreSQL runs as uid 999 directly, so the entrypoint's root-only chown/gosu path is
  skipped and no capability is needed. `UserNS=keep-id:uid=999,gid=999` maps the host
  user `llmgw` to uid 999 inside the container, so the bind-mounted data directory stays
  owned by `llmgw` on the host: readable for backups and inspection without
  `podman unshare`, and no recursive chown (`:U`) on every start.
- Presidio containers are `ReadOnly=true`; Podman's `ReadOnlyTmpfs` default provides
  the writable `/tmp` gunicorn needs for heartbeat files. If phase 5 shows either
  container unhealthy because of a write, the fix is a narrower tmpfs, not dropping
  `ReadOnly`.
- Presidio and LiteLLM (stateless) set `HealthOnFailure=kill`: an unhealthy container is
  killed and systemd restarts it. PostgreSQL does not: a spurious health failure must not
  force crash recovery on the database.
- LiteLLM is not read-only: it writes its runtime UI directory and Prisma client at
  startup. Revisit once the exact write set is observed in phase 5.

## D-07 Logging and data retention in PostgreSQL
- Spend logs stay enabled (budgets, per-key accounting, guardrail traces including
  masked-entity counts).
- `store_prompts_in_spend_logs: false`: prompt and response bodies are not persisted, and
  LiteLLM also redacts the prompt-carrying fields of guardrail traces.
- `LITELLM_LOG=INFO` with `json_logs: true`; `redact_user_api_key_info: true`.
- Interactive API docs (`/`, `/redoc`) disabled via `NO_DOCS` / `NO_REDOC`.

## D-08 Fail-closed on database loss
`allow_requests_on_db_unavailable: false` (the default, set explicitly): if PostgreSQL is
down, virtual keys cannot be verified and requests are refused.
`ENFORCE_PRISMA_MIGRATION_CHECK=true`: the proxy refuses to start on a failed migration
instead of logging and continuing.

## D-09 Validation-only mock model
`mock-echo` in `config.yaml` never calls a provider; it is used to prove mask/restore
without spending tokens or requiring a provider key. It is removed after phase 5.

## D-10 TLS (open)
LiteLLM serves plain HTTP on 4000. Virtual keys travel in the `Authorization` header, so
on any shared network segment TLS termination in front of LiteLLM (nginx/Caddy with an
internal CA certificate) is required before serving real users. Deferred until the
assessment shows whether an internal CA exists. Until then `PublishPort=127.0.0.1:4000:4000`.

## D-11 Runtime: rootless Podman with Quadlet, not Docker (RHEL 10)
Chosen after the assessment showed RHEL 10.1. Evidence, all from the vendors:
- Red Hat does not ship or support Docker on RHEL 8/9/10 (KB 3696691); Podman is the
  supported engine and Red Hat's RHEL 10 container guide recommends Quadlet for new
  deployments and calls rootless containers "much more secure".
- Docker's own RHEL install page requires removing `podman` and `runc` first, replacing
  a supported stack with an unsupported one.
- Docker's firewall integration on RHEL 10 has only two paths: `iptables-nft`, which Red
  Hat marks unmaintained with removal planned and a kernel warning when `nft_compat`
  loads (RHEL 10 has no legacy `ip_tables` module; moby #49020 / #49727), or Docker's
  nftables backend, documented as experimental and not production-ready (Engine 29).
- Podman is daemonless: no root daemon, no root-equivalent socket; each container is a
  child of systemd, confined by SELinux, running under the unprivileged `llmgw` account.
  Podman package updates never restart running containers.
Verified for this design from the `podman-systemd.unit(5)` pages of 5.4 and 5.6 (same
key table): `Internal=`, `Notify=healthy`, `HealthOnFailure=`, `UserNS=keep-id:uid=`,
`ReadOnly`/`ReadOnlyTmpfs`, `Pull=`, symlinked search paths. The units were generated
with the Podman 5.6.0 Quadlet generator (`--user --dryrun`) with no errors.
Rootless costs: a one-time account setup (subordinate ids, linger) and operating the
stack from a `machinectl shell llmgw@` session. No host IP forwarding, no privileged
port and no capability is needed, so nothing about the design required rootful.

## D-12 Everything of the deployment lives under /opt/llm-gateway, one directory per component
Requirement from the environment owner: LiteLLM and Presidio are mounted in `/opt`.
FHS reserves `/opt/<package>` for add-on application software. Decided 2026-09-14 with
the owner: a single tree `/opt/llm-gateway/` (one owner, one permission boundary, one
backup path) with `litellm/`, `presidio/`, `postgres/`, `network/` and `bin/`, each
holding its unit file(s) next to its configuration, secrets and data, and `storage/` as
the rootless Podman image store (`graphroot` in `~llmgw/.config/containers/storage.conf`,
SELinux equivalence to the default location per `containers-storage.conf(5)`; a user
config that omits `runroot` keeps the default, checked in the containers/storage
source). PostgreSQL data is a bind mount (`postgres/data`) rather than a named volume so
it is where the owner expects it. The Quadlet search path
`~llmgw/.config/containers/systemd/` holds symlinks to the units (allowed by
`podman-systemd.unit(5)`), created by `bin/link-quadlets.sh`. Only the service account's
home stays outside `/opt`: a non-standard home would need its own SELinux file-context
equivalences for no gain.

## D-13 Signature verification: cosign on the workstation; pins are linux/amd64 manifest digests
*Amended by D-18 (2026-09-14): the server now pulls by digest itself; the workstation
only verifies pins. The reasoning below about what cosign signs is unchanged.*

Tested on 2026-09-14 with skopeo against the pinned `litellm-non_root` digest: a
`sigstoreSigned` policy with the vendored key (and `use-sigstore-attachments: true` in
`registries.d`) rejects the pull with "A signature was required, but no signature
exists". Cause: LiteLLM signs the multi-arch image index (tag `sha256-<index>.sig`
exists), not the `linux/amd64` manifest that a pull selects (no `sha256-<manifest>.sig`),
and containers/image looks for the signature on the pulled manifest. cosign verifies the
index digest. Because the server is offline (D-16), the chain is: on the workstation,
`scripts/fetch-images.sh` cosign-verifies the index, fetches that index by digest
(content-addressed, so these are the signed bytes), checks that it lists the pinned
`linux/amd64` digest, copies exactly that manifest into an OCI archive and checks the
archive digest; on the server, `bin/verify-images.sh` loads the archives and proves that
every unit's `Image=repo:tag@amd64-digest` resolves in local storage. The units pin the
amd64 digest rather than the index because Podman recomputes and matches the digest of
the loaded manifest, and an archive never carries the index. `bin/images.tsv` records
both digests per image. Revisit if LiteLLM starts signing per-platform manifests.

## D-14 Service dependencies
`llmgw-litellm` `Requires=`+`After=` PostgreSQL (LiteLLM cannot serve without it,
`allow_requests_on_db_unavailable: false`), so it starts only after PostgreSQL is
healthy and is restarted with it. It only `Wants=`+`After=` the two Presidio units: the
guardrail already fails closed per request, and this lets LiteLLM keep running while
Presidio restarts (and lets docs/05 §5.5 test fail-closed by stopping the analyzer alone).
Database and role names are set in the PostgreSQL unit (`Environment=`) and repeated in
`DATABASE_URL`; only the password is in the env files, because a systemd `ExecStart`
cannot safely reference environment variables in the health command.

## D-15 Resource budget as cgroup ceilings
*Amended 2026-09-14: the Cortex XDR agent uses about 1 GiB of the host (docs/01 §1.7),
so the "about 1.5 GiB for the OS" below is shared with it. The ceilings stay: they are
maximums, and the expected working set (LiteLLM 1 to 2 GiB, analyzer about 3.5 GiB,
anonymizer and PostgreSQL under 1 GiB together) leaves headroom. Revisit with the
`memory.current` figures of docs/04 §4.4 if the host ever swaps.*

Owner's requirement: about 6 GiB RAM and 2 cores for LiteLLM, 6 GiB and 4 cores for
Presidio, on an 8-core / 15 GiB host. Implemented as `MemoryMax=`, `MemorySwapMax=0` and
`CPUQuota=` in the `[Service]` section of each unit: Quadlet runs the container with
`--cgroups=split` inside the service's own cgroup, so systemd's limits apply to the
container and are visible with `systemctl --user show`. Split: LiteLLM 6G / 200 %;
analyzer 5G / 300 % with three gunicorn workers (one spaCy model per worker, about
1 GiB each, single-threaded); anonymizer 1G / 100 %; PostgreSQL 1500M / 100 %, leaving
about 1.5 GiB for the OS. These are ceilings (quotas), chosen over core pinning: quotas
need only the `cpu memory pids` delegation that RHEL 10's systemd gives user sessions by
default (confirmed on the host), while pinning would need `cpuset` delegation via a
`user@.service` drop-in. Reservations (`MemoryLow`) were not added: the host is
dedicated to this stack, so nothing competes.

## D-16 Offline server: everything arrives by scp from the workstation
*Superseded by D-18 (2026-09-14): internet access was enabled on the host. Kept as the
record of the phase 1 situation; the scp path for the deployment tree remains.*

Phase 1 showed no route from the host to any registry, GitHub, Red Hat CDN or provider
API, and no package repositories. Consequences: (1) the package source is a decision
for the owner (registration through a proxy, Satellite, or the RHEL ISO); (2) images
are fetched, cosign-verified and archived on the workstation and loaded on the server
(D-13), which removes the need for cosign on the server; (3) the deployment tree is
copied with `scp` and installed in place, and the repository is never cloned on the
server; (4) the only internet access the design needs from the host is TCP 443 to the
chosen provider API hosts, to be requested on the network firewall before docs/05 §5.7.
Verified on 2026-09-14 with Podman: an image loaded from an OCI archive keeps the
archive's manifest digest and resolves as `name:tag@digest` with `--pull=never`; a
wrong digest is refused with "image not known".

## D-17 SELinux was found disabled and is re-enabled before deployment
*Confirmed 2026-09-14 (docs/01 §1.7): disabled through `SELINUX=disabled` in the config
only, after an installation that left it enforcing; files created since are unlabeled,
so the forced relabel is mandatory, not precautionary.*

The host runs with SELinux disabled. The container design relies on it (container_t
confinement, `:Z` labels, `container-selinux`). Phase 2 re-enables it the way Red Hat
documents for a previously disabled system: permissive, forced relabel at boot
(`fixfiles -F onboot`), reboot, watch `ausearch -m AVC` through phases 3 and 4, then
enforcing. The owner's confirmation is required first (phase 1 open question 2).

## D-18 Online server: images are pulled on the server by pinned digest; cosign at pin time
Internet access was enabled on the host after phase 1 (owner, 2026-09-14). Packages
come from the company Satellite (docs/01 §1.7, docs/03 §3.0; direct Red Hat
registration is blocked by TLS decryption on the firewall) and images are pulled on
the server, which removes the OCI-archive transfer of D-16. The trust chain stays the
one of D-13: `scripts/verify-pins.sh` on the workstation cosign-verifies LiteLLM's
multi-arch index and checks that the index lists the pinned `linux/amd64` digest,
whenever a pin is chosen or changed; `bin/pull-images.sh` on the server re-reads the
index by its pinned digest (content-addressed), checks the amd64 digest again, pulls
exactly `repository:tag@digest` and proves every unit's `Image=` resolves. cosign is not
packaged for RHEL, so it is not required on the server; the script uses it if present.
Confirmed on the host on 2026-09-14: manifests from `ghcr.io` and `registry-1.docker.io`
and layers from `pkg-containers.githubusercontent.com` and
`production.cloudfront.docker.com` all pass with valid TLS (docs/01 §1.9).
Verified with Podman on 2026-09-14 against a local registry: a pull of
`name:tag@digest` is stored without the tag and resolves under that exact reference with
`--pull=never`; a wrong digest is refused at pull ("manifest unknown") and at lookup
("image not known"). The deployment tree still travels by `scp` (README working
agreement: the server never talks to GitHub). The host-level egress policy (D-05, docs/02
§2.8) is what keeps the service account's traffic to TCP 443 now that the host has
general internet access.

## D-19 The LLM provider is chosen after the stack is validated
`api.anthropic.com` in the architecture diagram is an example. No provider key is placed
on the server and no provider model is configured until docs/05 §5.1 to §5.6 pass with
the validation-only `mock-echo` model (D-09); the provider decision, its key, the model
entries and the real round trip are phase 7 (docs/05 §5.7). Consequences: `config.yaml`
ships only `mock-echo` plus commented examples of the entry shape; `litellm.env` has no
provider variable yet; the egress rule stays `tcp dport 443` to any address until a
provider exists to narrow it to.

## D-20 Hostname and phase 2 sequence
Hostname `xbbovsrlllm001.xalqbank.az`, following the company pattern seen on the host
(`xbbovsransb001`); the owner's first proposal carried the IP address inside the name,
which is invalid (dots are label separators, an all-digit last label) and brittle. The
address is kept in `/etc/hosts` until DNS carries it. Phase 2 runs in this order:
hostname, Satellite registration (brought forward from phase 3 so the system can be
updated first), updates, logging and audit rules, then the single reboot that boots the
updated kernel, relabels and brings SELinux to permissive; SSH, sysctl and firewalls
after it. *Amended 2026-09-15:* two reboots instead of one. The first boots the new
kernel alone (§2.4.1) so that a regression in the Cortex XDR agent or elsewhere has a
single candidate cause; the second (§2.1) carries the SELinux relabel. Because the workstation is Windows, `.gitattributes` pins LF line endings for
every file (CRLF would break the units, scripts and YAML on the server) and the key is
installed without `ssh-copy-id`.

## D-21 No automatic OS updates
`dnf-automatic` is not installed. The owner patches manually on a monthly window with a
VM snapshot first (docs/06 §6.8). Reasoning: the host's exposure is internal and its
most exposed components are the container images, which dnf never touches; the parts an
unattended security update could break are exactly the ones nobody would be watching
(a kernel the Cortex XDR agent does not yet support, a podman/crun change picked up by
the next container restart). Applicable errata remain visible per host in Satellite, so
the owner still sees what is due. Depends on the window actually happening; if that
proves unreliable, the fallback is `dnf-automatic` in notify-only mode
(`apply_updates = no`, `emit_via = motd`), never auto-apply.
