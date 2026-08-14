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

_display_num() {
  local d="$1"
  local num="${d##*:}"
  printf '%s' "${num%%.*}"
}

_display_alive() {
  local d="$1"
  # Prefer xdpyinfo (x11-utils). xvfb does not depend on it, so a Cloud
  # image that only installed xvfb would otherwise treat every display as
  # dead and exit before writing ~/.pokewilds-cloud.env.
  if command -v xdpyinfo >/dev/null 2>&1; then
    DISPLAY="$d" xdpyinfo >/dev/null 2>&1
    return
  fi
  [[ -S "/tmp/.X11-unix/X$(_display_num "${d}")" ]]
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

if ! command -v xdpyinfo >/dev/null 2>&1; then
  echo "ensure_cloud_display: xdpyinfo missing; probing /tmp/.X11-unix sockets (install x11-utils)"
fi

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

# environment.json `start` runs start.sh in a child. Persist the file into
# later interactive/login shells. Non-interactive `python3 tools/verify_all.py`
# still needs tools/cloud_env.py (bashrc is not sourced there).
_CLOUD_ENV_HOOK='[ -f "$HOME/.pokewilds-cloud.env" ] && . "$HOME/.pokewilds-cloud.env"'
_install_cloud_env_hook() {
  local target="$1"
  if [[ ! -e "${target}" ]]; then
    printf '%s\n' "${_CLOUD_ENV_HOOK}" > "${target}"
    echo "ensure_cloud_display: created ${target} hook"
    return
  fi
  if grep -qxF "${_CLOUD_ENV_HOOK}" "${target}" 2>/dev/null; then
    return
  fi
  printf '\n%s\n' "${_CLOUD_ENV_HOOK}" >> "${target}"
  echo "ensure_cloud_display: appended hook to ${target}"
}
_install_cloud_env_hook "${HOME}/.bashrc"
if [[ -f "${HOME}/.profile" ]]; then
  _install_cloud_env_hook "${HOME}/.profile"
fi
if [[ -f "${HOME}/.bash_profile" ]]; then
  _install_cloud_env_hook "${HOME}/.bash_profile"
fi
