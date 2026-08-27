#!/usr/bin/env bash
# Video window: BOB's always-online wallet, serving recovery requests.
# Loops: whenever a recovered wallet publishes a new invitation link (the
# spec's "publish new endpoint" step, transported here via a shared file),
# Bob joins it, challenges the claimant, verifies the continuity proof
# against the identity key he has held since first pairing, and re-delivers
# every advice from his outbox.
set -euo pipefail
DEMO_ROOT="${DEMO_ROOT:?run inside devenv shell}"
source "$DEMO_ROOT/scripts/lib.sh"

LINK_FILE="$RUN_DIR/simplex/recovery-link"

wait_for_port 127.0.0.1 5227 "simplex-bob WS"
N_ADVICES=$(jq -r '[.[] | length] | add // 0' "$WALLETS_DIR/bob/axion-outbox.json" 2>/dev/null || echo 0)

printf '\n\033[1m╔══════════════════════════════════════════════════════╗\n'
printf '║  %-52s║\n' "BOB - online, outbox holds $N_ADVICES sent advice(s)"
printf '║  %-52s║\n' "serving recovery requests over SimpleX ..."
printf '╚══════════════════════════════════════════════════════╝\033[0m\n\n'

while true; do
    if [ -s "$LINK_FILE" ]; then
        LINK=$(cat "$LINK_FILE")
        rm -f "$LINK_FILE"
        echo "recovery request: joining the recovered wallet's new channel ..."
        if advice bob redeliver \
            --ws ws://127.0.0.1:5227 \
            --link "$LINK"; then
            printf '\n\033[1;32m╔══════════════════════════════════════════════════════╗\n'
            printf '║  %-52s║\n' "CONTINUITY PROOF VERIFIED"
            printf '║  %-52s║\n' "advices re-delivered from the outbox"
            printf '╚══════════════════════════════════════════════════════╝\033[0m\n\n'
        else
            echo "recovery attempt REJECTED (bad or missing proof)"
        fi
        echo "waiting for the next recovery request ..."
    fi
    sleep 2
done
