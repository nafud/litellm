# Phase 5: Validation

Run from the server itself while `LITELLM_BIND_ADDR=127.0.0.1`. Export the master key
for the session only:

```bash
export MASTER_KEY="$(sudo grep '^LITELLM_MASTER_KEY=' /opt/llm-gateway/deploy/litellm.env | cut -d= -f2-)"
export BASE=http://127.0.0.1:4000
```

## 5.1 Health

```bash
curl -sS $BASE/health/liveliness            # public route: "I'm alive!"
curl -sS -H "Authorization: Bearer $MASTER_KEY" $BASE/health/readiness | python3 -m json.tool
```

Readiness must report `"status": "connected"` for the database and list `presidio-pii`
under the guardrails/callbacks it shows.

## 5.2 Presidio services directly (from the LiteLLM container, they are not published)

```bash
sudo docker compose -f /opt/llm-gateway/deploy/docker-compose.yml exec litellm \
  python3 - <<'PY'
import json, urllib.request
req = urllib.request.Request("http://presidio-analyzer:3000/analyze",
    data=json.dumps({"text": "My name is Dennis Yurichev, mail dennis@example.com", "language": "en"}).encode(),
    headers={"Content-Type": "application/json"})
print(json.dumps(json.load(urllib.request.urlopen(req, timeout=30)), indent=1))
PY
```

Expect two results: `PERSON` (score around 0.85) and `EMAIL_ADDRESS` (score 1.0).

## 5.3 Masking as the provider would see it

`/guardrails/apply_guardrail` runs the guardrail on text and returns the masked form:

```bash
curl -sS -X POST $BASE/guardrails/apply_guardrail \
  -H "Authorization: Bearer $MASTER_KEY" -H "Content-Type: application/json" \
  -d '{"guardrail_name":"presidio-pii","text":"My name is Dennis Yurichev, mail dennis@example.com, card 4111 1111 1111 1111"}'
```

Expected `response_text`: `My name is <PERSON>, mail <EMAIL_ADDRESS>, card <CREDIT_CARD>`.

## 5.4 End-to-end mask + restore, without a provider

`mock-echo` returns a fixed reply containing `<PERSON_1>` and `<EMAIL_ADDRESS_1>`. If the
`post_call` restoration works, those tokens come back replaced with the values from the
request:

```bash
curl -sS $BASE/v1/chat/completions \
  -H "Authorization: Bearer $MASTER_KEY" -H "Content-Type: application/json" \
  -d '{"model":"mock-echo","messages":[{"role":"user","content":"I am Dennis Yurichev, dennis@example.com"}]}' \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["choices"][0]["message"]["content"])'
```

Expected: `Mock reply. Restored placeholders: Dennis Yurichev dennis@example.com`.

Streaming path (the restore logic is separate for streams):

```bash
curl -sS -N $BASE/v1/chat/completions \
  -H "Authorization: Bearer $MASTER_KEY" -H "Content-Type: application/json" \
  -d '{"model":"mock-echo","stream":true,"messages":[{"role":"user","content":"I am Dennis Yurichev, dennis@example.com"}]}' \
  | grep -o '"content":"[^"]*"' | tr -d '\n'; echo
```

The concatenated content must again read `... Dennis Yurichev dennis@example.com`.

## 5.5 Fail-closed check

Stop the analyzer and repeat 5.4: the request must be rejected (HTTP 4xx/5xx with a
guardrail error), never forwarded unmasked.

```bash
sudo docker compose -f /opt/llm-gateway/deploy/docker-compose.yml stop presidio-analyzer
curl -sS -o /dev/null -w 'HTTP %{http_code}\n' $BASE/v1/chat/completions \
  -H "Authorization: Bearer $MASTER_KEY" -H "Content-Type: application/json" \
  -d '{"model":"mock-echo","messages":[{"role":"user","content":"I am Dennis Yurichev"}]}'
sudo docker compose -f /opt/llm-gateway/deploy/docker-compose.yml start presidio-analyzer
```

## 5.6 Virtual keys and budgets

```bash
curl -sS -X POST $BASE/key/generate \
  -H "Authorization: Bearer $MASTER_KEY" -H "Content-Type: application/json" \
  -d '{"key_alias":"validation-dev1","models":["claude-sonnet-5","mock-echo"],"max_budget":5,"budget_duration":"30d","duration":"30d"}'
```

Save the returned `key` (`sk-...`). Then, with that key:

- a request to `mock-echo` succeeds;
- a request to `claude-opus-5` is refused (not in the key's model list);
- `GET /key/info?key=<key>` with the master key shows the alias, budget and spend.

## 5.7 Real provider round trip

Only after 5.1 to 5.6 pass, with the virtual key from 5.6:

```bash
curl -sS $BASE/v1/chat/completions \
  -H "Authorization: Bearer <virtual-key>" -H "Content-Type: application/json" \
  -d '{"model":"claude-sonnet-5","messages":[{"role":"user","content":"Reply with exactly the text between the quotes: \"Hello Dennis Yurichev\""}]}'
```

The reply must contain `Hello Dennis Yurichev` (restored), while the provider only
received `Hello <PERSON_1>`. To see that from LiteLLM's side, the spend log row for the
request records which guardrail ran and how many entities were masked, without the
prompt body:

```bash
sudo docker compose -f /opt/llm-gateway/deploy/docker-compose.yml exec postgres \
  psql -U litellm -d litellm -c \
  "select request_id, model, spend, metadata->'applied_guardrails' as guardrails, metadata->'guardrail_information' as info from \"LiteLLM_SpendLogs\" order by \"startTime\" desc limit 3;"
```

Confirm the `messages` and `response` columns of the same rows are empty objects
(`store_prompts_in_spend_logs: false`).

## 5.8 Admin UI

`http://127.0.0.1:4000/ui` via an SSH tunnel (`ssh -L 4000:127.0.0.1:4000 <admin>@<server>`),
login with `UI_USERNAME` / `UI_PASSWORD`. Confirm: models are listed but not editable
(config-driven), the key from 5.6 appears with its budget, and there is no way to add
provider credentials.

## 5.9 Clean up and record

- Remove the `mock-echo` entry from `deploy/litellm/config.yaml`, commit, and
  `sudo docker compose up -d litellm` (config is mounted, so a restart applies it).
- Delete the validation key: `POST /key/delete` with `{"keys":["<key>"]}`.
- Record the results (pass/fail per section, versions, date) in the phase 5 entry of
  `README.md` and any deviations in `DECISIONS.md`.

## 5.10 Exit criteria

All of 5.1 to 5.7 pass as described; 5.5 proves fail-closed. Then switch
`LITELLM_BIND_ADDR` to the LAN IP (`docker compose up -d litellm`), re-check `ss -tlnp`,
and confirm the `DOCKER-USER` rules limit access to the client subnet.
