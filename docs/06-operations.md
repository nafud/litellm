# Phase 6: Operations

## 6.1 Backups

What must be backed up together (a restore needs all three):

1. PostgreSQL data: virtual keys (hashed), teams, budgets, spend logs, guardrail traces.
2. `deploy/litellm.env` (in particular `LITELLM_SALT_KEY`) and `deploy/.env`.
3. This repository (configuration).

Logical dump, consistent, run from cron on the host:

```bash
sudo docker compose -f /opt/llm-gateway/deploy/docker-compose.yml exec -T postgres \
  pg_dump -U litellm -d litellm -Fc > /var/backups/llm-gateway/litellm-$(date +%F).dump
```

Encrypt at rest (`age` or `gpg`) before moving off-host; the dump contains hashed keys and
spend metadata. Test a restore quarterly:

```bash
sudo docker compose exec -T postgres pg_restore -U litellm -d litellm --clean --if-exists < litellm-<date>.dump
```

## 6.2 Routine checks

- `sudo docker compose ps` all healthy; `sudo docker compose logs --since 24h litellm | grep -i -E 'error|guardrail'`.
- Disk: `docker system df`, `df -h /var/lib/docker`.
- Spend: admin UI or `GET /global/spend/report` with the master key.
- Host: `unattended-upgrades` log, `auditctl -l`, `last -a`.

## 6.3 Updating an image (the only supported way)

1. Pick the new tag (LiteLLM: a stable `vX.Y.Z` release; Presidio: a release tag;
   PostgreSQL: a new **minor** only, e.g. `18.7`; a major upgrade needs `pg_upgrade`).
2. Resolve its digest from the registry, not from a blog post:

   ```bash
   docker buildx imagetools inspect ghcr.io/berriai/litellm-non_root:v1.101.0 | grep -m1 Digest
   ```

3. Edit `deploy/docker-compose.yml`: change tag **and** digest on the same line.
4. `sudo bash scripts/verify-images.sh` (pull + cosign for LiteLLM).
5. Read the release notes for schema or config changes; take a DB backup (§6.1).
6. `sudo docker compose up -d` and watch `logs -f litellm` for the migration.
7. Re-run `docs/05-validation.md` §5.1, §5.3 and §5.4. Commit with the release note link.

Rollback = revert the compose line and `docker compose up -d`. LiteLLM migrations are
forward-only; if a release added a migration, restore the DB dump from step 5 first.

## 6.4 Key and secret rotation

| Secret | Rotation | Procedure |
|--------|----------|-----------|
| Provider API keys | on schedule / on suspicion | new key in `litellm.env`, `docker compose up -d litellm`, revoke old key at the provider |
| `LITELLM_MASTER_KEY` | on suspicion, staff change | edit `litellm.env`, restart litellm; virtual keys are unaffected |
| Virtual keys | per user policy | `POST /key/regenerate` or `/key/delete` + `/key/generate` |
| `UI_PASSWORD` | with master key | edit `litellm.env`, restart |
| `POSTGRES_PASSWORD` | rarely | `ALTER USER litellm PASSWORD '...'` in psql, then update `.env`, `docker compose up -d litellm` |
| `LITELLM_SALT_KEY` | **never** | changing it orphans encrypted DB content |

## 6.5 Adding a model or provider

Edit `deploy/litellm/config.yaml` (and `litellm.env` for a new provider key), commit,
then `sudo docker compose up -d litellm`. Model IDs must exist in LiteLLM's cost map for
spend tracking to work; unknown IDs are accepted but logged at zero cost.

## 6.6 Onboarding a client

- Chat UI (Open WebUI, LibreChat): base URL `http://<gateway>:4000/v1`, a virtual key
  created for that application with a team and budget.
- Developer tools (OpenCode, Claude Code): one virtual key per developer, scoped
  `models`, `max_budget` and `budget_duration`; hand out via the password manager.

## 6.7 Incident basics

- Suspected key leak: delete the virtual key (`/key/delete`), review its spend and the
  `requester_ip_address` column in `LiteLLM_SpendLogs`.
- Presidio down: traffic is refused (fail closed). `docker compose restart presidio-analyzer`,
  check `logs`, memory (`docker stats`), and the analyzer `/health`.
- Provider outage: LiteLLM returns the provider error to the client; no unmasked data is
  involved. Consider `fallbacks` in `litellm_settings` only as a deliberate decision.
