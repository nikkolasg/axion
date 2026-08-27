#!/usr/bin/env bash
# The headline demonstration: the same recipient wallet (same mnemonic, same
# birthday) discovers an incoming payment two ways, side by side:
#
#   alice-oob   waits for out-of-band advice over SimpleX, fetches ONE
#               transaction and runs one targeted trial decryption
#   alice-scan  runs a normal full chain scan from its last synced height
#
# Scenario 2 (unless SKIP_FALLBACK=1): kill the SimpleX relay, pay again
# without advice, and show the payment still arrives via the fallback
# scanner (the dual-rail invariant).
set -euo pipefail
DEMO_ROOT="${DEMO_ROOT:?run inside devenv shell}"
source "$DEMO_ROOT/scripts/lib.sh"

SERVER_ARGS=(-s 127.0.0.1:8137 --connection direct)
OOB_LOG="$RUN_DIR/race-oob.log"

[ -d "$WALLETS_DIR/alice-oob" ] || { echo "run demo-setup first" >&2; exit 1; }
[ -f "$RUN_DIR/simplex/paired" ] || { echo "SimpleX contacts not paired — run demo-setup" >&2; exit 1; }

wait_for_zebra
wait_for_port 127.0.0.1 8137 "zainod gRPC"

# A leftover listener from an aborted earlier run would swallow the advice
# event meant for this run's listener.
pkill -f 'zcash-devtool advice' 2>/dev/null || true
sleep 1

HEIGHT_BEFORE=$(chain_height)
# The wallet's last-synced height defines the "offline gap" both alices must
# cover: alice-oob via one advice message, alice-scan by scanning it all.
SCAN_FROM=$(wallet alice-scan balance 2>/dev/null | grep -oE 'Height: [0-9]+' | grep -oE '[0-9]+' | head -1 || echo "?")
echo "chain height: $HEIGHT_BEFORE (alice wallets last synced at height ${SCAN_FROM:-?})"

echo
echo "== Starting alice-oob advice listener (targeted-decryption path)"
rm -f "$OOB_LOG"
advice alice-oob receive \
    --ws ws://127.0.0.1:5226 \
    --from bob \
    --timeout 300 \
    --identity "$WALLETS_DIR/alice.age" \
    "${SERVER_ARGS[@]}" >"$OOB_LOG" 2>&1 &
OOB_PID=$!
sleep 2

echo "== Bob pays Alice and sends advice"
bash "$DEMO_ROOT/scripts/demo-pay.sh"

echo
echo "== Waiting for the OOB path to verify the payment"
if ! wait "$OOB_PID"; then
    echo "advice receive FAILED:" >&2
    cat "$OOB_LOG" >&2
    exit 1
fi
grep -E 'ADVICE VERIFIED|timing:' "$OOB_LOG" || cat "$OOB_LOG"

echo
echo "== Running alice-scan full chain scan of the same payment"
SCAN_START=$(date +%s.%N)
wallet alice-scan sync "${SERVER_ARGS[@]}" >"$RUN_DIR/race-scan.log" 2>&1
SCAN_END=$(date +%s.%N)
SCAN_SECS=$(echo "$SCAN_END $SCAN_START" | awk '{printf "%.2f", $1 - $2}')

OOB_VIS=$(grep -oE 'time-to-first-visibility [0-9.]+m?s' "$OOB_LOG" | head -1 | sed 's/time-to-first-visibility //' || echo "see $OOB_LOG")
TXID=$(cat "$RUN_DIR/last-payment-txid" 2>/dev/null || echo "?")

echo
echo "================= RESULT ================="
echo " payment tx: $TXID"
echo " offline gap covered: height ${SCAN_FROM:-?} -> $(chain_height)"
echo
echo " alice-oob  (private: same GetBlockRange as vanilla; advised"
echo "            note decrypted FIRST) time-to-first-visibility: ${OOB_VIS:-?}"
echo " alice-scan (vanilla full scan of the same gap):            ${SCAN_SECS}s"
echo
echo " Both download+scan the whole gap (identical indexer requests, no"
echo " tx leak); the OOB win is seeing the EXPECTED payment before the full"
echo " trial-decryption pass finishes. Small on regtest (near-empty blocks);"
echo " sub-second vs minutes at mainnet output densities. The dramatic"
echo " 'fetch one tx, skip the scan' number is the --fast-sync opt-in, which"
echo " reveals the txid to the indexer."
echo "=========================================="
echo
echo "balances (should both show the 2.5 ZEC payment):"
echo "-- alice-oob (advised note surfaced first; full sync completed in the same command)"
wallet alice-oob list-tx | tail -5 || true
echo "-- alice-scan"
wallet alice-scan balance "${SERVER_ARGS[@]}" 2>/dev/null | tail -8 || true

if [ "${SKIP_FALLBACK:-0}" != "1" ]; then
    echo
    echo "== Scenario 2: relay killed, fallback scanning still finds the payment"
    docker stop axion-smp >/dev/null 2>&1 || true
    echo "SimpleX relay stopped."
    NO_ADVICE=1 bash "$DEMO_ROOT/scripts/demo-pay.sh"
    echo "-- alice-oob discovers it by falling back to a normal scan:"
    wallet alice-oob sync "${SERVER_ARGS[@]}" >/dev/null 2>&1
    wallet alice-oob list-tx | tail -3
    echo "(restart the relay with: devenv processes restart smp-server)"
fi
