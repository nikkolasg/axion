#!/usr/bin/env bash
# Manufacture chain history so that the full-scan wallet has real work to do.
#
# Bob repeatedly pays himself with multi-output shielded transactions; every
# transaction is followed by a batch of mined blocks. Resumable: progress is
# tracked by a counter file, so interrupting and re-running continues where
# it left off.
#
# Bob holds many independent coinbase notes (he is the miner), so several
# transactions can be created per sync: each pay reserves different notes.
# One cycle = sync once, pay BATCH txs into the mempool, mine a block batch.
#
# The defaults build a chain segment resembling a two-week offline period
# (~13k blocks at Zcash's 75s spacing) with shielded traffic sprinkled
# throughout. Requires demo-setup to have switched the miner to the fast
# transparent address.
#
# Knobs (env):
#   NOISE_TXS       cumulative transaction target         (default 180)
#   MORE_TXS        extend by N txs beyond current progress (overrides NOISE_TXS)
#   OUTPUTS_PER_TX  shielded outputs per transaction      (default 8)
#   BATCH           transactions per sync+mine cycle      (default 6)
#   BLOCKS_PER_BATCH blocks mined after each cycle        (default 450)
#   QUICK=1         light parameters: 4 outputs / 50 blocks per cycle
set -euo pipefail
DEMO_ROOT="${DEMO_ROOT:?run inside devenv shell}"
source "$DEMO_ROOT/scripts/lib.sh"

NOISE_TXS="${NOISE_TXS:-180}"
OUTPUTS_PER_TX="${OUTPUTS_PER_TX:-8}"
BATCH="${BATCH:-6}"
BLOCKS_PER_BATCH="${BLOCKS_PER_BATCH:-450}"
if [ "${QUICK:-0}" = "1" ]; then
    OUTPUTS_PER_TX=4 BATCH=6 BLOCKS_PER_BATCH=50
fi
if [ -n "${MORE_TXS:-}" ]; then
    NOISE_TXS=$(( $(cat "$RUN_DIR/noise-progress" 2>/dev/null || echo 0) + MORE_TXS ))
fi

SERVER_ARGS=(-s 127.0.0.1:8137 --connection direct)
COUNTER_FILE="$RUN_DIR/noise-progress"
DONE=$(cat "$COUNTER_FILE" 2>/dev/null || echo 0)

wait_for_zebra
wait_for_port 127.0.0.1 8137 "zainod gRPC"

BOB_UA=$(wallet bob list-addresses | grep -oE 'uregtest[0-9a-z]+' | head -1)
[ -n "$BOB_UA" ] || { echo "could not extract Bob's unified address" >&2; exit 1; }

# ZIP-321 multi-output payment request paying Bob's own address N times.
AMOUNT="0.001"
build_uri() {
    local uri="zcash:?address=${BOB_UA}&amount=${AMOUNT}"
    local i
    for i in $(seq 1 $((OUTPUTS_PER_TX - 1))); do
        uri="${uri}&address.${i}=${BOB_UA}&amount.${i}=${AMOUNT}"
    done
    printf '%s' "$uri"
}
URI=$(build_uri)

echo "noise progress: $DONE/$NOISE_TXS txs ($OUTPUTS_PER_TX outputs each, $BATCH per cycle)"
START_TIME=$(date +%s)

while [ "$DONE" -lt "$NOISE_TXS" ]; do
    # The indexer may be briefly down (e.g. right after a zebrad bounce);
    # retry instead of dying mid-run.
    if ! wallet bob sync "${SERVER_ARGS[@]}" >/dev/null 2>&1; then
        echo "  bob sync failed (indexer restarting?); retrying in 10s"
        sleep 10
        continue
    fi
    IN_BATCH=0
    while [ "$IN_BATCH" -lt "$BATCH" ] && [ "$DONE" -lt "$NOISE_TXS" ]; do
        # A pay can fail when spendable notes run out mid-batch; end the
        # batch early, mine, and let the next sync pick up fresh notes.
        if ! wallet bob pay \
            --identity "$WALLETS_DIR/bob.age" \
            --payment-uri "$URI" \
            --disable-confirmation \
            "${SERVER_ARGS[@]}" >/dev/null 2>&1; then
            echo "  pay failed at tx $((DONE + 1)) (likely out of spendable notes); mining and re-syncing"
            break
        fi
        DONE=$((DONE + 1))
        IN_BATCH=$((IN_BATCH + 1))
        printf '%s' "$DONE" > "$COUNTER_FILE"
    done
    mine "$BLOCKS_PER_BATCH"
    ELAPSED=$(( $(date +%s) - START_TIME ))
    echo "  $DONE/$NOISE_TXS txs, height $(chain_height), ${ELAPSED}s elapsed"
done

echo "noise generation complete: height $(chain_height), $((NOISE_TXS * OUTPUTS_PER_TX)) shielded outputs on chain"
