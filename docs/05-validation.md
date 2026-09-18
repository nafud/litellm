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
sound (D-19). Decided 2026-09-16: Google Gemini through the AI Studio API, public model
name `gemini-2.5-flash` (D-29). Phase 7 consists of:

1. The model entry is in `deploy/opt/litellm/config.yaml` (`model_name` as clients call
   it, `litellm_params.model` in LiteLLM's `<provider>/<model>` form,
   `api_key: os.environ/GEMINI_API_KEY`). Transfer the file with the branch ZIP and
   `scp` (docs/03 §3.4), check it and install it as `llmgw`:

   ```bash
   grep -c $'\r' /tmp/config.yaml; sudo diff /opt/llm-gateway/litellm/config.yaml /tmp/config.yaml
   sudo install -m 644 -o llmgw -g llmgw /tmp/config.yaml /opt/llm-gateway/litellm/config.yaml && rm /tmp/config.yaml
   ```

   The CRLF count must be 0 and the diff must show only the intended lines.
2. Create the key at aistudio.google.com and put it in
   `/opt/llm-gateway/litellm/litellm.env` without it ever appearing on screen or in the
   shell history, then restart LiteLLM and confirm `/v1/models` lists the new name:

   ```bash
   llmgw$ read -rs -p 'Gemini key: ' GK; echo; printf 'GEMINI_API_KEY=%s\n' "$GK" >> /opt/llm-gateway/litellm/litellm.env; unset GK
   llmgw$ grep -c '^GEMINI_API_KEY=' /opt/llm-gateway/litellm/litellm.env; stat -c '%U %a' /opt/llm-gateway/litellm/litellm.env
   llmgw$ systemctl --user restart llmgw-litellm.service && podman ps --format '{{.Names}}\t{{.Status}}'
   curl -sS $BASE/v1/models -H "Authorization: Bearer $MASTER_KEY" | python3 -c 'import sys,json; print([m["id"] for m in json.load(sys.stdin)["data"]])'
   ```
