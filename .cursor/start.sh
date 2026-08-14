#!/usr/bin/env bash
# Per-boot Cloud Agent start: bring up the windowed display Godot needs.
# Must return after readiness — Xvfb is backgrounded when this script starts it.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="${HOME}/.local/bin:${PATH}"
if [[ -x "${HOME}/godot-bin/godot" ]]; then
  export GODOT_BIN="${HOME}/godot-bin/godot"
fi
bash "${REPO_ROOT}/tools/ensure_cloud_display.sh"
if [[ -f "${HOME}/.pokewilds-cloud.env" ]]; then
  # shellcheck disable=SC1091
  source "${HOME}/.pokewilds-cloud.env"
fi
echo "start: DISPLAY=${DISPLAY:-unset} GODOT_BIN=${GODOT_BIN:-unset} cmd=$(command -v cmd || echo missing)"
