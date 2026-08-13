#!/usr/bin/env bash
# Cloud Agent install script for PokeWilds-Godot.
#
# Idempotent, non-interactive repository bootstrap run after the source is
# checked out. It provisions the pinned Godot editor binary, then hands the
# repo-native bootstrap (tools/setup_worktree.py) the rest: fetching the pinned
# PokeAPI cache and importing the Godot resource tree. With environment builds
# this runs once to create the baseline snapshot; a warm re-run is a fast no-op.
#
# End-to-end validation lives in tools/verify_all.py --skip-windowed (the honest
# display-less path); this script only prepares the inputs that gate needs.
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

# 3. Repo-native bootstrap: version checks, pinned PokeAPI cache fetch, and the
#    Godot resource import. setup_worktree.py is idempotent and never mutates
#    tracked files (it aborts if it would). This deliberately uses the full
#    default preparation for the reusable cloud environment snapshot; local
#    Cursor and Codex worktree hooks use --quick instead.
cd "${REPO_ROOT}"
python3 tools/setup_worktree.py --godot-bin "${GODOT_BIN}"

echo "== install complete: run 'python3 tools/verify_all.py --skip-windowed' to validate =="