3. Issue a virtual key limited to the new model (like 5.6) and send, through it, a prompt
   containing a name:

   ```bash
   VKEY=$(curl -sS -X POST $BASE/key/generate -H "Authorization: Bearer $MASTER_KEY" -H "Content-Type: application/json" \
     -d '{"key_alias":"validation-gemini","models":["gemini-2.5-flash"],"max_budget":1,"budget_duration":"30d","duration":"7d"}' \
     | python3 -c 'import sys,json; print(json.load(sys.stdin)["key"])')
   curl -sS $BASE/v1/chat/completions \
     -H "Authorization: Bearer $VKEY" -H "Content-Type: application/json" \
     -d '{"model":"gemini-2.5-flash","messages":[{"role":"user","content":"Reply with exactly the text between the quotes: \"Hello Dennis Yurichev\""}]}' \
     | python3 -c 'import sys,json; print(json.load(sys.stdin)["choices"][0]["message"]["content"])'
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
4. Optionally narrow the egress rule to the provider's addresses (docs/02 §2.8); the
   endpoint is `generativelanguage.googleapis.com`, TCP 443.

### 5.7a Testing provider: OpenRouter, until the Gemini key exists

Added 2026-09-17 (D-31 amended). The Gemini key had not been obtained; an OpenRouter key
on a free-tier account (no credits) is used for the demonstration and for tests with
made-up data. Model entry `nemotron-3-super` in `deploy/opt/litellm/config.yaml`
(`openrouter/nvidia/nemotron-3-super-120b-a12b:free`, served by NVIDIA according to
OpenRouter's endpoint listing on 2026-09-17; 262k context, text only, reasoning returned
in a separate field). Account limits: 20 requests per minute and 50 per day across all
free models; when exhausted LiteLLM returns OpenRouter's 429 to the client. Prompts pass
OpenRouter and NVIDIA; both may keep or train on free-tier inputs.

First attempt, same day: `google/gemma-4-31b-it:free` (served by Google AI Studio, the
D-29 backend). The master-key round trip passed once, then the browser and direct calls
answered 429 `limit_source: upstream_provider_shared_pool` on most attempts. Verified
from the server: direct calls to OpenRouter failed at the same moments as calls through
LiteLLM, with and without streaming, so nothing in the gateway caused it; LiteLLM's
retries (the OpenAI client's two, wrapped by the router's, 1.100.1 `router.py`
`async_function_with_retries`) even got two calls through where the direct call failed.
Journal: eight `rate-limited upstream` lines within six seconds per browser message.
The Google free pool is shared by all OpenRouter users and saturated most of the time;
the NVIDIA endpoint answered on the first call in every test. Entry replaced.

Steps, same shape as 1 to 3 above:

1. Transfer and install the new `config.yaml` (step 1 above). The diff shows the
   `nemotron-3-super` block and two comment changes only.
2. Add the key and restart; `/v1/models` must list `nemotron-3-super`:

   ```bash
   llmgw$ read -rs -p 'OpenRouter key: ' ORK; echo; printf 'OPENROUTER_API_KEY=%s\n' "$ORK" >> /opt/llm-gateway/litellm/litellm.env; unset ORK
   llmgw$ grep -c '^OPENROUTER_API_KEY=' /opt/llm-gateway/litellm/litellm.env; stat -c '%U %a' /opt/llm-gateway/litellm/litellm.env   # 1, llmgw 600
   llmgw$ systemctl --user restart llmgw-litellm.service && podman ps --format '{{.Names}}\t{{.Status}}'
   llmgw$ curl -sS $BASE/v1/models -H "Authorization: Bearer $MASTER_KEY" | python3 -c 'import sys,json; print([m["id"] for m in json.load(sys.stdin)["data"]])'
   ```
3. Round trip through the master key first (no virtual key yet), then the spend log row.
   Spend logs are written in batches (ten seconds by default), so run the query after a
   pause:

   ```bash
   llmgw$ curl -sS $BASE/v1/chat/completions -H "Authorization: Bearer $MASTER_KEY" -H "Content-Type: application/json" -d '{"model":"nemotron-3-super","messages":[{"role":"user","content":"Reply with exactly the text between the quotes: \"Hello Dennis Yurichev\""}]}' | python3 -c 'import sys,json; r=json.load(sys.stdin); print(r["model"], "|", r["choices"][0]["message"]["content"].strip())'
   llmgw$ podman exec postgres psql -U litellm -d litellm -c "select model, model_group, spend, end_user, metadata->'applied_guardrails' as guardrails, metadata->'guardrail_information'->0->'masked_entity_count' as masked, messages::text = '{}' as no_prompt from \"LiteLLM_SpendLogs\" order by \"startTime\" desc limit 2;"
   ```

   Expected: the reply contains `Hello Dennis Yurichev` (restored on the way back; the
   provider received `Hello <PERSON_1>`), `spend` is 0 (explicit pricing), `masked`
   shows `{"PERSON": 1}`, `no_prompt` is `t`.
4. Point the front-end's key at the model. `/key/update` accepts the alias in 1.100.1
   (`key_management_endpoints.py`), so the key value is not read out; `mock-echo` leaves
   the users' key (D-29):

   ```bash
   llmgw$ curl -sS -X POST $BASE/key/update -H "Authorization: Bearer $MASTER_KEY" -H "Content-Type: application/json" -d '{"key_alias":"openwebui","models":["nemotron-3-super"]}' | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("models"), d.get("key_alias"))'
   ```

   Open WebUI reads the model list from LiteLLM on each page load; a browser reload
   shows `nemotron-3-super` and no longer `mock-echo`. Send the name test from docs/07
   §7.6 through the browser and confirm the new spend-log row carries the user's
   `end_user` id and `nemotron-3-super`.

Result 2026-09-17: all four steps pass with `nemotron-3-super`. Master-key reply
`Hello Dennis Yurichev`, spend-log row `{"PERSON": 1}`, `no_prompt` `t`; key switched
(`['nemotron-3-super'] openwebui`); browser reply "Hello Dennis Yurichev, it's great to
meet you!" with the reasoning shown as a folded "Thought for less than a second" block.
Two spend-log rows under the user's id per new chat, the answer with
`{"PERSON": 1, "EMAIL_ADDRESS": 1}` and the title generation with one more LOCATION
detection in its prompt; so a fresh chat costs two of the 50 daily requests.

Demonstration prompt, same day, with the Mastercard sandbox number 5555 5555 5555 4444:
"My card number is 5555 5555 5555 4444. Is it Visa or Mastercard? Answer with the brand
only and quote the number you see." The model's reasoning block, shown unmasked by Open
WebUI, discusses only `<CREDIT_CARD_1>` ("it's a placeholder, not actual digits, so we
cannot determine brand"), guesses Visa, which is wrong, and answers
`Visa "<CREDIT_CARD_1>"`; the browser shows `Visa "5555 5555 5555 4444"` because
LiteLLM restores the value in the answer text. The placeholder stays visible in the
reasoning block: the restore step applies to the answer content only. A first attempt at
this prompt returned an empty answer: NVIDIA reported "Service temporarily overloaded"
after the stream had begun (`MidStreamFallbackError` in the LiteLLM log), which the
front-end shows as an empty reply rather than an error; noted for the front-end
hardening list. Phase 7 is closed for the testing provider; the Gemini steps stay for
the paid phase.

Reverting to Gemini later: steps 2 and 3 above with the Gemini key, then `/key/update`
with `["gemini-2.5-flash"]`; the `nemotron-3-super` entry and `OPENROUTER_API_KEY` line
are removed when the account is closed.

Limits to state to users (D-29): the guardrail scans only the text parts of a message
(verified in 1.100.1 `presidio.py`: list content items without a `text` field are
skipped), so a file or image attachment reaches the provider unmasked; documents are
pasted as text. On the AI Studio free tier Google may use requests to improve its
products.

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

Result (2026-09-16): tunnel and login work; Models + Endpoints shows `mock-echo` with
"Defined in config" and credentials "Manual", nothing editable. The validation key had
already been deleted (5.9) when the UI was opened, so its Virtual Keys entry was not
viewed; the API check in 5.6 covers it. The "Add Model" refusal was not exercised in the
UI; the guard is verified in the source. Pass.

## 5.9 Clean up and record

- `mock-echo` stays in `config.yaml` as a test-only entry (D-29): it is what §5.4 and
  the regression checks of docs/06 §6.3 use. Virtual keys for users list the real model
  names only, so users cannot reach it.
- Delete the validation key by alias, the value was never kept: `POST /key/delete` with
  `{"key_aliases":["validation-dev1"]}`.
- Record the results (pass/fail per section, versions, date) in the phase 5 entry of
  `README.md` and any deviations in `DECISIONS.md`.

Result (2026-09-16): `POST /key/delete` by alias returned `{"deleted_keys":["validation-dev1"]}`
and `/key/info` on the alias answers 404 "Key not found in database". Phase 5 is closed except 5.7 and 5.10, which wait for the provider (D-19).

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

*Superseded 2026-09-17 (D-33):* port 4000 is not opened to a client subnet. When
litellm.xalqbank.az goes live it is published for the WAF address only, like Open WebUI
in docs/08, and the WAF exposes `/v1/` alone.

*Updated 2026-09-18:* `litellm.xalqbank.az` goes live together with Open WebUI, on
request; the steps are docs/08 §8.1 (steps 13 to 19), §8.2 and §8.3.
