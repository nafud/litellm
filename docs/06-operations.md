# Phase 6: Operations

`llmgw$` commands run in the service-account session (`sudo machinectl shell llmgw@`).

## 6.1 Backups

What must be backed up together (a restore needs all three):

1. PostgreSQL data: virtual keys (hashed), teams, budgets, spend logs, guardrail traces.
2. `/opt/llm-gateway/litellm/litellm.env` (in particular `LITELLM_SALT_KEY`) and
   `/opt/llm-gateway/postgres/postgres.env`.
3. This repository (configuration and units).
4. Since phase 8: the `openwebui` database in the same container (users, chats,
   settings), `/opt/llm-gateway/openwebui/openwebui.env` and the upload/vector
   directory `/opt/llm-gateway/openwebui/data`. Note that chats are stored there
   unmasked (D-30): the dump inherits that sensitivity.

Logical dump, consistent, run as `llmgw`:

```bash
llmgw$ mkdir -p -m 700 /opt/llm-gateway/postgres/backups
llmgw$ podman exec postgres pg_dump -U litellm -d litellm -Fc > /opt/llm-gateway/postgres/backups/litellm-$(date +%F).dump
llmgw$ podman exec postgres pg_dump -U litellm -d openwebui -Fc > /opt/llm-gateway/postgres/backups/openwebui-$(date +%F).dump   # phase 8
```

Scheduling (user timer under `llmgw`), retention and any off-host copy are deferred to a
supervisor decision (D-28). When they come: encrypt at rest (`age` or `gpg`) before moving
off-host; the dump contains hashed keys and spend metadata. Test a restore quarterly,
into a scratch database rather than over the live one:

```bash
llmgw$ podman exec postgres createdb -U litellm litellm_restoretest
llmgw$ podman exec -i postgres pg_restore -U litellm -d litellm_restoretest < /opt/llm-gateway/postgres/backups/litellm-<date>.dump
llmgw$ podman exec postgres psql -U litellm -d litellm_restoretest -tAc 'select count(*) from _prisma_migrations'   # same as live
llmgw$ podman exec postgres dropdb -U litellm litellm_restoretest
```

A real restore over the live database (after a failed migration, §6.3) is the same
`pg_restore` with `-d litellm --clean --if-exists`, with `llmgw-litellm.service` stopped.

## 6.2 Routine checks

- `llmgw$ systemctl --user list-units 'llmgw-*'` all active; `podman ps` all healthy.
- `sudo journalctl _SYSTEMD_USER_UNIT=llmgw-litellm.service --since -24h | grep -i -E 'error|guardrail'` (admin; `llmgw` cannot read the journal, D-25).
- Disk: `llmgw$ podman system df`, `df -h /opt`.
- Egress drops: `sudo journalctl -k --since -24h | grep llmgw-egress-drop` (expect none).
- Spend: admin UI or `GET /global/spend/report` with the master key.
- Host: `sudo dnf updateinfo --summary` (pending errata, see §6.8), `auditctl -l`, `last -a`.

## 6.3 Updating an image (the only supported way)

Podman's `AutoUpdate=` is deliberately not set on any unit: an update is a reviewed
commit, never an unattended pull.

1. Pick the new tag (LiteLLM: a stable `vX.Y.Z` release; Presidio: a release tag;
   PostgreSQL: a new **minor** only, e.g. `18.7`; a major upgrade needs `pg_upgrade`).
2. On the workstation, resolve both digests from the registry, not from a blog post:

   ```bash
   skopeo inspect --raw docker://ghcr.io/berriai/litellm-non_root:v1.101.0 > idx.json
   sha256sum idx.json                                   # index digest
   python3 -c "import json; [print(m['digest']) for m in json.load(open('idx.json'))['manifests'] if m['platform']['architecture']=='amd64']"   # linux/amd64 digest
   ```

3. Update the row in `deploy/opt/bin/images.tsv` and the `Image=` line of the unit
   (tag **and** amd64 digest, index digest in the comment). Commit.
4. `scripts/verify-pins.sh` on the workstation (cosign on the index, index lists the
   amd64 digest, unit pins it), then `scp` `images.tsv` and the changed unit to the
   server, install them over their `/opt/llm-gateway/{bin,<component>}/` copies as
   `llmgw`, then `llmgw$ bash /opt/llm-gateway/bin/pull-images.sh` (pulls the new digest,
   leaves the old image in place for rollback).
5. Read the release notes for schema or config changes; take a DB backup (§6.1).
6. `llmgw$ systemctl --user daemon-reload && systemctl --user restart llmgw-litellm.service`
   (or the unit that changed), then `sudo journalctl -f _SYSTEMD_USER_UNIT=llmgw-litellm.service` (admin) for
   the migration.
7. Re-run `docs/05-validation.md` §5.1, §5.3 and §5.4, then one call to the real model
   (§5.7a step 3; §5.7 step 3 once Gemini is in use). Remove the old image with
   `podman image prune`.

Rollback = reinstall the previous unit (the old image is still in storage until pruned),
`daemon-reload`, restart. LiteLLM migrations are forward-only; if a release added a
migration, restore the DB dump from step 5 first.

