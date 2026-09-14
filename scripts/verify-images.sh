#!/usr/bin/env bash
# Pull every image referenced by the Quadlet units (deploy/quadlet/*.container) by its
# pinned digest into the rootless storage of the user running this script, and verify
# the LiteLLM image's cosign signature against the vendored public key.
#
# Run as the service account:   sudo -iu llmgw  ->  bash /opt/llm-gateway/repo/scripts/verify-images.sh
# Exit code is non-zero if any image is unpinned, any pull fails, or the signature check fails.
#
# Why cosign and not podman's own policy.json: LiteLLM signs the multi-arch image index,
# not the per-platform manifest that a pull selects, and podman's sigstore policy looks
# for a signature on the pulled manifest (verified with skopeo on 2026-09-14, see
# DECISIONS.md D-13). cosign verifies the index digest, which is exactly what is pinned.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
UNIT_DIR="$REPO_DIR/deploy/quadlet"
KEY="$REPO_DIR/deploy/cosign/litellm-cosign.pub"
COSIGN="${COSIGN:-cosign}"

command -v podman >/dev/null || { echo "podman not found (see docs/03-podman-install.md)"; exit 1; }
command -v "$COSIGN" >/dev/null || { echo "cosign not found (see docs/03-podman-install.md §3.4)"; exit 1; }
[ "$(id -u)" -ne 0 ] || echo "WARNING: running as root pulls into root's storage, not the service account's"

# Extract 'Image=' references from the container units.
mapfile -t IMAGES < <(grep -h -E '^Image=' "$UNIT_DIR"/*.container | sed -E 's/^Image=//; s/[[:space:]]+#.*$//')

fail=0
for ref in "${IMAGES[@]}"; do
  echo
  echo "== $ref"
  if [[ "$ref" != *@sha256:* ]]; then
    echo "   ERROR: not pinned by digest"; fail=1; continue
  fi
  repo="${ref%%@*}"; repo="${repo%%:*}"; digest="${ref##*@}"

  # Pull by the exact digest so a tag move upstream cannot change what runs.
  if ! podman pull --quiet "${repo}@${digest}" >/dev/null; then
    echo "   ERROR: pull failed"; fail=1; continue
  fi
  # Tag it with the unit's tag@digest form so 'podman images' shows the version we pinned.
  podman tag "${repo}@${digest}" "$ref" 2>/dev/null || true
  echo "   pulled: ${repo}@${digest}"

  case "$repo" in
    ghcr.io/berriai/*)
      # Verify by digest (repo@sha256:...): the signature is bound to the manifest index.
      if "$COSIGN" verify --key "$KEY" "${repo}@${digest}" >/dev/null 2>&1; then
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
