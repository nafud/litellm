# LiteLLM image signing key

`litellm-cosign.pub` is the cosign public key BerriAI uses to sign every image
published under `ghcr.io/berriai/` (since v1.83.0, including the `-non_root` variant).

Provenance, fetched on 2026-09-14 and identical at both locations:

- `https://raw.githubusercontent.com/BerriAI/litellm/0112e53046018d726492c814b3644b7d376029d0/cosign.pub`
  (the commit LiteLLM's Docker Image Security Guide pins)
- `https://raw.githubusercontent.com/BerriAI/litellm/main/cosign.pub`

Vendoring the key here means verification does not depend on GitHub being reachable
from the server and cannot be silently changed upstream. If LiteLLM rotates the key,
update this file deliberately and record why in `DECISIONS.md`.
