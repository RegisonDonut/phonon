#!/usr/bin/env bash
# Start the warm-resident MLX omni server that Phonon talks to.
# Loads MiniCPM-o 4.5 once and serves http://127.0.0.1:8799.
#
#   ./scripts/start_server.sh
#
# The model is local-only; we disable proxy env vars so nothing is routed
# through Shadowrocket/Clash.
set -euo pipefail
cd "$(dirname "$0")/.."

# Model is chosen by the app's config (~/Library/Application Support/Phonon/model)
# via resolve_model_path(). Do NOT hardcode S2T_MODEL here — a forced value
# silently overrides the user's menu choice (this exact bug bit us: config said
# qwen-omni but the server loaded MiniCPM because S2T_MODEL pinned it).
# Set S2T_MODEL only to deliberately override for a one-off test.
export S2T_HOST="${S2T_HOST:-127.0.0.1}"
export S2T_PORT="${S2T_PORT:-8799}"

# Loopback only — bypass the system HTTP/SOCKS proxy.
unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY 2>/dev/null || true

# Dispatch by the active model id (all run in the same .venv — all MLX, no torch).
CONFIG="$HOME/Library/Application Support/Phonon/model"
MODEL_ID="$(cat "$CONFIG" 2>/dev/null | tr -d '[:space:]')"

if [ "$MODEL_ID" = "qwen-pipeline" ]; then
  echo "[start_server] dispatch -> Qwen3-ASR + Qwen3.5-4B two-layer pipeline"
  exec .venv/bin/python scripts/pipeline_server.py
else
  echo "[start_server] dispatch -> MLX omni (MiniCPM)"
  exec .venv/bin/python scripts/omni_server.py
fi
