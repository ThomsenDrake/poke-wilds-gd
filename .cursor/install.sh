#!/usr/bin/env bash
# Cloud Agent install script for PokeWilds-Godot.
#
# Idempotent, non-interactive repository bootstrap run after the source is
# checked out. It provisions the pinned Godot editor binary, then hands the
# repo-native bootstrap (tools/setup_worktree.py) the rest: fetching the pinned
# PokeAPI cache and importing the Godot resource tree. With environment builds
# this runs once to create the baseline snapshot; a warm re-run is a fast no-op.
#
# Windowed + Lane-4 validation needs a display (start.sh) and Command Code
# (`cmd` + COMMAND_CODE_API_KEY). This script only prepares durable inputs.
set -euo pipefail

GODOT_VERSION="4.6.1-stable"
GODOT_DIR="${HOME}/godot-bin"
GODOT_BIN="${GODOT_DIR}/godot"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "== PokeWilds-Godot Cloud Agent install =="
echo "repo root: ${REPO_ROOT}"

# 1. Pinned Godot editor binary (skip the ~140MB download when already correct).
if "${GODOT_BIN}" --version 2>/dev/null | grep -q '^4\.6\.1\.'; then
  echo "Godot ${GODOT_VERSION} already present: $("${GODOT_BIN}" --version)"
else
  echo "Downloading Godot ${GODOT_VERSION} (linux x86_64)..."
  mkdir -p "${GODOT_DIR}"
  curl -fsSL -o /tmp/godot.zip \
    "https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}/Godot_v${GODOT_VERSION}_linux.x86_64.zip"
  unzip -o -q /tmp/godot.zip -d "${GODOT_DIR}"
  mv -f "${GODOT_DIR}/Godot_v${GODOT_VERSION}_linux.x86_64" "${GODOT_BIN}"
  chmod +x "${GODOT_BIN}"
  rm -f /tmp/godot.zip
  echo "Installed: $("${GODOT_BIN}" --version)"
fi

# 2. Make GODOT_BIN the default for the tools (verify_all / setup_worktree read
#    GODOT_BIN before falling back to the macOS app path). Persist it for the
#    agent's interactive shells too, idempotently and self-healingly: match the
#    EXACT intended export line (not any "GODOT_BIN=" substring, which a comment,
#    an OLD_GODOT_BIN=, or an export pointing elsewhere would satisfy). When the
#    exact line is absent, drop any stale export GODOT_BIN= lines we manage, then
#    append the authoritative value so a later shell never resolves a wrong path.
export GODOT_BIN
BASHRC="${HOME}/.bashrc"
GODOT_BIN_EXPORT="export GODOT_BIN=\"${GODOT_BIN}\""
touch "${BASHRC}"
if ! grep -qxF "${GODOT_BIN_EXPORT}" "${BASHRC}"; then
  if grep -qE '^[[:space:]]*export[[:space:]]+GODOT_BIN=' "${BASHRC}"; then
    grep -vE '^[[:space:]]*export[[:space:]]+GODOT_BIN=' "${BASHRC}" > "${BASHRC}.tmp"
    mv "${BASHRC}.tmp" "${BASHRC}"
  fi
  echo "${GODOT_BIN_EXPORT}" >> "${BASHRC}"
fi

# 3. Windowed Godot runtime libs + lavapipe (software Vulkan). Skip apt when
#    the ICD is already present so a warm re-run stays a no-op.
LVP_ICD="/usr/share/vulkan/icd.d/lvp_icd.x86_64.json"
if [[ -f "${LVP_ICD}" ]] && command -v Xvfb >/dev/null; then
  echo "Xvfb + lavapipe already present: ${LVP_ICD}"
else
  echo "Installing Xvfb, lavapipe, and Godot X11 runtime libs..."
  sudo apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    xvfb mesa-vulkan-drivers vulkan-tools \
    libx11-6 libxcursor1 libxi6 libxinerama1 libxrandr2 libxrender1 libgl1
fi

# 4. Command Code CLI (Lane-4 VLM backend). Auth is COMMAND_CODE_API_KEY from
#    the environment secret — never written here. Node 22+ is required.
if command -v cmd >/dev/null && cmd --version >/dev/null 2>&1; then
  echo "Command Code already present: $(cmd --version)"
else
  if ! command -v npm >/dev/null; then
    echo "error: npm is required to install command-code (Node 22+)" >&2
    exit 1
  fi
  echo "Installing Command Code CLI (command-code@latest) into ${HOME}/.local..."
  mkdir -p "${HOME}/.local"
  npm i -g --prefix "${HOME}/.local" command-code@latest
  export PATH="${HOME}/.local/bin:${PATH}"
  echo "Installed: $(cmd --version)"
fi
if ! grep -qxF 'export PATH="$HOME/.local/bin:$PATH"' "${BASHRC}"; then
  echo 'export PATH="$HOME/.local/bin:$PATH"' >> "${BASHRC}"
fi
if ! grep -qxF 'export COMMANDCODE_SKIP_UPDATES=1' "${BASHRC}"; then
  echo 'export COMMANDCODE_SKIP_UPDATES=1' >> "${BASHRC}"
fi

# 5. Repo-native bootstrap: version checks, pinned PokeAPI cache fetch, and the
#    Godot resource import. setup_worktree.py is idempotent and never mutates
#    tracked files (it aborts if it would). This deliberately uses the full
#    default preparation for the reusable cloud environment snapshot; local
#    Cursor and Codex worktree hooks use --quick instead.
cd "${REPO_ROOT}"
python3 tools/setup_worktree.py --godot-bin "${GODOT_BIN}"

echo "== install complete =="
echo "headless gate: python3 tools/verify_all.py --skip-windowed"
echo "windowed + VLM: source ~/.pokewilds-cloud.env 2>/dev/null; python3 tools/verify_all.py"
echo "Command Code auth: COMMAND_CODE_API_KEY environment secret (never committed)"
