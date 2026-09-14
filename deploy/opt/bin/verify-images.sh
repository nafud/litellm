#!/usr/bin/env bash
# Run on the SERVER as the service account (llmgw), after scp of the image archives.
# Loads every OCI archive from the given directory into the rootless image store
# (/opt/llm-gateway/storage) after checking its SHA256SUMS, then proves that every
# Image= reference in the units (repository:tag@digest) resolves in local storage.
# Usage: bash /opt/llm-gateway/bin/verify-images.sh /path/to/archives
set -euo pipefail

DIR="${1:?usage: verify-images.sh <archive dir>}"
UNITS=(/opt/llm-gateway/litellm/*.container /opt/llm-gateway/presidio/*.container /opt/llm-gateway/postgres/*.container)

command -v podman >/dev/null || { echo "podman not found (docs/03)"; exit 1; }
[[ "$(id -un)" == "llmgw" ]] || { echo "run as llmgw: images must land in llmgw's storage"; exit 1; }

( cd "$DIR" && sha256sum -c SHA256SUMS )
for tar in "$DIR"/*.tar; do
  echo "== loading $(basename "$tar")"
  podman load --quiet -i "$tar"
done

fail=0
echo
for ref in $(grep -h -E '^Image=' "${UNITS[@]}" | sed -E 's/^Image=//'); do
  if podman image exists "$ref"; then
    echo "OK       $ref"
  else
    echo "MISSING  $ref"; fail=1
  fi
done
echo
podman images --digests --format '{{.Repository}}:{{.Tag}}  {{.Digest}}  {{.Size}}'
echo
if [[ "$fail" -ne 0 ]]; then echo "RESULT: FAILED (a unit pins an image that is not in local storage)"; exit 1; fi
echo "RESULT: every unit's Image= resolves in local storage by digest."
