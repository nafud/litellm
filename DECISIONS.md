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
- All four images are pinned `tag@sha256:digest`, and the digests were read from the
  registries' manifest APIs on 2026-09-14. Updating = change tag + digest together, then
  `scripts/verify-images.sh`.

## D-02 Signature verification
LiteLLM signs all `ghcr.io/berriai/*` images with one cosign key. The key is vendored in
`deploy/cosign/` (provenance in its README). Presidio and PostgreSQL images are not
verified by signature; integrity relies on the digest pin.

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

## D-05 Network segmentation inside Docker
- `backend` is an `internal: true` network: PostgreSQL and Presidio have no route to the
  internet. Only `litellm` is also on `egress`.
- Nothing but LiteLLM publishes a port, and only on `LITELLM_BIND_ADDR`
  (default `127.0.0.1`). PostgreSQL is never reachable from the host network.
- The network-level egress firewall (allow provider API hosts from the gateway host only)
  is an infrastructure control outside this repo; the assessment records whether it exists.

## D-06 Container hardening
- All services: `no-new-privileges`, `cap_drop: ALL`, log rotation, `restart: unless-stopped`.
- PostgreSQL runs as uid 999 directly, so the entrypoint's root-only chown/gosu path is
  skipped and no capability is needed. This depends on the named volume (ownership is
  inherited from the image); a bind mount would need `chown 999:999`.
- Presidio containers are `read_only` with a tmpfs `/tmp` (gunicorn heartbeat files).
  If phase 5 shows either container unhealthy because of a write, the fix is a narrower
  tmpfs, not dropping `read_only`.
- LiteLLM is not `read_only`: it writes its runtime UI directory and Prisma client at
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
assessment shows whether an internal CA exists. Until then `LITELLM_BIND_ADDR=127.0.0.1`.
