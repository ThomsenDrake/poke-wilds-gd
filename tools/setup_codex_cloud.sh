#!/usr/bin/env bash
# Codex Cloud setup for PokeWilds-Godot.
#
# Codex Cloud runs this script in its Linux universal image after checkout.
# The local Codex/Cursor hooks remain intentionally lightweight and separate.
# This script installs the pinned Linux Godot binary into the cached container,
# persists GODOT_BIN for the later agent phase, and performs the repo's full
# cache/resource preparation once.
set -euo pipefail

GODOT_VERSION="4.6.1-stable"
GODOT_ARCHIVE="Godot_v${GODOT_VERSION}_linux.x86_64.zip"
GODOT_URL="https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}/${GODOT_ARCHIVE}"
GODOT_SHA512_DEFAULT="a76fd0fe1d44a2dd6c065b6f7b434ad75f5593c07bda3d3017f8304f2d069acbcf0f39cb5d0976f0434b56e9ea852032ddbcbdb7e0ce1c75a47e1dacb6794bd7"
GODOT_SHA512="${CODEX_CLOUD_GODOT_SHA512:-${GODOT_SHA512_DEFAULT}}"
GODOT_DIR="${CODEX_CLOUD_GODOT_DIR:-${HOME}/.local/share/poke-wilds-godot/godot/${GODOT_VERSION}}"
GODOT_BIN="${GODOT_DIR}/godot"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${HOME}/.pokewilds-codex-cloud.env"
ENV_HOOK='[ -f "$HOME/.pokewilds-codex-cloud.env" ] && . "$HOME/.pokewilds-codex-cloud.env"'

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

# The stock Linux binary can run headlessly without an X server, but Godot's
# font loader still needs libfontconfig. Install only when the dynamic linker
# cannot already see it; warm cached containers skip apt entirely.
if ! command -v ldconfig >/dev/null \
  || ! ldconfig -p 2>/dev/null | grep -q 'libfontconfig\.so\.1'; then
  command -v apt-get >/dev/null \
    || fail "libfontconfig.so.1 is missing and this image has no apt-get."
  echo "Installing the Godot headless fontconfig runtime..."
  if (( EUID == 0 )); then
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends libfontconfig1
  else
    command -v sudo >/dev/null \
      || fail "libfontconfig.so.1 is missing; sudo is required to install libfontconfig1."
    sudo apt-get update -qq
    sudo env DEBIAN_FRONTEND=noninteractive \
      apt-get install -y --no-install-recommends libfontconfig1
  fi
  ldconfig -p 2>/dev/null | grep -q 'libfontconfig\.so\.1' \
    || fail "libfontconfig1 installed but libfontconfig.so.1 is still unavailable."
else
  echo "Godot headless fontconfig runtime: ready"
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

export GODOT_BIN
export PATH="${GODOT_DIR}:${PATH}"

# Codex runs setup and the agent in separate Bash sessions. Keep this generated,
# secret-free environment file as the single persistent handoff between them.
cat > "${ENV_FILE}" <<EOF
export GODOT_BIN="${GODOT_BIN}"
export PATH="${GODOT_DIR}:\$PATH"
EOF
for shell_file in "${HOME}/.bashrc" "${HOME}/.profile"; do
  touch "${shell_file}"
  if ! grep -qxF "${ENV_HOOK}" "${shell_file}"; then
    echo "${ENV_HOOK}" >> "${shell_file}"
  fi
done

cd "${REPO_ROOT}"
python3 tools/setup_worktree.py --godot-bin "${GODOT_BIN}"

echo "== Codex Cloud setup complete =="
echo "headless gate: python3 tools/verify_all.py --skip-windowed"
