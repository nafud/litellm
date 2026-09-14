#!/usr/bin/env bash
# Run on the WORKSTATION (the gateway host has no internet access).
# For every row of deploy/opt/bin/images.tsv:
#   1. cosign-verify the multi-arch index (LiteLLM only) with the vendored public key;
#   2. read the index from the registry and confirm it lists the pinned linux/amd64 digest;
#   3. copy the linux/amd64 image, by digest, into an OCI archive named after the unit's
#      repository:tag, and confirm the archive's manifest digest equals the pin;
#   4. confirm the unit files pin the same repository:tag@digest;
#   5. write SHA256SUMS for the transfer.
# Requires: skopeo, cosign, python3, sha256sum (or shasum).  Usage: scripts/fetch-images.sh [outdir]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TABLE="$REPO_DIR/deploy/opt/bin/images.tsv"
KEY="$REPO_DIR/deploy/opt/bin/litellm-cosign.pub"
OUT="${1:-$REPO_DIR/images}"

for t in skopeo cosign python3; do command -v "$t" >/dev/null || { echo "missing tool: $t"; exit 1; }; done
if command -v sha256sum >/dev/null; then SUM="sha256sum"; else SUM="shasum -a 256"; fi
mkdir -p "$OUT"

fail=0
while IFS=$'\t' read -r name repo tag index amd64 sig; do
  [[ -z "$name" || "$name" == \#* ]] && continue
  echo; echo "== $name  $repo:$tag"

  if [[ "$sig" == "cosign" ]]; then
    if cosign verify --key "$KEY" "${repo}@${index}" >/dev/null 2>&1; then
      echo "   cosign: index $index VERIFIED with $(basename "$KEY")"
    else
      echo "   ERROR: cosign verification of ${repo}@${index} FAILED"; fail=1; continue
    fi
  else
    echo "   cosign: not published by this project (digest pin only)"
  fi

  # The index is content-addressed: fetching it by digest guarantees these are the signed bytes.
  if ! skopeo inspect --raw "docker://${repo}@${index}" > "$OUT/$name.index.json"; then
    echo "   ERROR: cannot read index ${index}"; fail=1; continue
  fi
  listed=$(python3 -c "
import json,sys
d=json.load(open('$OUT/$name.index.json'))
print(next((m['digest'] for m in d.get('manifests',[]) if m['platform'].get('os')=='linux' and m['platform'].get('architecture')=='amd64'),''))")
  if [[ "$listed" != "$amd64" ]]; then
    echo "   ERROR: index lists linux/amd64 as '${listed}', table says '${amd64}'"; fail=1; continue
  fi
  echo "   index lists linux/amd64 = $amd64"

  archive="$OUT/$name.tar"
  rm -f "$archive"
  skopeo copy --quiet "docker://${repo}@${amd64}" "oci-archive:${archive}:${repo}:${tag}"
  got=$(skopeo inspect --format '{{.Digest}}' "oci-archive:${archive}")
  if [[ "$got" != "$amd64" ]]; then
    echo "   ERROR: archive manifest digest $got differs from pin $amd64"; fail=1; continue
  fi
  echo "   archive: $(basename "$archive") manifest digest $got"

  if ! grep -qh -E "^Image=${repo}:${tag}@${amd64}\$" "$REPO_DIR"/deploy/opt/*/*.container; then
    echo "   ERROR: no unit pins Image=${repo}:${tag}@${amd64}"; fail=1
  fi
done < "$TABLE"

( cd "$OUT" && $SUM *.tar > SHA256SUMS )
echo
if [[ "$fail" -ne 0 ]]; then echo "RESULT: FAILED"; exit 1; fi
echo "RESULT: archives in $OUT verified; transfer *.tar and SHA256SUMS to the server."