## 6.4 Key and secret rotation

| Secret | Rotation | Procedure |
|--------|----------|-----------|
| Provider API keys | on schedule / on suspicion | new key in `litellm/litellm.env`, `systemctl --user restart llmgw-litellm.service`, revoke old key at the provider |
| `LITELLM_MASTER_KEY` | on suspicion, staff change | edit `litellm/litellm.env`, restart litellm; virtual keys are unaffected |
| Virtual keys | per user policy | `/key/generate` a new key under a new alias, hand it out, then `/key/delete` the old one by alias. `/key/regenerate` is refused without an enterprise licence in 1.100.1 (`key_management_endpoints.py`; only the master key may be regenerated), and aliases are unique across keys |
| `openwebui` virtual key | with the other virtual keys | new key as in docs/07 §7.4 under a new alias, into `openwebui/openwebui.env`, `systemctl --user restart llmgw-openwebui.service`, delete the old key by alias |
| `UI_PASSWORD` | with master key | edit `litellm/litellm.env`, restart |
| `WEBUI_SECRET_KEY` | on suspicion | edit `openwebui/openwebui.env`, restart `llmgw-openwebui.service`; every user is logged out, nothing else depends on it |
| Open WebUI database password | rarely | `ALTER USER openwebui PASSWORD '...'` as for `litellm`, update `DATABASE_URL` in `openwebui/openwebui.env`, restart `llmgw-openwebui.service` |
| `POSTGRES_PASSWORD` | rarely | `podman exec -it postgres psql -U litellm -c "ALTER USER litellm PASSWORD '...'"`, update `postgres.env` and `DATABASE_URL`, restart litellm |
| `LITELLM_SALT_KEY` | **never** | changing it orphans encrypted DB content |

## 6.5 Adding a model or provider

Edit `deploy/opt/litellm/config.yaml` in the repository (and `litellm/litellm.env` on
the server for a new provider key), commit, `scp` and install the file as `llmgw`, then
`systemctl --user restart llmgw-litellm.service`. An id absent from LiteLLM's cost map
is accepted, but LiteLLM sets its `response_cost` to None (1.100.1 `litellm_logging.py`,
"not found in completion cost map"), so budgets do not see it; state
`input_cost_per_token` and `output_cost_per_token` in the entry instead, as the
`nemotron-3-super` entry does, so spend accounting does not depend on the map.

## 6.6 Onboarding a client

- Open WebUI (deployed, docs/07): its virtual key `openwebui` sits in
  `openwebui/openwebui.env`, base URL `http://litellm:4000/v1` on the internal network;
  users are created by its admin (docs/07 §7.6). Another chat application would get its
  own key and budget the same way.
- Developer tools (OpenCode, Claude Code): one virtual key per developer, scoped
  `models`, `max_budget` and `budget_duration`; hand out via the password manager.

## 6.7 Incident basics

- Suspected key leak: delete the virtual key (`/key/delete`), review its spend and the
  `requester_ip_address` column in `LiteLLM_SpendLogs`.
- Presidio down: traffic is refused (fail closed). systemd restarts an unhealthy
  container by itself (`HealthOnFailure=kill` + `Restart=always`); if it keeps failing,
  `sudo journalctl _SYSTEMD_USER_UNIT=llmgw-presidio-analyzer.service` (admin), memory (`podman stats`), and
  the analyzer `/health`.
- Provider outage: LiteLLM returns the provider error to the client; no unmasked data is
  involved. Open WebUI shows that error text to the user as it is, and a failure after
  the stream has begun as an empty answer (docs/07 §7.8). Consider `fallbacks` in
  `litellm_settings` only as a deliberate decision.
- Host compromise suspected: the containers run as `llmgw` without capabilities; check
  `sudo ausearch -k gateway -ts recent` and `sudo journalctl -k | grep llmgw-egress-drop`.

## 6.8 Monthly OS patch window

Automatic updates are off (D-21). Once a month, or sooner for a critical erratum that
Satellite flags for this host:

1. Check what is due: Satellite (Hosts > Content Hosts > `llmgw01` > Errata) or
   on the host `sudo dnf updateinfo --summary` and `sudo dnf -q check-update`.
2. Take a VM snapshot.
3. `sudo dnf upgrade`, read the transaction summary (kernel, selinux-policy, podman,
   crun, systemd, glibc, openssh are the packages that matter), confirm.
4. If `sudo needs-restarting -r` returns 1, reboot in a window: `sudo systemctl reboot`.
   Otherwise `sudo needs-restarting` lists the services to restart; the containers are
   restarted only if `podman`, `crun`, `conmon` or `netavark` changed
   (`llmgw$ systemctl --user restart llmgw-litellm.service` etc., one at a time,
   watching `podman ps` health).
5. Verify: `uname -r`, `systemctl --failed`, `sudo /opt/traps/bin/cytool status` and
   `runtime query` (agent supports the new kernel), `getenforce` = Enforcing with no new
   AVCs (`sudo ausearch -m avc -ts boot`), §6.2 checks, one request through the gateway
   (docs/05 §5.2).
6. Delete the snapshot after a day of normal operation; record the date and kernel in
   the change log.
