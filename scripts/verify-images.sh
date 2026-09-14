#!/usr/bin/env bash
# Pull every image referenced in deploy/docker-compose.yml by its pinned digest and
# verify the LiteLLM image's cosign signature against the vendored public key.
#
# Usage:  sudo bash scripts/verify-images.sh
# Exit code is non-zero if any pull or signature verification fails.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPOSE="$REPO_DIR/deploy/docker-compose.yml"
KEY="$REPO_DIR/deploy/cosign/litellm-cosign.pub"

command -v docker >/dev/null || { echo "docker not found"; exit 1; }
command -v cosign >/dev/null || { echo "cosign not found (see docs/03-docker-install.md)"; exit 1; }

# Extract 'image:' references (tag@sha256:...) from the compose file.
mapfile -t IMAGES < <(grep -E '^\s*image:\s' "$COMPOSE" | sed -E 's/^\s*image:\s*//; s/\s+#.*$//' | tr -d '"')

fail=0
for ref in "${IMAGES[@]}"; do
  echo
  echo "== $ref"
  if [[ "$ref" != *@sha256:* ]]; then
    echo "   ERROR: not pinned by digest"; fail=1; continue
  fi
  # Pull by the exact digest so a tag move upstream cannot change what runs.
  if ! docker pull --quiet "$ref"; then
    echo "   ERROR: pull failed"; fail=1; continue
  fi
  pulled_digest=$(docker image inspect --format '{{index .RepoDigests 0}}' "$ref" 2>/dev/null || true)
  echo "   local repo digest: ${pulled_digest:-unknown}"

  case "$ref" in
    ghcr.io/berriai/*)
      # Verify by digest (repo@sha256:...), the strongest form: the signature is bound to the manifest.
      repo="${ref%%:*}"; digest="${ref##*@}"
      if cosign verify --key "$KEY" "${repo}@${digest}" >/dev/null 2>&1; then
        echo "   cosign signature: VERIFIED with $(basename "$KEY")"
      else
        echo "   ERROR: cosign verification FAILED"; fail=1
      fi
      ;;
    *)
      echo "   signature: not checked (integrity assured by digest pin only)"
      ;;
  esac
done

echo
if [ "$fail" -ne 0 ]; then echo "RESULT: FAILED"; exit 1; fi
echo "RESULT: all images pulled by digest; LiteLLM signature verified."
