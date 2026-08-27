#!/usr/bin/env bash
# Video-friendly foreground listener for the OOB wallet: waits for payment
# advice over SimpleX and prints the verification timing when it lands.
# Trigger it from another window with `demo-pay`.
set -euo pipefail
DEMO_ROOT="${DEMO_ROOT:?run inside devenv shell}"
source "$DEMO_ROOT/scripts/lib.sh"

SERVER_ARGS=(-s 127.0.0.1:8137 --connection direct)
LOG="$RUN_DIR/watch-oob.log"

# A leftover listener would swallow the advice event meant for this one.
pkill -f 'zcash-devtool advice' 2>/dev/null || true
sleep 1
wait_for_port 127.0.0.1 5226 "simplex-alice WS"

printf '\n\033[1m╔══════════════════════════════════════════════════════╗\n'
printf '║  %-52s║\n' "ALICE - out-of-band wallet"
printf '║  %-52s║\n' "waiting for payment advice over SimpleX ..."
printf '╚══════════════════════════════════════════════════════╝\033[0m\n\n'

# --identity lets the wallet answer with a signed acknowledgment carrying
# the next fresh address (the spec's piggybacked address ratchet).
advice alice-oob receive \
    --ws ws://127.0.0.1:5226 \
    --from bob \
    --timeout 3600 \
    --identity "$WALLETS_DIR/alice.age" \
    "${SERVER_ARGS[@]}" 2>&1 | tee "$LOG"

TOTAL=$(grep -oE 'time-to-first-visibility [0-9.]+m?s' "$LOG" | head -1 | sed 's/time-to-first-visibility //')
printf '\n\033[1;32m╔══════════════════════════════════════════════════════╗\n'
printf '║  %-52s║\n' "PAYMENT VISIBLE IN ${TOTAL:-?}"
printf '║  %-52s║\n' "advised note decrypted first, then full sync"
printf '║  %-52s║\n' "same indexer requests as vanilla (no tx leak)"
printf '╚══════════════════════════════════════════════════════╝\033[0m\n'
