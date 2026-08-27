#!/usr/bin/env bash
# devenv process: one headless simplex-chat CLI instance per wallet, exposing
# the WebSocket JSON API on the given port, pinned to ONLY the local SMP relay.
# Usage: run-simplex.sh <name> <ws-port>
set -euo pipefail
: "${DEMO_ROOT:?}" "${RUN_DIR:?}"
source "$DEMO_ROOT/scripts/lib.sh"

NAME="${1:?usage: run-simplex.sh <name> <ws-port>}"
PORT="${2:?usage: run-simplex.sh <name> <ws-port>}"

wait_for_file "$SMP_ADDRESS_FILE" "SMP server address"
wait_for_port 127.0.0.1 5223 "SMP server"

mkdir -p "$RUN_DIR/simplex/$NAME"
SMP_ADDR=$(cat "$SMP_ADDRESS_FILE")

# --create-bot-display-name creates the user profile non-interactively on a
# fresh database (a bare fresh start would block on the display-name prompt).
exec simplex-chat \
    -d "$RUN_DIR/simplex/$NAME/chat" \
    -p "$PORT" \
    -s "$SMP_ADDR" \
    --create-bot-display-name "$NAME" \
    --mute
