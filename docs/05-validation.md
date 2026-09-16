# Phase 5: Validation

Run on the server while LiteLLM listens on `127.0.0.1`. `curl` commands work from the
admin account or the `llmgw` session; `podman` commands need the `llmgw` session
(`sudo machinectl shell llmgw@`). Export the master key for the session only:

```bash
export MASTER_KEY="$(sudo grep '^LITELLM_MASTER_KEY=' /opt/llm-gateway/litellm/litellm.env | cut -d= -f2-)"   # as llmgw: without sudo
export BASE=http://127.0.0.1:4000
```

## 5.1 Health

```bash
curl -sS $BASE/health/liveliness            # public route: "I'm alive!"
curl -sS -H "Authorization: Bearer $MASTER_KEY" $BASE/health/readiness | python3 -m json.tool
```

Readiness must report `"db": "connected"`. Result (2026-09-16): `{"status": "healthy",
"db": "connected"}`; this version lists no guardrails there, the guardrail is proven by
§5.3 and §5.4 instead.

## 5.2 Presidio services directly (from the LiteLLM container, they are not published)

```bash
llmgw$ podman exec -i litellm python3 - <<'PY'
import json, urllib.request
req = urllib.request.Request("http://presidio-analyzer:3000/analyze",
    data=json.dumps({"text": "My name is Dennis Yurichev, mail dennis@example.com", "language": "en"}).encode(),
    headers={"Content-Type": "application/json"})
print(json.dumps(json.load(urllib.request.urlopen(req, timeout=30)), indent=1))
PY
```

Expect `PERSON` (score around 0.85) and `EMAIL_ADDRESS` (score 1.0). Result
(2026-09-16): both, plus `URL` at 0.5 for `example.com` inside the address; `URL` is not
in `pii_entities_config`, so LiteLLM ignores it.

## 5.3 Masking as the provider would see it

`/guardrails/apply_guardrail` runs the guardrail on text and returns the masked form:

```bash
curl -sS -X POST $BASE/guardrails/apply_guardrail \
  -H "Authorization: Bearer $MASTER_KEY" -H "Content-Type: application/json" \
  -d '{"guardrail_name":"presidio-pii","text":"My name is Dennis Yurichev, mail dennis@example.com, card 4111 1111 1111 1111"}'
```

Expected `response_text`: `My name is <PERSON_1>, mail <EMAIL_ADDRESS_2>, card <CREDIT_CARD_3>`.
Placeholders are numbered by position across all entities, not per entity type
(litellm 1.100.1, `_finalize_presidio_anonymize_numbered_tokens`). Result (2026-09-16):
exactly that.

## 5.4 End-to-end mask + restore, without a provider

`mock-echo` returns a fixed reply containing `<PERSON_1>` and `<EMAIL_ADDRESS_2>`. If the
`post_call` restoration works, those tokens come back replaced with the values from the
request:

```bash
curl -sS $BASE/v1/chat/completions \
  -H "Authorization: Bearer $MASTER_KEY" -H "Content-Type: application/json" \
  -d '{"model":"mock-echo","messages":[{"role":"user","content":"I am Dennis Yurichev, dennis@example.com"}]}' \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["choices"][0]["message"]["content"])'
```

Expected: `Mock reply. Restored placeholders: Dennis Yurichev dennis@example.com`.

Finding (2026-09-16, first run): the mock reply carried `<EMAIL_ADDRESS_1>` while the
request produced `<EMAIL_ADDRESS_2>` (numbering above), so only the person was
restored; config.yaml corrected, a placeholder without mapping is passed through
unchanged. The streaming run returned `<PERSON> <EMAIL_ADDRESS_1>`: the restored name
had been masked again with an un-numbered token. Root cause (DEBUG capture, then
`guardrail_initializers.initialize_presidio` of 1.100.1): `presidio_filter_scope`
defaults to `both`, which registers three guardrail instances, the third with
`apply_to_output=True`, masking PII in the model's reply towards the user. On the
streaming path it runs after the unmasker (restored values re-masked), on the
non-streaming path before it (no effect), hence the asymmetry. Fix:
`presidio_filter_scope: input` in config.yaml (D-27); two instances remain, no output
masker. Log redaction was the first suspect and is cleared: the masking happened in the
post_call phase, before the logging_only phase.

