#!/usr/bin/env bash
# Run on the SERVER as llmgw. Points the rootless Quadlet search path
# (~/.config/containers/systemd) at the unit files kept next to each component under
# /opt/llm-gateway, then reloads the user manager. Symlinks inside the search path are
# supported by podman-systemd.unit(5). Re-runnable.
set -euo pipefail
BASE=/opt/llm-gateway
DEST="${XDG_CONFIG_HOME:-$HOME/.config}/containers/systemd"
mkdir -p "$DEST"
for f in "$BASE"/network/*.network "$BASE"/postgres/*.container "$BASE"/presidio/*.container "$BASE"/litellm/*.container "$BASE"/openwebui/*.container; do
  ln -sfn "$f" "$DEST/$(basename "$f")"
done
ls -l "$DEST"
systemctl --user daemon-reload
systemctl --user list-unit-files 'llmgw-*'
