#!/usr/bin/env bash
# Codex Cloud setup for PokeWilds-Godot.
#
# Codex Cloud runs this script in its Linux universal image after checkout.
# The local Codex/Cursor hooks remain intentionally lightweight and separate.
# This script installs the pinned Linux Godot binary, windowed software-rendering
# stack, and Command Code reviewer CLI into the cached container. It persists
# only non-secret runtime configuration for the later agent phase, then performs
# the repo's full cache/resource preparation once.
set -euo pipefail

GODOT_VERSION="4.6.1-stable"
GODOT_ARCHIVE="Godot_v${GODOT_VERSION}_linux.x86_64.zip"
GODOT_URL="https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}/${GODOT_ARCHIVE}"
GODOT_SHA512_DEFAULT="a76fd0fe1d44a2dd6c065b6f7b434ad75f5593c07bda3d3017f8304f2d069acbcf0f39cb5d0976f0434b56e9ea852032ddbcbdb7e0ce1c75a47e1dacb6794bd7"
GODOT_SHA512="${CODEX_CLOUD_GODOT_SHA512:-${GODOT_SHA512_DEFAULT}}"
COMMAND_CODE_VERSION="1.26.0"
USER_DIR="${CODEX_CLOUD_USER_DIR:-${HOME}}"
LOCAL_PREFIX="${CODEX_CLOUD_LOCAL_PREFIX:-${USER_DIR}/.local}"
GODOT_DIR="${CODEX_CLOUD_GODOT_DIR:-${LOCAL_PREFIX}/share/poke-wilds-godot/godot/${GODOT_VERSION}}"
GODOT_BIN="${GODOT_DIR}/godot"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${CODEX_CLOUD_ENV_FILE:-${USER_DIR}/.pokewilds-codex-cloud.env}"
ENV_HOOK='[ -f "$HOME/.pokewilds-codex-cloud.env" ] && . "$HOME/.pokewilds-codex-cloud.env"'
LVP_ICD="${CODEX_CLOUD_LVP_ICD:-/usr/share/vulkan/icd.d/lvp_icd.x86_64.json}"

fail() {
  printf 'setup_codex_cloud: %s\n' "$1" >&2
  exit 1
}

[[ "$(uname -s)" == "Linux" ]] \
  || fail "Codex Cloud setup requires Linux; use the local worktree setup on this platform."
[[ "$(uname -m)" == "x86_64" ]] \
  || fail "The pinned Godot archive requires x86_64; found $(uname -m)."
command -v python3 >/dev/null \
  || fail "Python 3.12+ is required in the Codex Cloud image."
command -v curl >/dev/null \
  || fail "curl is required to download the pinned Godot archive."

# Godot's headless import needs fontconfig. Windowed visual sweeps additionally
# need Xvfb, X11 client libraries, and Mesa lavapipe. Install the complete set in
# one apt transaction; warm cached containers skip apt entirely.
visual_runtime_ready() {
  local linker_cache
  command -v ldconfig >/dev/null || return 1
  linker_cache="$(ldconfig -p 2>/dev/null)" || return 1
  for runtime_lib in \
    'libfontconfig\.so\.1' 'libX11\.so\.6' 'libXcursor\.so\.1' \
    'libXi\.so\.6' 'libXinerama\.so\.1' 'libXrandr\.so\.2' \
    'libXrender\.so\.1' 'libGL\.so\.1'; do
    grep -q "${runtime_lib}" <<< "${linker_cache}" || return 1
  done
  command -v Xvfb >/dev/null \
    && command -v xdpyinfo >/dev/null \
    && [[ -f "${LVP_ICD}" ]]
}

if ! visual_runtime_ready; then
  command -v apt-get >/dev/null \
    || fail "Godot's X11/lavapipe runtime is incomplete and this image has no apt-get."
  echo "Installing the Godot X11, Xvfb, and lavapipe runtime..."
  packages=(
    libfontconfig1 xvfb x11-utils mesa-vulkan-drivers vulkan-tools
    libx11-6 libxcursor1 libxi6 libxinerama1 libxrandr2 libxrender1 libgl1
  )
  if (( EUID == 0 )); then
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${packages[@]}"
  else
    command -v sudo >/dev/null \
      || fail "Godot's X11/lavapipe runtime is incomplete; sudo is required to install it."
    sudo apt-get update -qq
    sudo env DEBIAN_FRONTEND=noninteractive \
      apt-get install -y --no-install-recommends "${packages[@]}"
  fi
  visual_runtime_ready \
    || fail "The X11/lavapipe packages installed but the visual runtime is still incomplete."
else
  echo "Godot X11/Xvfb/lavapipe runtime: ready"
fi

echo "== PokeWilds-Godot Codex Cloud setup =="
echo "repo root: ${REPO_ROOT}"

if "${GODOT_BIN}" --version 2>/dev/null | grep -q '^4\.6\.1\.'; then
  echo "Godot ${GODOT_VERSION} already present: $("${GODOT_BIN}" --version)"
else
  echo "Downloading Godot ${GODOT_VERSION} for Linux x86_64..."
  download_dir="$(mktemp -d)"
  trap 'rm -rf "${download_dir}"' EXIT
  archive_path="${download_dir}/${GODOT_ARCHIVE}"
  extract_dir="${download_dir}/extract"
  curl -fsSL --retry 3 --retry-delay 2 -o "${archive_path}" "${GODOT_URL}"

  actual_sha512="$(python3 - "${archive_path}" <<'PY'