Streaming path (the restore logic is separate for streams):

```bash
curl -sS -N $BASE/v1/chat/completions \
  -H "Authorization: Bearer $MASTER_KEY" -H "Content-Type: application/json" \
  -d '{"model":"mock-echo","stream":true,"messages":[{"role":"user","content":"I am Dennis Yurichev, dennis@example.com"}]}' \
  | grep -o '"content":"[^"]*"' | tr -d '\n'; echo
```

The concatenated content must again read `... Dennis Yurichev dennis@example.com`.

Result (2026-09-16, after the scope fix, `LITELLM_LOG=INFO`): non-streaming and streaming
both return `Mock reply. Restored placeholders: Dennis Yurichev dennis@example.com`. Pass.
A request without PII returns the raw placeholders, as there is nothing to restore. The
guardrail instance count is only visible at DEBUG (the `Checking if <... object at 0x...>`
lines), so it was not re-counted at INFO; the source of 1.100.1
(`initialize_presidio`, `run_output = filter_scope in ("output", "both")`) shows that
`input` creates exactly the pre_call masker and the post_call restorer, and the restored
streaming reply is the functional proof that the output masker is gone.

## 5.5 Fail-closed check

Stop the analyzer and repeat 5.4: the request must be rejected (HTTP 4xx/5xx with a
guardrail error), never forwarded unmasked. LiteLLM keeps running because its unit only
*wants* the Presidio units (`Wants=`), it does not *require* them.

```bash
llmgw$ systemctl --user stop llmgw-presidio-analyzer.service
llmgw$ systemctl --user is-active llmgw-litellm.service        # active
curl -sS -o /dev/null -w 'HTTP %{http_code}\n' $BASE/v1/chat/completions \
  -H "Authorization: Bearer $MASTER_KEY" -H "Content-Type: application/json" \
  -d '{"model":"mock-echo","messages":[{"role":"user","content":"I am Dennis Yurichev"}]}'
llmgw$ systemctl --user start llmgw-presidio-analyzer.service
```

Result (2026-09-16): LiteLLM stays `active`; the request is answered with HTTP 500 and the
body `{"error":{"message":"Presidio PII analysis failed: ClientConnectorDNSError", ...}}`.
The name `presidio-analyzer` stops resolving on the internal network as soon as the
container is gone, the guardrail raises, nothing is forwarded to the model. After the
restart all four containers report healthy within 30 s. Pass.

## 5.6 Virtual keys and budgets

```bash
curl -sS -X POST $BASE/key/generate \
  -H "Authorization: Bearer $MASTER_KEY" -H "Content-Type: application/json" \
  -d '{"key_alias":"validation-dev1","models":["mock-echo"],"max_budget":5,"budget_duration":"30d","duration":"30d"}'
```

Keep the returned `key` (`sk-...`) in a shell variable, never print it. Then, with that key:

- a request to `mock-echo` succeeds;
- a request to `other-model` is refused with HTTP 403, `key_model_access_denied`;
- `GET /key/info?key=<key>` with the master key shows the alias, budget and spend.

Result (2026-09-16): key generated (25 characters, `sk-` plus 22); `mock-echo` answers
through it; `other-model` is refused with 403 "key not allowed to access model. This key
can only access models=['mock-echo']"; `/key/info` shows alias `validation-dev1`, models
`['mock-echo']`, `max_budget 5.0`, `spend 0.0` (the mock model has no price), budget
duration `30d`, expiry 30 days out. Pass. The variable was unset afterwards; the key is
deleted by alias in 5.9.

## 5.7 Real provider round trip (phase 7, after the provider is chosen)

The provider and its key are decided only once 5.1 to 5.6 pass and the stack is judged
sound (D-19). Until then `model_list` holds only `mock-echo` and no provider key exists
on the server. Phase 7 then consists of:

1. Add the model entries to `deploy/opt/litellm/config.yaml` (the commented examples show
   the shape: `model_name` as clients will call it, `litellm_params.model` in LiteLLM's
   `<provider>/<model>` form, `api_key: os.environ/<VAR>`), commit, `scp` and install
   the file as `llmgw` (docs/06 §6.5).
