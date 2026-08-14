#!/usr/bin/env bash
# Per-boot virtual display + software Vulkan for windowed Godot on Cursor Cloud.
#
# Reuses an already-working DISPLAY (computer-use desktops often own :1).
# Otherwise starts Xvfb at the canonical 1152x648 sweep window. Idempotent:
# a second call finds the live server and returns. Never prints secrets.
set -euo pipefail

CANONICAL_W=1152
CANONICAL_H=648
DISPLAY_NUM="${POKEWILDS_XVFB_DISPLAY:-99}"
ENV_FILE="${POKEWILDS_CLOUD_ENV_FILE:-${HOME}/.pokewilds-cloud.env}"
LVP_ICD_CANDIDATES=(
  /usr/share/vulkan/icd.d/lvp_icd.x86_64.json
  /usr/share/vulkan/icd.d/lvp_icd.json
)

_display_alive() {
  local d="$1"
  DISPLAY="$d" xdpyinfo >/dev/null 2>&1
}

_pick_lvp_icd() {
  local candidate
  for candidate in "${LVP_ICD_CANDIDATES[@]}"; do
    if [[ -f "${candidate}" ]]; then
      printf '%s' "${candidate}"
      return 0
    fi
  done
  return 1
}

if [[ -n "${DISPLAY:-}" ]] && _display_alive "${DISPLAY}"; then
  echo "ensure_cloud_display: reusing live DISPLAY=${DISPLAY}"
else
  export DISPLAY=":${DISPLAY_NUM}"
  if _display_alive "${DISPLAY}"; then
    echo "ensure_cloud_display: reusing Xvfb DISPLAY=${DISPLAY}"
  else
    echo "ensure_cloud_display: starting Xvfb ${DISPLAY} ${CANONICAL_W}x${CANONICAL_H}x24"
    Xvfb "${DISPLAY}" -screen 0 "${CANONICAL_W}x${CANONICAL_H}x24" -ac +extension GLX +render -noreset >/tmp/pokewilds-xvfb.log 2>&1 &
    echo $! > /tmp/pokewilds-xvfb.pid
    for _i in 1 2 3 4 5 6 7 8 9 10; do
      if _display_alive "${DISPLAY}"; then
        break
      fi
      sleep 0.2
    done
    if ! _display_alive "${DISPLAY}"; then
      echo "ensure_cloud_display: Xvfb failed to become ready; see /tmp/pokewilds-xvfb.log" >&2
      exit 1
    fi
  fi
fi

if ICD="$(_pick_lvp_icd)"; then
  export VK_ICD_FILENAMES="${ICD}"
  echo "ensure_cloud_display: lavapipe ICD ${ICD}"
else
  echo "ensure_cloud_display: no lavapipe ICD (mesa-vulkan-drivers missing?); Godot will use the default Vulkan loader"
fi

umask 077
{
  printf 'export DISPLAY=%q\n' "${DISPLAY}"
  if [[ -n "${VK_ICD_FILENAMES:-}" ]]; then
    printf 'export VK_ICD_FILENAMES=%q\n' "${VK_ICD_FILENAMES}"
  fi
  if [[ -n "${GODOT_BIN:-}" ]]; then
    printf 'export GODOT_BIN=%q\n' "${GODOT_BIN}"
  fi
  printf 'export COMMANDCODE_SKIP_UPDATES=1\n'
  printf 'export GODOT_AUDIO_DRIVER=Dummy\n'
} > "${ENV_FILE}"
echo "ensure_cloud_display: wrote ${ENV_FILE}"
