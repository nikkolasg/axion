#!/usr/bin/env bash
# Scaling measurement: how private-OOB time-to-first-visibility
# and vanilla full-scan time compare over a gap containing many shielded
# outputs. Build the gap first with dense noise, e.g.:
#   OUTPUTS_PER_TX=16 BATCH=10 BLOCKS_PER_BATCH=3 MORE_TXS=400 demo-noise
# then run:  BIRTHDAY=<height alices were synced to> demo-scaling
#
# The workload that matters is shielded OUTPUTS in the gap (each is one trial
# decryption), not block count. Vanilla is measured at 32 cores and at 1 core
# (RAYON_NUM_THREADS=1, phone-class); private-OOB only decrypts the advised
# block so it is flat in the gap size.
set -euo pipefail
DEMO_ROOT="${DEMO_ROOT:?run inside devenv shell}"
source "$DEMO_ROOT/scripts/lib.sh"

SA=(-s 127.0.0.1:8137 --connection direct)
ACT="$DEMO_ROOT/configs/activation-heights.toml"
BIRTHDAY="${BIRTHDAY:?set BIRTHDAY to the height the wallets were synced to before demo-noise}"
MN=$(wallet alice-oob display-mnemonic --identity "$WALLETS_DIR/alice.age" --enable | tail -1)
TIP=$(chain_height)

measure_vanilla() {
    local name="$1" threads="$2"
    rm -rf "$WALLETS_DIR/$name"; mkdir -p "$WALLETS_DIR/$name"
    printf '%s\n' "$MN" | wallet "$name" restore-mnemonic --name "$name" \
        --identity "$WALLETS_DIR/alice.age" --birthday "$BIRTHDAY" --network regtest \
        --activation-heights "$ACT" "${SA[@]}" >/dev/null 2>&1
    local T0 T1
    T0=$(date +%s.%N)
    RAYON_NUM_THREADS="$threads" wallet "$name" sync "${SA[@]}" >/dev/null 2>&1
    T1=$(date +%s.%N)
    echo "$(echo "$T1 $T0" | awk '{printf "%.2f", $1-$2}')s"
    rm -rf "$WALLETS_DIR/$name"
}

echo "gap: $BIRTHDAY -> $TIP ($((TIP-BIRTHDAY)) blocks); scanning all shielded outputs in it"
echo "vanilla full scan  (32 cores): $(measure_vanilla scaling_mc 0)"
echo "vanilla full scan  ( 1 core ): $(measure_vanilla scaling_sc 1)"

# Private OOB: fresh alice-oob at the same birthday, receive advice, read the
# time-to-first-visibility it prints (download the gap + peek the advised block).
LOG="$RUN_DIR/scaling-priv.log"
rm -rf "$WALLETS_DIR/alice-oob"
printf '%s\n' "$MN" | wallet alice-oob restore-mnemonic --name alice-oob \
    --identity "$WALLETS_DIR/alice.age" --birthday "$BIRTHDAY" --network regtest \
    --activation-heights "$ACT" "${SA[@]}" >/dev/null 2>&1
"$DEVTOOL" advice -w "$WALLETS_DIR/alice-oob" receive --ws ws://127.0.0.1:5226 \
    --from bob --timeout 150 --identity "$WALLETS_DIR/alice.age" "${SA[@]}" >"$LOG" 2>&1 &
RECV_PID=$!
sleep 4
bash "$DEMO_ROOT/scripts/demo-pay.sh" >/dev/null 2>&1
wait "$RECV_PID" || true
VIS=$(grep -oE 'time-to-first-visibility [0-9.]+m?s' "$LOG" | head -1 | sed 's/time-to-first-visibility //')
LEAK=$(grep -ci get_transaction "$LOG" || true)

echo "private OOB time-to-first-visibility: ${VIS:-see $LOG}   (get_transaction calls: $LEAK)"
echo
echo "private-OOB is flat in the gap size (only the advised block is decrypted);"
echo "vanilla grows with the shielded-output count. Re-pair alice-oob afterwards"
echo "(demo-reset-pairing) — this script restored its wallet from seed."
