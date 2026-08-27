#!/usr/bin/env bash
# Video window: ALICE's vanilla wallet. One command = "open the wallet":
# a normal light-wallet sync runs (as any wallet does on startup), then the
# balance and the received payment appear, with the wall-clock time.
# Same seed and birthday as the OOB wallet. KEEP_LOGS=1 shows the raw sync
# logs instead of the quiet spinner line.
set -euo pipefail
DEMO_ROOT="${DEMO_ROOT:?run inside devenv shell}"
source "$DEMO_ROOT/scripts/lib.sh"

SERVER_ARGS=(-s 127.0.0.1:8137 --connection direct)

wait_for_zebra
wait_for_port 127.0.0.1 8137 "zainod gRPC"

FROM=$(wallet alice-scan balance 2>/dev/null | grep -oE 'Height: [0-9]+' | grep -oE '[0-9]+' | head -1 || echo "?")
TIP=$(chain_height)

printf '\n\033[1m╔══════════════════════════════════════════════════════╗\n'
printf '║  %-52s║\n' "ALICE - vanilla wallet (no out-of-band channel)"
printf '║  %-52s║\n' "opening wallet ... startup sync begins"
printf '╚══════════════════════════════════════════════════════╝\033[0m\n\n'

T0=$(date +%s.%N)
if [ "${KEEP_LOGS:-0}" = "1" ]; then
    wallet alice-scan sync "${SERVER_ARGS[@]}"
else
    echo "scanning the chain since last sync (height ${FROM:-?} -> $TIP) ..."
    wallet alice-scan sync "${SERVER_ARGS[@]}" >/dev/null 2>&1
fi
T1=$(date +%s.%N)
SECS=$(echo "$T1 $T0" | awk '{printf "%.2f", $1 - $2}')
BLOCKS=$([ "$FROM" != "?" ] && echo $((TIP - FROM)) || echo "?")

echo
echo "wallet is up to date - latest received payment:"
wallet alice-scan list-tx | grep -E 'Value|Received by' | tail -2 || true
wallet alice-scan balance 2>/dev/null | grep -E 'Balance:|Orchard Spendable:' | grep -v '{' || true

printf '\n\033[1;33m╔══════════════════════════════════════════════════════╗\n'
printf '║  %-52s║\n' "WALLET READY AFTER ${SECS}s ($BLOCKS blocks scanned)"
printf '║  %-52s║\n' "and this cost grows with every block"
printf '╚══════════════════════════════════════════════════════╝\033[0m\n'
