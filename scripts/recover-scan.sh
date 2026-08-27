#!/usr/bin/env bash
# Video window: the vanilla wallet after the same device loss. Seed phrase
# in, then the only way to find its payments is a FULL chain rescan from
# the wallet birthday — cost proportional to the whole chain.
set -euo pipefail
DEMO_ROOT="${DEMO_ROOT:?run inside devenv shell}"
source "$DEMO_ROOT/scripts/lib.sh"

SERVER_ARGS=(-s 127.0.0.1:8137 --connection direct)
ACTIVATION="$DEMO_ROOT/configs/activation-heights.toml"

TIP=$(chain_height)
printf '\n\033[1m╔══════════════════════════════════════════════════════╗\n'
printf '║  %-52s║\n' "ALICE - vanilla wallet, device lost."
printf '║  %-52s║\n' "restore from seed = full rescan of $TIP blocks"
printf '╚══════════════════════════════════════════════════════╝\033[0m\n\n'

MNEMONIC=$(wallet alice-oob display-mnemonic --identity "$WALLETS_DIR/alice.age" --enable | tail -1)
[ -n "$MNEMONIC" ] || { echo "could not read the demo seed phrase" >&2; exit 1; }

rm -rf "$WALLETS_DIR/alice-scan-recovered"
mkdir -p "$WALLETS_DIR/alice-scan-recovered"
echo "restoring wallet from seed ..."
printf '%s\n' "$MNEMONIC" | wallet alice-scan-recovered restore-mnemonic \
    --name alice-scan-recovered \
    --identity "$WALLETS_DIR/alice.age" \
    --birthday 1 \
    --network regtest \
    --activation-heights "$ACTIVATION" \
    "${SERVER_ARGS[@]}" >/dev/null

echo "rescanning the whole chain to find the wallet's notes ..."
T0=$(date +%s.%N)
if [ "${KEEP_LOGS:-0}" = "1" ]; then
    wallet alice-scan-recovered sync "${SERVER_ARGS[@]}"
else
    wallet alice-scan-recovered sync "${SERVER_ARGS[@]}" >/dev/null 2>&1
fi
T1=$(date +%s.%N)
SECS=$(echo "$T1 $T0" | awk '{printf "%.2f", $1 - $2}')

echo
echo "recovered balance:"
wallet alice-scan-recovered balance 2>/dev/null | grep -E 'Balance:|Orchard Spendable:' | grep -v '{' || true

printf '\n\033[1;33m╔══════════════════════════════════════════════════════╗\n'
printf '║  %-52s║\n' "RECOVERED VIA FULL RESCAN"
printf '║  %-52s║\n' "chain work: ${SECS}s ($TIP blocks, grows with chain)"
printf '║  %-52s║\n' "no advice channel: every block must be checked"
printf '╚══════════════════════════════════════════════════════╝\033[0m\n'