from hashlib import sha512
from pathlib import Path
import sys

digest = sha512()
with Path(sys.argv[1]).open("rb") as handle:
    for block in iter(lambda: handle.read(1024 * 1024), b""):
        digest.update(block)
print(digest.hexdigest())
PY
)"
  [[ "${actual_sha512}" == "${GODOT_SHA512}" ]] \
    || fail "Godot archive checksum mismatch; expected ${GODOT_SHA512}, got ${actual_sha512}."

  mkdir -p "${extract_dir}" "${GODOT_DIR}"
  python3 -m zipfile -e "${archive_path}" "${extract_dir}"
  extracted_bin="${extract_dir}/Godot_v${GODOT_VERSION}_linux.x86_64"
  [[ -f "${extracted_bin}" ]] \
    || fail "Downloaded archive did not contain ${extracted_bin##*/}."
  install -m 0755 "${extracted_bin}" "${GODOT_BIN}.new"
  mv -f "${GODOT_BIN}.new" "${GODOT_BIN}"
  echo "Installed: $("${GODOT_BIN}" --version)"
fi

# command-code currently requires Node 22+. Codex Cloud can pin Node 22 in its
# package-version UI; if it is pinned lower, use the universal image's nvm
# installation without touching the repository's .nvmrc.
node_major=""
if command -v node >/dev/null 2>&1; then
  node_major="$(node --version 2>/dev/null | sed -E 's/^v([0-9]+).*/\1/')"
fi
if [[ ! "${node_major}" =~ ^[0-9]+$ ]] || (( node_major < 22 )); then
  nvm_dir="${CODEX_CLOUD_NVM_DIR:-${NVM_DIR:-${USER_DIR}/.nvm}}"
  [[ -s "${nvm_dir}/nvm.sh" ]] \
    || fail "Command Code ${COMMAND_CODE_VERSION} requires Node 22+; pin Node 22 in Codex Cloud or provide nvm."
  # shellcheck disable=SC1090
  . "${nvm_dir}/nvm.sh"
  nvm install 22
  nvm use 22
  hash -r
fi
node_major="$(node --version 2>/dev/null | sed -E 's/^v([0-9]+).*/\1/')"
[[ "${node_major}" =~ ^[0-9]+$ ]] && (( node_major >= 22 )) \
  || fail "Command Code ${COMMAND_CODE_VERSION} requires Node 22+; found $(node --version 2>/dev/null || echo missing)."
command -v npm >/dev/null \
  || fail "npm is required to install Command Code ${COMMAND_CODE_VERSION}."
NODE_BIN_DIR="$(dirname "$(command -v node)")"

export GODOT_BIN COMMANDCODE_SKIP_UPDATES=1 GODOT_AUDIO_DRIVER=Dummy
export PATH="${LOCAL_PREFIX}/bin:${NODE_BIN_DIR}:${GODOT_DIR}:${PATH}"

if command -v cmd >/dev/null 2>&1 \
  && cmd --version >/dev/null 2>&1 \
  && npm list --global --prefix "${LOCAL_PREFIX}" --depth=0 \
       "command-code@${COMMAND_CODE_VERSION}" >/dev/null 2>&1; then
  echo "Command Code ${COMMAND_CODE_VERSION} already present: $(cmd --version)"
else
  echo "Installing Command Code ${COMMAND_CODE_VERSION} into ${LOCAL_PREFIX}..."
  mkdir -p "${LOCAL_PREFIX}"
  npm install --global --prefix "${LOCAL_PREFIX}" "command-code@${COMMAND_CODE_VERSION}"
  hash -r
  command -v cmd >/dev/null \
    || fail "Command Code installed but ${LOCAL_PREFIX}/bin/cmd is unavailable."
  cmd --version >/dev/null \
    || fail "Command Code installed but its version probe failed."
  echo "Installed Command Code: $(cmd --version)"
fi

# Codex runs setup and the agent in separate Bash sessions. Keep this generated,
# secret-free environment file as the single persistent handoff between them.
umask 077
{
  printf 'export GODOT_BIN=%q\n' "${GODOT_BIN}"
  printf 'export PATH=%q:%q:%q:"$PATH"\n' "${LOCAL_PREFIX}/bin" "${NODE_BIN_DIR}" "${GODOT_DIR}"
  printf 'export COMMANDCODE_SKIP_UPDATES=1\n'
  printf 'export GODOT_AUDIO_DRIVER=Dummy\n'
} > "${ENV_FILE}"
for shell_file in "${USER_DIR}/.bashrc" "${USER_DIR}/.profile"; do
  touch "${shell_file}"
  if ! grep -qxF "${ENV_HOOK}" "${shell_file}"; then
    echo "${ENV_HOOK}" >> "${shell_file}"
  fi
done

cd "${REPO_ROOT}"
python3 tools/setup_worktree.py --godot-bin "${GODOT_BIN}"

echo "== Codex Cloud setup complete =="
echo "headless gate: python3 tools/verify_all.py --skip-windowed"
echo "visual preflight: bash tools/run_codex_cloud_visuals.sh --check"
echo "full visual gate: bash tools/run_codex_cloud_visuals.sh"