2. Put the key in `/opt/llm-gateway/litellm/litellm.env` (mode 0600, `llmgw`), restart
   `llmgw-litellm.service`, confirm `/v1/models` lists the new names.
3. Issue a virtual key limited to the new model (like 5.6) and send, through it, a prompt
   containing a name:

   ```bash
   curl -sS $BASE/v1/chat/completions \
     -H "Authorization: Bearer <virtual-key>" -H "Content-Type: application/json" \
     -d '{"model":"<public-model-name>","messages":[{"role":"user","content":"Reply with exactly the text between the quotes: \"Hello Dennis Yurichev\""}]}'
   ```

   The reply must contain `Hello Dennis Yurichev` (restored), while the provider only
   received `Hello <PERSON_1>`. From LiteLLM's side, the spend log row records which
   guardrail ran and how many entities were masked, without the prompt body:

   ```bash
   llmgw$ podman exec postgres psql -U litellm -d litellm -c \
     "select request_id, model, spend, metadata->'applied_guardrails' as guardrails, metadata->'guardrail_information' as info from \"LiteLLM_SpendLogs\" order by \"startTime\" desc limit 3;"
   ```

   Confirm the `messages` and `response` columns of the same rows are empty objects
   (`store_prompts_in_spend_logs: false`).
4. Optionally narrow the egress rule to the provider's addresses (docs/02 §2.8).

## 5.8 Admin UI

`http://127.0.0.1:4000/ui` via an SSH tunnel from the workstation
(`ssh -L 4000:127.0.0.1:4000 infosec@10.50.4.68`, kept open in its own window; the
server's `AllowTcpForwarding` must permit local forwarding, `sudo sshd -T | grep -i
allowtcpforwarding`). Login with `UI_USERNAME` / `UI_PASSWORD`. Confirm:

- Models + Endpoints lists `mock-echo`; "Add Model" is refused with
  "Set STORE_MODEL_IN_DB=True in your env to enable this feature" (config-driven models,
  `STORE_MODEL_IN_DB=False` in the unit);
- Virtual Keys shows `validation-dev1` with its $5 budget and `mock-echo` only;
- do not use the Credentials tab. Verified in the 1.100.1 source: `POST /credentials`
  writes to the database (encrypted with `SALT_KEY`) with no `STORE_MODEL_IN_DB` guard,
  while the reload of stored credentials is scheduled only when `store_model_in_db` is
  true. An entry made there could not be attached to a model and would be dropped from
  memory at the next restart, but it would sit in the database. Provider keys stay in
  `litellm.env` only (D-19, §6.5).

## 5.9 Clean up and record

- Remove the `mock-echo` entry from `deploy/opt/litellm/config.yaml` in the repository,
  commit, `scp` the file to the server and install it as `llmgw`
  (`sudo install -m 644 -o llmgw -g llmgw /tmp/config.yaml /opt/llm-gateway/litellm/config.yaml`),
  then `systemctl --user restart llmgw-litellm.service` (the file is bind-mounted, so a
  restart applies it).
- Delete the validation key by alias, the value was never kept: `POST /key/delete` with
  `{"key_aliases":["validation-dev1"]}`.
- Record the results (pass/fail per section, versions, date) in the phase 5 entry of
  `README.md` and any deviations in `DECISIONS.md`.

## 5.10 Exit criteria and opening the port

All of 5.1 to 5.7 pass as described; 5.5 proves fail-closed. Then serve the client
network: change `PublishPort=127.0.0.1:4000:4000` in
`deploy/opt/litellm/llmgw-litellm.container` to `10.50.4.68:4000:4000`, commit, `scp`
the unit to the server and install it over `/opt/llm-gateway/litellm/llmgw-litellm.container`
(owner `llmgw`), and

```bash
llmgw$ systemctl --user daemon-reload && systemctl --user restart llmgw-litellm.service
sudo ss -tlnp | grep ':4000 '
sudo firewall-cmd --permanent --zone=public --add-rich-rule='rule family="ipv4" source address="<client-cidr>" port port="4000" protocol="tcp" accept'
sudo firewall-cmd --reload && sudo firewall-cmd --list-rich-rules
```

Plain HTTP on the LAN is acceptable only until TLS termination is in place (D-10).
