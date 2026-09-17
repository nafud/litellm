#!/usr/bin/env bash
# Run on the SERVER as the service account (llmgw). The host has internet access, so the
# images are pulled here, straight from the registries, by the digests pinned in
# images.tsv and in the units. For every row of images.tsv:
#   1. read the multi-arch index from the registry BY ITS PINNED DIGEST (content-addressed:
#      the registry cannot substitute bytes without changing the digest) and confirm it
#      lists the pinned linux/amd64 manifest digest;
#   2. podman pull repository:tag@amd64-digest, the exact string the unit's Image= uses
#      (Podman verifies the pulled manifest against the digest);
#   3. confirm that every Image= line in the units resolves in local storage.
# cosign verification of the LiteLLM index is done when a pin is chosen or changed
# (scripts/verify-pins.sh on the workstation, D-18); this script trusts the digests
# recorded in images.tsv. If cosign is present on the server it is used as well.
# Usage: bash /opt/llm-gateway/bin/pull-images.sh
set -euo pipefail

BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TABLE="$BIN/images.tsv"
KEY="$BIN/litellm-cosign.pub"
UNITS=(/opt/llm-gateway/litellm/*.container /opt/llm-gateway/presidio/*.container /opt/llm-gateway/postgres/*.container /opt/llm-gateway/openwebui/*.container)

for t in podman skopeo python3; do command -v "$t" >/dev/null || { echo "missing tool: $t (docs/03 §3.1)"; exit 1; }; done
[[ "$(id -un)" == "llmgw" ]] || { echo "run as llmgw: images must land in llmgw's storage"; exit 1; }

fail=0
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
while IFS=$'\t' read -r name repo tag index amd64 sig; do
  [[ -z "$name" || "$name" == \#* ]] && continue
  echo; echo "== $name  $repo:$tag"

  if [[ "$sig" == "cosign" ]] && command -v cosign >/dev/null; then
    if cosign verify --key "$KEY" "${repo}@${index}" >/dev/null 2>&1; then
      echo "   cosign: index $index VERIFIED with $(basename "$KEY")"
    else
      echo "   ERROR: cosign verification of ${repo}@${index} FAILED"; fail=1; continue
    fi
  elif [[ "$sig" == "cosign" ]]; then
    echo "   cosign: not installed here; index digest verified on the workstation when pinned (images.tsv)"
  else
    echo "   cosign: not published by this project (digest pin only)"
  fi

  if ! skopeo inspect --raw "docker://${repo}@${index}" > "$tmp/$name.index.json"; then
    echo "   ERROR: cannot read index ${index} from the registry"; fail=1; continue
  fi
  listed=$(python3 -c "
import json
d=json.load(open('$tmp/$name.index.json'))
print(next((m['digest'] for m in d.get('manifests',[]) if m['platform'].get('os')=='linux' and m['platform'].get('architecture')=='amd64'),''))")
  if [[ "$listed" != "$amd64" ]]; then
    echo "   ERROR: index lists linux/amd64 as '${listed}', table says '${amd64}'"; fail=1; continue
  fi
  echo "   index lists linux/amd64 = $amd64"

  if ! grep -qhxF "Image=${repo}:${tag}@${amd64}" "${UNITS[@]}"; then
    echo "   ERROR: no unit pins Image=${repo}:${tag}@${amd64}"; fail=1; continue
  fi

  if podman image exists "${repo}:${tag}@${amd64}"; then
    echo "   already in local storage"
  else
    podman pull --quiet "${repo}:${tag}@${amd64}" >/dev/null
    echo "   pulled"
  fi
done < "$TABLE"

echo
for ref in $(grep -h -E '^Image=' "${UNITS[@]}" | sed -E 's/^Image=//'); do
  if podman image exists "$ref"; then echo "OK       $ref"; else echo "MISSING  $ref"; fail=1; fi
done
echo
podman images --digests --format '{{.Repository}}  {{.Digest}}  {{.Size}}'
echo
if [[ "$fail" -ne 0 ]]; then echo "RESULT: FAILED"; exit 1; fi
echo "RESULT: every unit's Image= resolves in local storage by digest."
