#!/usr/bin/env bash
# Per-task virtual display + software Vulkan for windowed Godot on Linux Cloud.
#
# Reuses an already-working DISPLAY (computer-use desktops often own :1).
# Otherwise starts Xvfb at the canonical 1152x648 sweep window. Idempotent:
# a second call finds the live server and returns. Never prints secrets.
set -euo pipefail

CANONICAL_W=1152
CANONICAL_H=648
DISPLAY_NUM="${POKEWILDS_XVFB_DISPLAY:-99}"
USER_DIR="${POKEWILDS_CLOUD_USER_DIR:-${HOME}}"
ENV_FILE="${POKEWILDS_CLOUD_ENV_FILE:-${USER_DIR}/.pokewilds-cloud.env}"
X11_SOCKET_DIR="${POKEWILDS_X11_SOCKET_DIR:-/tmp/.X11-unix}"
X11_LOCK_DIR="${POKEWILDS_X11_LOCK_DIR:-/tmp}"
XVFB_LOG="${POKEWILDS_XVFB_LOG:-/tmp/pokewilds-xvfb.log}"
XVFB_PID_FILE="${POKEWILDS_XVFB_PID_FILE:-/tmp/pokewilds-xvfb.pid}"
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
  [[ -S "${X11_SOCKET_DIR}/X$(_display_num "${d}")" ]]
}

_clear_stale_display_state() {
  local display_num="$1"
  local lock_file="${X11_LOCK_DIR}/.X${display_num}-lock"
  local socket_file="${X11_SOCKET_DIR}/X${display_num}"
  local owner_pid=""

  if _display_alive ":${display_num}"; then
    return 0
  fi
  if [[ -f "${lock_file}" ]]; then
    owner_pid="$(<"${lock_file}")"
    owner_pid="${owner_pid//[[:space:]]/}"
    if [[ "${owner_pid}" =~ ^[0-9]+$ ]] && kill -0 "${owner_pid}" 2>/dev/null; then
      echo "ensure_cloud_display: DISPLAY=:${display_num} lock is owned by live PID ${owner_pid}, but xdpyinfo cannot reach it" >&2
      return 1
    fi
    echo "ensure_cloud_display: removing stale ${lock_file}"
    rm -f -- "${lock_file}"
  fi
  if [[ -e "${socket_file}" || -S "${socket_file}" ]]; then
    echo "ensure_cloud_display: removing stale ${socket_file}"
    rm -f -- "${socket_file}"
  fi
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
  echo "ensure_cloud_display: xdpyinfo missing; probing ${X11_SOCKET_DIR} sockets (install x11-utils)"
fi

[[ "${DISPLAY_NUM}" =~ ^[0-9]+$ ]] || {
  echo "ensure_cloud_display: POKEWILDS_XVFB_DISPLAY must be numeric; found ${DISPLAY_NUM}" >&2
  exit 1
}

if [[ -n "${DISPLAY:-}" ]] && _display_alive "${DISPLAY}"; then
  echo "ensure_cloud_display: reusing live DISPLAY=${DISPLAY}"
else
  export DISPLAY=":${DISPLAY_NUM}"
  if _display_alive "${DISPLAY}"; then
    echo "ensure_cloud_display: reusing Xvfb DISPLAY=${DISPLAY}"
  else
    _clear_stale_display_state "${DISPLAY_NUM}" || exit 1
    echo "ensure_cloud_display: starting Xvfb ${DISPLAY} ${CANONICAL_W}x${CANONICAL_H}x24"
    Xvfb "${DISPLAY}" -screen 0 "${CANONICAL_W}x${CANONICAL_H}x24" -ac +extension GLX +render -noreset >"${XVFB_LOG}" 2>&1 &
    xvfb_pid=$!
    printf '%s\n' "${xvfb_pid}" > "${XVFB_PID_FILE}"
    for _i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25; do
      if _display_alive "${DISPLAY}"; then
        break
      fi
      sleep 0.2
    done
    if ! _display_alive "${DISPLAY}"; then
      echo "ensure_cloud_display: Xvfb failed to become ready; see ${XVFB_LOG}" >&2
      if [[ -s "${XVFB_LOG}" ]]; then
        tail -n 12 "${XVFB_LOG}" >&2
      fi
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
  # For bashrc-sourced shells. Python loaders prepend ~/.local/bin themselves
  # because PATH is already set and must not be replaced wholesale.
  printf 'export PATH="$HOME/.local/bin:$PATH"\n'
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
_install_cloud_env_hook "${USER_DIR}/.bashrc"
if [[ -f "${USER_DIR}/.profile" ]]; then
  _install_cloud_env_hook "${USER_DIR}/.profile"
fi
if [[ -f "${USER_DIR}/.bash_profile" ]]; then
  _install_cloud_env_hook "${USER_DIR}/.bash_profile"
fi
