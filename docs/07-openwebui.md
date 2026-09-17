# Phase 8: Open WebUI, the users' front-end

Users never get the LiteLLM admin UI. They get Open WebUI (chosen in D-30), one more
rootless container on the same host, whose only model source is LiteLLM on the internal
network. Prerequisite: docs/05 §5.7 passed, because the front-end's virtual key lists
`gemini-2.5-flash` only. The container work takes about an hour; what remains afterwards
is exposure (TLS, DNS name, firewalld), which is §7.8 and D-10.

Files added to the repository for this phase: `deploy/opt/openwebui/llmgw-openwebui.container`
(every setting, with the reason for each), `deploy/opt/openwebui/openwebui.env.example`
(the three secrets), one row in `deploy/opt/bin/images.tsv`, the `openwebui` directory
in `bin/pull-images.sh` and `bin/link-quadlets.sh`, `user_header_name` in
`litellm/config.yaml`, and `MemoryMax=4G` in `litellm/llmgw-litellm.container` (D-15).

## 7.1 Files onto the server (admin account)

From the workstation, out of the extracted ZIP (docs/03 §3.3 conventions):

```
scp litellm-claude-zealous-lamport-kklwuf\deploy\opt\openwebui\llmgw-openwebui.container litellm-claude-zealous-lamport-kklwuf\deploy\opt\openwebui\openwebui.env.example litellm-claude-zealous-lamport-kklwuf\deploy\opt\bin\images.tsv litellm-claude-zealous-lamport-kklwuf\deploy\opt\bin\pull-images.sh litellm-claude-zealous-lamport-kklwuf\deploy\opt\bin\link-quadlets.sh litellm-claude-zealous-lamport-kklwuf\deploy\opt\litellm\config.yaml litellm-claude-zealous-lamport-kklwuf\deploy\opt\litellm\llmgw-litellm.container infosec@10.50.4.68:/tmp/
```

On the server, CRLF check and diff of the five files that already exist:

```bash
infosec$ cd /tmp && grep -c $'\r' llmgw-openwebui.container openwebui.env.example images.tsv pull-images.sh link-quadlets.sh config.yaml llmgw-litellm.container   # every line ends in :0
infosec$ for f in bin/images.tsv bin/pull-images.sh bin/link-quadlets.sh litellm/config.yaml litellm/llmgw-litellm.container; do echo "== $f"; diff /opt/llm-gateway/$f /tmp/$(basename $f); done
```

Expected: `images.tsv` one comment line changed and one `openwebui` row added;
`pull-images.sh` the `UNITS=` line; `link-quadlets.sh` the `for f in` line;
`config.yaml` six comment lines and `user_header_name: X-OpenWebUI-User-Id` added under
`general_settings`, nothing else; `llmgw-litellm.container` the `MemoryMax` block only.
Anything beyond that means the server copy drifted from the repository: stop and compare.

Install (directory modes as in docs/03 §3.3; the data directory is created here so that
it is owned by `llmgw` before Podman first mounts it):

```bash
infosec$ sudo install -d -m 750 -o llmgw -g llmgw /opt/llm-gateway/openwebui
infosec$ sudo install -d -m 700 -o llmgw -g llmgw /opt/llm-gateway/openwebui/data
infosec$ sudo install -m 640 -o llmgw -g llmgw /tmp/llmgw-openwebui.container /tmp/openwebui.env.example /opt/llm-gateway/openwebui/
infosec$ sudo install -m 640 -o llmgw -g llmgw /tmp/images.tsv /opt/llm-gateway/bin/images.tsv
infosec$ sudo install -m 750 -o llmgw -g llmgw /tmp/pull-images.sh /tmp/link-quadlets.sh /opt/llm-gateway/bin/
infosec$ sudo install -m 644 -o llmgw -g llmgw /tmp/config.yaml /opt/llm-gateway/litellm/config.yaml
infosec$ sudo install -m 644 -o llmgw -g llmgw /tmp/llmgw-litellm.container /opt/llm-gateway/litellm/llmgw-litellm.container
infosec$ rm /tmp/llmgw-openwebui.container /tmp/openwebui.env.example /tmp/images.tsv /tmp/pull-images.sh /tmp/link-quadlets.sh /tmp/config.yaml /tmp/llmgw-litellm.container
infosec$ ls -la /opt/llm-gateway/openwebui /opt/llm-gateway/bin; ls -laZ /opt/llm-gateway/openwebui/data
```

