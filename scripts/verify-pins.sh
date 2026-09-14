#!/usr/bin/env bash
# Run on the WORKSTATION whenever a pin in deploy/opt/bin/images.tsv is chosen or changed
# (initial pins, and docs/06 §6.3 image updates). It needs cosign, which RHEL does not
# package; the server only needs the resulting digests. For every row:
#   1. cosign-verify the multi-arch index with the vendored public key (LiteLLM only;
#      the other projects do not sign their images);
#   2. read that index from the registry by digest and confirm it lists the pinned
#      linux/amd64 manifest digest;
#   3. confirm the unit files pin the same repository:tag@digest.
# Requires: skopeo, cosign, python3.  Usage: scripts/verify-pins.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TABLE="$REPO_DIR/deploy/opt/bin/images.tsv"
KEY="$REPO_DIR/deploy/opt/bin/litellm-cosign.pub"

for t in skopeo cosign python3; do command -v "$t" >/dev/null || { echo "missing tool: $t"; exit 1; }; done
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

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
  if ! skopeo inspect --raw "docker://${repo}@${index}" > "$tmp/$name.index.json"; then
    echo "   ERROR: cannot read index ${index}"; fail=1; continue
  fi
  listed=$(python3 -c "
import json
d=json.load(open('$tmp/$name.index.json'))
print(next((m['digest'] for m in d.get('manifests',[]) if m['platform'].get('os')=='linux' and m['platform'].get('architecture')=='amd64'),''))")
  if [[ "$listed" != "$amd64" ]]; then
    echo "   ERROR: index lists linux/amd64 as '${listed}', table says '${amd64}'"; fail=1; continue
  fi
  echo "   index lists linux/amd64 = $amd64"

  if ! grep -qh -E "^Image=${repo}:${tag}@${amd64}\$" "$REPO_DIR"/deploy/opt/*/*.container; then
    echo "   ERROR: no unit pins Image=${repo}:${tag}@${amd64}"; fail=1
  else
    echo "   unit pins Image=${repo}:${tag}@${amd64}"
  fi
done < "$TABLE"

echo
if [[ "$fail" -ne 0 ]]; then echo "RESULT: FAILED"; exit 1; fi
echo "RESULT: pins verified; commit images.tsv and the units, then run bin/pull-images.sh on the server."
