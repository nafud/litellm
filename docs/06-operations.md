# Phase 6: Operations

`llmgw$` commands run in the service-account session (`sudo machinectl shell llmgw@`).

## 6.1 Backups

What must be backed up together (a restore needs all three):

1. PostgreSQL data: virtual keys (hashed), teams, budgets, spend logs, guardrail traces.
2. `/opt/llm-gateway/env/` (in particular `LITELLM_SALT_KEY` in `litellm.env`).
3. This repository (configuration and units).

Logical dump, consistent, run as `llmgw`:

```bash
llmgw$ mkdir -p -m 700 /opt/llm-gateway/backups
llmgw$ podman exec postgres pg_dump -U litellm -d litellm -Fc > /opt/llm-gateway/backups/litellm-$(date +%F).dump
```

Schedule it with the service account's crontab (`llmgw$ crontab -e`) or a user timer.
Encrypt at rest (`age` or `gpg`) before moving off-host; the dump contains hashed keys and
spend metadata. Test a restore quarterly:

```bash
llmgw$ podman exec -i postgres pg_restore -U litellm -d litellm --clean --if-exists < /opt/llm-gateway/backups/litellm-<date>.dump
```

## 6.2 Routine checks

- `llmgw$ systemctl --user list-units 'llmgw-*'` all active; `podman ps` all healthy.
- `llmgw$ journalctl --user -u llmgw-litellm.service --since -24h | grep -i -E 'error|guardrail'`.
- Disk: `llmgw$ podman system df`, `df -h /opt /home`.
- Egress drops: `sudo journalctl -k --since -24h | grep llmgw-egress-drop` (expect none).
- Spend: admin UI or `GET /global/spend/report` with the master key.
- Host: `dnf-automatic` log (`journalctl -u dnf-automatic`), `auditctl -l`, `last -a`.

## 6.3 Updating an image (the only supported way)

Podman's `AutoUpdate=` is deliberately not set on any unit: an update is a reviewed
commit, never an unattended pull.

1. Pick the new tag (LiteLLM: a stable `vX.Y.Z` release; Presidio: a release tag;
   PostgreSQL: a new **minor** only, e.g. `18.7`; a major upgrade needs `pg_upgrade`).
2. Resolve its digest from the registry, not from a blog post. The pinned digest is the
   digest of the raw manifest index:

   ```bash
   skopeo inspect --raw docker://ghcr.io/berriai/litellm-non_root:v1.101.0 | sha256sum
   ```

3. Edit the unit in `deploy/quadlet/`: change tag **and** digest on the `Image=` line.
   Commit, then `llmgw$ git -C /opt/llm-gateway/repo pull`.
4. `llmgw$ bash /opt/llm-gateway/repo/scripts/verify-images.sh` (pull + cosign for LiteLLM).
5. Read the release notes for schema or config changes; take a DB backup (§6.1).
6. `llmgw$ systemctl --user daemon-reload && systemctl --user restart llmgw-litellm.service`
   (or the unit that changed), then `journalctl --user -f -u llmgw-litellm.service` for
   the migration.
7. Re-run `docs/05-validation.md` §5.1, §5.3 and §5.4. Remove the old image with
   `podman image prune`.

Rollback = revert the `Image=` line, pull, `daemon-reload`, restart. LiteLLM migrations
are forward-only; if a release added a migration, restore the DB dump from step 5 first.

## 6.4 Key and secret rotation

| Secret | Rotation | Procedure |
|--------|----------|-----------|
| Provider API keys | on schedule / on suspicion | new key in `env/litellm.env`, `systemctl --user restart llmgw-litellm.service`, revoke old key at the provider |
| `LITELLM_MASTER_KEY` | on suspicion, staff change | edit `env/litellm.env`, restart litellm; virtual keys are unaffected |
| Virtual keys | per user policy | `POST /key/regenerate` or `/key/delete` + `/key/generate` |
| `UI_PASSWORD` | with master key | edit `env/litellm.env`, restart |
| `POSTGRES_PASSWORD` | rarely | `podman exec -it postgres psql -U litellm -c "ALTER USER litellm PASSWORD '...'"`, update `postgres.env` and `DATABASE_URL`, restart litellm |
| `LITELLM_SALT_KEY` | **never** | changing it orphans encrypted DB content |

## 6.5 Adding a model or provider

Edit `deploy/litellm/config.yaml` (and `env/litellm.env` for a new provider key),
commit, pull on the server, `systemctl --user restart llmgw-litellm.service`. Model IDs
must exist in LiteLLM's cost map for spend tracking to work; unknown IDs are accepted but
logged at zero cost.

## 6.6 Onboarding a client

- Chat UI (Open WebUI, LibreChat): base URL `http://<gateway>:4000/v1`, a virtual key
  created for that application with a team and budget.
- Developer tools (OpenCode, Claude Code): one virtual key per developer, scoped
  `models`, `max_budget` and `budget_duration`; hand out via the password manager.

## 6.7 Incident basics

- Suspected key leak: delete the virtual key (`/key/delete`), review its spend and the
  `requester_ip_address` column in `LiteLLM_SpendLogs`.
- Presidio down: traffic is refused (fail closed). systemd restarts an unhealthy
  container by itself (`HealthOnFailure=kill` + `Restart=always`); if it keeps failing,
  `journalctl --user -u llmgw-presidio-analyzer.service`, memory (`podman stats`), and
  the analyzer `/health`.
- Provider outage: LiteLLM returns the provider error to the client; no unmasked data is
  involved. Consider `fallbacks` in `litellm_settings` only as a deliberate decision.
- Host compromise suspected: the containers run as `llmgw` without capabilities; check
  `sudo ausearch -k gateway -ts recent` and `sudo journalctl -k | grep llmgw-egress-drop`.
