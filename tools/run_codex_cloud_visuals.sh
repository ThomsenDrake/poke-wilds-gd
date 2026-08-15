#!/usr/bin/env bash
# Start Codex Cloud's ephemeral display and run the Command Code visual lane.
# No credential is copied or persisted by this script.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
USER_DIR="${CODEX_CLOUD_USER_DIR:-${HOME}}"
SETUP_ENV_FILE="${CODEX_CLOUD_ENV_FILE:-${USER_DIR}/.pokewilds-codex-cloud.env}"
RUNTIME_ENV_FILE="${POKEWILDS_CLOUD_ENV_FILE:-${USER_DIR}/.pokewilds-cloud.env}"
MODE="full"

fail() {
  printf 'run_codex_cloud_visuals: %s\n' "$1" >&2
  exit 1
}

case "${1:-}" in
  --check|--focused|--full)
    MODE="${1#--}"
    shift
    ;;
  --help|-h)
    cat <<'EOF'
Usage: bash tools/run_codex_cloud_visuals.sh [--check|--focused|--full] [extra args]

  --check    Start the display and verify Godot, Command Code, and runtime auth.
  --focused  Run only the visual_sweep scenario and Command Code review.
  --full     Run verify_all with all windowed lanes (default).
EOF
    exit 0
    ;;
esac

[[ "$(uname -s)" == "Linux" ]] || fail "this launcher requires Linux."
[[ -f "${SETUP_ENV_FILE}" ]] \
  || fail "setup environment missing; run bash tools/setup_codex_cloud.sh first."
# shellcheck disable=SC1090
. "${SETUP_ENV_FILE}"

cd "${REPO_ROOT}"
bash tools/ensure_cloud_display.sh
[[ -f "${RUNTIME_ENV_FILE}" ]] \
  || fail "display environment was not written to ${RUNTIME_ENV_FILE}."
# shellcheck disable=SC1090
. "${RUNTIME_ENV_FILE}"

[[ -z "${PLAYTEST_FORCE_HEADLESS:-}" ]] \
  || fail "PLAYTEST_FORCE_HEADLESS is set; unset it for a genuine windowed sweep."
command -v xdpyinfo >/dev/null \
  || fail "xdpyinfo is unavailable; rerun the Codex Cloud setup."
DISPLAY="${DISPLAY:-}" xdpyinfo >/dev/null 2>&1 \
  || fail "DISPLAY=${DISPLAY:-unset} is not live."
[[ -n "${GODOT_BIN:-}" && -x "${GODOT_BIN}" ]] \
  || fail "GODOT_BIN is missing or not executable; rerun the Codex Cloud setup."
"${GODOT_BIN}" --version 2>/dev/null | grep -q '^4\.6\.1\.' \
  || fail "GODOT_BIN is not Godot 4.6.1."
command -v cmd >/dev/null \
  || fail "Command Code is unavailable; rerun the Codex Cloud setup."
cmd --version >/dev/null 2>&1 \
  || fail "Command Code's version probe failed."

AUTH_FILE="${USER_DIR}/.commandcode/auth.json"
if [[ -z "${COMMAND_CODE_API_KEY:-}" && ! -f "${AUTH_FILE}" ]]; then
  fail "Command Code runtime auth is unavailable. Codex Cloud secrets are setup-only; use an existing login or an explicitly agent-readable environment variable."
fi

export VLM_RUNTIME=command_code
export VLM_REQUIRED=1
export COMMANDCODE_SKIP_UPDATES=1
export GODOT_AUDIO_DRIVER=Dummy

echo "Codex Cloud visual preflight: ready (DISPLAY=${DISPLAY}, Godot=$("${GODOT_BIN}" --version), Command Code=$(cmd --version))"
case "${MODE}" in
  check)
    [[ $# -eq 0 ]] || fail "--check does not accept extra arguments."
    ;;
  focused)
    python3 tools/run_playtests.py \
      --scenario visual_sweep \
      --report .godot-smoke/visual-sweep-command-code.json \
      "$@"
    ;;
  full)
    python3 tools/verify_all.py \
      --windowed-timeout "${CODEX_CLOUD_WINDOWED_TIMEOUT:-1800}" \
      "$@"
    ;;
esac