## 7.2 Pull the image (service account)

`pull-images.sh` is re-runnable: the four existing images report "already in local
storage", the new one is pulled by digest (1.8 GB compressed; the project publishes no
cosign signature, so this is a digest pin like Presidio and PostgreSQL):

```bash
llmgw$ bash /opt/llm-gateway/bin/pull-images.sh
llmgw$ podman image inspect --format 'user={{.User}} entrypoint={{.Config.Entrypoint}} cmd={{.Config.Cmd}} port={{.Config.ExposedPorts}}' ghcr.io/open-webui/open-webui:v0.11.3@sha256:9cd136effce6bb12a6a1988a35ab3b82cb40c48a6768fceeb17c83baf7cfac9c
```

Expected: `RESULT: every unit's Image= resolves in local storage by digest.` and
`user=0:0` (the unit's comment relies on it; if the user is not 0, stop and report).
The full `repo:tag@digest` reference is needed: an image pulled by digest is not stored
under the bare tag. On disk the image is 5.16 GB (1.8 GB compressed): it carries the
embedding and speech models.

## 7.3 Database role and the env file (service account)

Open WebUI gets its own role and database in the existing PostgreSQL container, so one
dump procedure covers both products (docs/06 §6.1). The password never appears on a
command line: it is generated into a shell variable, piped into `psql`, written into the
env file by `sed`, and unset.

```bash
llmgw$ install -m 600 /opt/llm-gateway/openwebui/openwebui.env.example /opt/llm-gateway/openwebui/openwebui.env
llmgw$ OWPW=$(openssl rand -hex 32); OWSK=$(openssl rand -hex 32)
llmgw$ printf "CREATE ROLE openwebui LOGIN PASSWORD '%s';\nCREATE DATABASE openwebui OWNER openwebui;\n" "$OWPW" | podman exec -i postgres psql -U litellm -d postgres -v ON_ERROR_STOP=1
llmgw$ sed -i -e "s|^WEBUI_SECRET_KEY=.*|WEBUI_SECRET_KEY=$OWSK|" -e "s|^DATABASE_URL=.*|DATABASE_URL=postgresql://openwebui:$OWPW@postgres:5432/openwebui|" /opt/llm-gateway/openwebui/openwebui.env
llmgw$ unset OWPW OWSK
llmgw$ podman exec postgres psql -U litellm -d postgres -tAc "select datname, pg_get_userbyid(datdba) from pg_database where datname='openwebui'"
llmgw$ grep -c REPLACE /opt/llm-gateway/openwebui/openwebui.env    # 1: only OPENAI_API_KEY is left
```

Expected: `CREATE ROLE`, `CREATE DATABASE`, then `openwebui|openwebui`, then `1`.

## 7.4 The front-end's LiteLLM key (service account)

One virtual key for the whole front-end, alias `openwebui`, limited to the models the
users may see and to a monthly budget (the number is the pilot's; raise it in the admin
UI, never by regenerating). Per-person accounting still works: LiteLLM records the
`X-OpenWebUI-User-Id` header as `end_user` on every request (§7.6).

```bash
llmgw$ export MASTER_KEY="$(grep '^LITELLM_MASTER_KEY=' /opt/llm-gateway/litellm/litellm.env | cut -d= -f2-)"; export BASE=http://127.0.0.1:4000
llmgw$ OWKEY=$(curl -sS -X POST $BASE/key/generate -H "Authorization: Bearer $MASTER_KEY" -H "Content-Type: application/json" -d '{"key_alias":"openwebui","models":["gemini-2.5-flash"],"max_budget":20,"budget_duration":"30d","metadata":{"purpose":"Open WebUI service key (docs/07 §7.4)"}}' | python3 -c 'import sys,json; print(json.load(sys.stdin)["key"])')
llmgw$ echo "${#OWKEY}"                                                # 25
llmgw$ sed -i "s|^OPENAI_API_KEY=.*|OPENAI_API_KEY=$OWKEY|" /opt/llm-gateway/openwebui/openwebui.env; unset OWKEY
llmgw$ grep -c REPLACE /opt/llm-gateway/openwebui/openwebui.env; stat -c '%U %a' /opt/llm-gateway/openwebui/openwebui.env   # 0, llmgw 600
llmgw$ curl -sS "$BASE/key/info" -H "Authorization: Bearer $MASTER_KEY" -G --data-urlencode "key=$(grep '^OPENAI_API_KEY=' /opt/llm-gateway/openwebui/openwebui.env | cut -d= -f2-)" | python3 -c 'import sys,json; i=json.load(sys.stdin)["info"]; print(i["key_alias"], i["models"], i["max_budget"], i["budget_duration"])'
```

Expected last line: `openwebui ['gemini-2.5-flash'] 20.0 30d`.

## 7.5 Link, reload, restart LiteLLM, start Open WebUI (service account)

LiteLLM restarts because its config and its unit changed (header mapping, ceiling).
Presidio and PostgreSQL are untouched.

```bash
llmgw$ bash /opt/llm-gateway/bin/link-quadlets.sh                      # now lists llmgw-openwebui.service
llmgw$ systemctl --user restart llmgw-litellm.service && systemctl --user show llmgw-litellm.service -p MemoryMax
llmgw$ systemctl --user start llmgw-openwebui.service; systemctl --user status llmgw-openwebui.service --no-pager | head -12
llmgw$ podman ps --format '{{.Names}}\t{{.Status}}'
llmgw$ podman logs --since 5m openwebui 2>&1 | grep -viE 'INFO:     127.0.0.1' | tail -40
```

Expected: `MemoryMax=4294967296`; the start returns once the health check passes (up to
three minutes on first start: migrations, then the embedding model loads); five
containers `healthy`; the log shows the migrations, the version banner and
`Uvicorn running on http://0.0.0.0:8080`, no `ERROR` and no attempt to reach
`huggingface.co` or `github.com`. The unit logs to journald, so read it from the admin
account: `sudo journalctl _SYSTEMD_USER_UNIT=llmgw-openwebui.service --since -10m --no-pager -o cat`.

First start on 2026-09-17: healthy in 30 s, 759 MB, but the log carried
`ERROR ... Error loading SentenceTransformer: Cannot find an appropriate cached snapshot
folder ... outgoing traffic has been disabled`. Cause: the unit mounted the data
directory at `/app/backend/data`, where the image keeps its baked-in models under
`cache/`, so the bind mount hid them. Fixed in the unit with `DATA_DIR=/data` and the
volume at `/data` (verified in v0.11.3 env.py: `DATA_DIR` is read from the environment;
retrieval/utils.py looks the model up through `SENTENCE_TRANSFORMERS_HOME`, which stays
inside the image). The data directory was emptied before the restart (no account existed yet).

## 7.6 First admin account and round trip (workstation, browser)

Second tunnel, in its own window, alongside the LiteLLM one:

```
ssh -L 8080:127.0.0.1:8080 infosec@10.50.4.68
```

Then `http://127.0.0.1:8080/` in the browser. On an empty database the page offers to
create the first account, which becomes the admin: name, e-mail (the address is a login
identifier only, no mail is sent), a password from the password manager. After that the
sign-up form is gone (`ENABLE_SIGNUP=false`): further accounts are created by the admin
under Admin Panel, Users, and are `pending` until activated.

Checks, in order:

1. Model selector shows `gemini-2.5-flash` and nothing else (the key's model list;
   `mock-echo` is not in it).
2. Send `Reply with exactly the text between the quotes: "Hello Dennis Yurichev"`.
   Expected: the reply contains `Hello Dennis Yurichev`; the chat gets a title (one
   background call).
3. Admin Panel, Users: note the admin's id (a UUID). On the server, the spend log carries
   it as `end_user`, the prompt and response columns hold the literal `{}` that LiteLLM
   writes when `store_prompts_in_spend_logs` is false (verified in 1.100.1
   spend_tracking_utils.py), and the request came through the `openwebui` key:

   ```bash
   llmgw$ podman exec postgres psql -U litellm -d litellm -tAc "select \"startTime\", model, end_user, spend, messages::text = '{}' as no_prompt, response::text = '{}' as no_response from \"LiteLLM_SpendLogs\" order by \"startTime\" desc limit 3"
   llmgw$ podman exec postgres psql -U litellm -d litellm -tAc "select key_alias, spend from \"LiteLLM_VerificationToken\" where key_alias='openwebui'"
   ```

4. Masking end to end, as in docs/05 §5.4 but through the browser: the proof is the
   reply itself, the values restored in place of the placeholders. The LiteLLM log
   carries nothing per request at INFO (the guardrail logs at DEBUG only, docs/05 §5.4),
   so there is no log line to look for.
5. Log out and log in again (cookie signing key works across the session).

## 7.7 Measure (service account, after ten minutes of use)

The ceilings in D-15 were re-cut without a measurement of Open WebUI; this records one.

```bash
llmgw$ for u in llmgw-litellm llmgw-openwebui llmgw-presidio-analyzer llmgw-presidio-anonymizer llmgw-postgres; do printf '%-28s %s\n' $u "$(systemctl --user show $u.service -p MemoryCurrent --value | numfmt --to=iec)"; done
llmgw$ podman stats --no-stream --format '{{.Name}}\t{{.MemUsage}}\t{{.CPUPerc}}'
llmgw$ free -m
```

From the admin account, the log rate of the new unit over the same window (SIEM
concern, docs/04 §4.5): `sudo journalctl _SYSTEMD_USER_UNIT=llmgw-openwebui.service --since -10m | wc -l`.
Record the figures in D-32; if Open WebUI's working set is above 1.5 GiB or LiteLLM's
above 3 GiB, revisit the split before any user is invited.

## 7.8 Exit criteria and what comes next

- Five units active and healthy after a `systemctl --user restart llmgw-openwebui.service`.
- §7.6 checks 1 to 5 pass; results recorded below.
- Everything the users see comes from the unit and the env file: the admin panel's
  Connections and Settings pages show the values and changing them there does not
  survive a restart (by design, `ENABLE_PERSISTENT_CONFIG=false`).

Not part of this phase, in this order: TLS termination and a DNS name (D-10), firewalld
enabled with a source range for the users (D-22, docs/02 §2.7), the second
`PublishPort=` on this unit, Active Directory login through the LDAP settings of the
unit, and the OpenCode client configuration for developers.

## Results

2026-09-17, run in the order above, without the Gemini key (§5.7 not yet run, so the
`openwebui` key lists `mock-echo` only; switched to `nemotron-3-super` in docs/05 §5.7a the
same day, and to `gemini-2.5-flash` with `/key/update` once that key exists).

- §7.1: seven files transferred, CRLF 0, diffs exactly as described. Two comment blocks
  in config.yaml differed because the earlier scope fix had been applied by `sed` on the
  server without the comments; the `presidio_filter_scope: input` line itself was identical.
- §7.2: pull OK, 1.8 GB compressed, 5.16 GB on disk; `user=0:0`, `cmd=[bash start.sh]`,
  port 8080.
- §7.3, §7.4: role and database created; key alias `openwebui`, 25 characters,
  `['mock-echo'] 20.0 30d`; env file `llmgw 600`, no placeholder left.
- §7.5: LiteLLM restarted, `MemoryMax=4294967296`, both models listed. Open WebUI healthy
  in 30 s at 759 MB, but with the embedding-model error described in §7.5; fixed by the
  `/data` mount, second start healthy at 763 MB, log shows
  `Loading SentenceTransformer model from /app/backend/data/cache/embedding/models/...`
  and no `ERROR`. The application logs in UTC (four hours behind the podman lines).
- §7.6: onboarding page, admin account created (`admin`). Model selector shows
  `mock-echo` only. Prompt `My name is Dennis Yurichev, e-mail dennis@example.com.
  Summarise this.` returned `Mock reply. Restored placeholders: Dennis Yurichev
  dennis@example.com`. Spend log: three rows (`test` message, its title generation
  80 ms later, the PII prompt), each with the admin's UUID in `end_user`, `{}` in both
  body columns, key `openwebui` at spend 0.
- §7.6 check 5: sign out and log in again work, the login form offers no sign-up, chats
  persist (they live in the `openwebui` database).
- §7.7 after 20 minutes of use: LiteLLM 906 MB (ceiling 4 GiB), Open WebUI 778 MB
  (2 GiB), analyzer 2.2 GB (5 GiB), anonymizer 56 MB (1 GiB), PostgreSQL 270 MB
  (1.5 GiB); host 5.2 GB used of 15.7 GB, swap 0. The D-15 split holds.
